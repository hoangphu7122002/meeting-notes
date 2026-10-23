import numpy as np
from helpers import tone

from meeting_notes.adapters.outbound.ffmpeg_audio import decode, encode_m4a
from meeting_notes.adapters.outbound.wav_files import write_wav
from meeting_notes.domain.signal import SR


def test_encode_and_decode_roundtrip(tmp_path):
    src = tmp_path / "a.wav"
    write_wav(src, tone(1.0))
    encode_m4a([(src, 0.5)], tmp_path / "a.m4a")
    y = decode(tmp_path / "a.m4a")
    assert abs(len(y) / SR - 1.5) < 0.1
    assert np.abs(y[: int(0.4 * SR)]).max() < 0.02  # leading delay is silent


def test_afconvert_fallback_roundtrip_and_mix(tmp_path):
    import pytest

    from meeting_notes.adapters.outbound import afconvert_audio

    if not afconvert_audio.available():
        pytest.skip("macOS afconvert")
    a, b = tmp_path / "a.wav", tmp_path / "b.wav"
    write_wav(a, tone(1.0))
    write_wav(b, tone(2.0))
    afconvert_audio.encode_m4a([(a, 0.5)], tmp_path / "a.m4a")
    y = afconvert_audio.decode(tmp_path / "a.m4a")
    assert y.dtype == np.float32 and abs(len(y) / SR - 1.5) < 0.1
    assert np.abs(y[: int(0.4 * SR)]).max() < 0.02 and np.abs(y[int(0.7 * SR):]).max() > 0.05
    afconvert_audio.encode_m4a([(a, 0.0), (b, 1.0)], tmp_path / "mix.m4a")
    mixed = afconvert_audio.decode(tmp_path / "mix.m4a")
    assert abs(len(mixed) / SR - 3.0) < 0.1 and np.abs(mixed).max() <= 1.0


def test_audio_files_fall_back_to_afconvert_without_ffmpeg(monkeypatch):
    from meeting_notes.adapters.outbound import afconvert_audio, audio_files, ffmpeg_audio

    def missing():
        raise RuntimeError("ffmpeg not found")

    monkeypatch.setattr(ffmpeg_audio, "ffmpeg_bin", missing)
    monkeypatch.setattr(afconvert_audio, "available", lambda: True)
    assert audio_files.media_backend() is afconvert_audio
    assert ffmpeg_audio.find_ffmpeg().startswith("not installed: using macOS afconvert")
    monkeypatch.setattr(afconvert_audio, "available", lambda: False)
    try:
        audio_files.media_backend()
        raise AssertionError("expected RuntimeError")
    except RuntimeError as exc:
        assert "ffmpeg not found" in str(exc)
