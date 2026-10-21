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
