"""sherpa-onnx diarizer adapter with a mocked engine (no sherpa_onnx import, no download)."""

import hashlib
import io
import tarfile
from types import SimpleNamespace

import numpy as np
import pytest
from helpers import room, speechlike

from meeting_notes.adapters.outbound import sherpa_models
from meeting_notes.adapters.outbound.model_cache import Models, make_diarizer
from meeting_notes.adapters.outbound.pyannote_diarizer import Diarizer
from meeting_notes.adapters.outbound.sherpa_diarizer import SherpaDiarizer, run
from meeting_notes.config import Config
from meeting_notes.domain.meeting_naming import describe_diarization
from meeting_notes.domain.speakers import TrackDiarization
from meeting_notes.domain.voice_check import VoiceCheck

SPEECH = np.concatenate([room(1), speechlike(6), room(1), speechlike(6)])


class Result(list):
    def sort_by_start_time(self):
        return sorted(self, key=lambda r: r.start)


class FakeEngine:
    sample_rate = 16000

    def __init__(self, segments=((7.0, 13.0, 1), (1.0, 7.0, 0))):
        self.segments, self.calls = segments, []

    def process(self, samples, callback=None):
        self.calls.append(samples)
        for i in range(1, 5):
            callback(i, 4)
        return Result(SimpleNamespace(start=s, end=e, speaker=k) for s, e, k in self.segments)


class FakeFallback:
    def __init__(self):
        self.diarized = self.checked = self.released = 0

    def diarize(self, audio, progress=None):
        self.diarized += 1
        return TrackDiarization([(0.0, 1.0, "A")], "pyannote:fake", ["fallback note"])

    def voice_check(self, audio, exclude=None):
        self.checked += 1
        return VoiceCheck([], True, "fake")

    def release(self):
        self.released += 1

    def trim(self):
        pass


def sherpa(engine=None, error=None, fallback=None):
    def loader(cfg, log):
        if error:
            raise error
        return engine

    cfg = Config(diarization_engine="sherpa-onnx")
    return SherpaDiarizer(cfg, log=lambda m: None, fallback=fallback or FakeFallback(), loader=loader)


def test_run_returns_sorted_turns_and_reports_progress():
    seen = []
    turns = run(FakeEngine(), SPEECH.astype(np.float64), seen.append)
    assert turns == [(1.0, 7.0, "0"), (7.0, 13.0, "1")]
    assert seen == [0.25, 0.5, 0.75, 1.0]


def test_diarize_uses_the_engine_and_names_the_method():
    engine = FakeEngine()
    d = sherpa(engine)
    out = d.diarize(SPEECH)
    assert out.method == "sherpa-onnx:3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced"
    assert out.turns == [(1.0, 7.0, "0"), (7.0, 13.0, "1")] and out.notes == []
    assert engine.calls[0].dtype == np.float32 and d._fallback.diarized == 0


def test_silence_skips_the_engine():
    engine = FakeEngine()
    out = sherpa(engine).diarize(np.zeros(16000 * 3, np.float32))
    assert out.method == "vad" and engine.calls == []


def test_missing_sherpa_falls_back_to_pyannote_with_a_note():
    fb = FakeFallback()
    out = sherpa(error=RuntimeError("sherpa-onnx is not installed"), fallback=fb).diarize(SPEECH)
    assert fb.diarized == 1 and out.method == "pyannote:fake"
    assert out.notes[0].startswith("sherpa-onnx unavailable: RuntimeError: sherpa-onnx is not installed")


def test_engine_failure_falls_back_too():
    class Broken(FakeEngine):
        def process(self, samples, callback=None):
            raise ValueError("bad model")

    out = sherpa(Broken()).diarize(SPEECH)
    assert out.method == "pyannote:fake" and out.notes[0] == "sherpa-onnx failed: ValueError: bad model"


def test_voice_check_and_release_use_the_pyannote_fallback():
    fb = FakeFallback()
    d = sherpa(FakeEngine(), fallback=fb)
    assert d.voice_check(SPEECH).single is True and fb.checked == 1
    d.engine()
    d.release()
    assert fb.released == 1 and d._engine is None and d._fallback is None


def test_engine_choice_follows_config():
    assert isinstance(make_diarizer(Config(), log=lambda m: None), Diarizer)
    assert isinstance(make_diarizer(Config(diarization_engine="sherpa-onnx"), log=lambda m: None), SherpaDiarizer)
    assert isinstance(make_diarizer(Config(diarization_engine="nonsense"), log=lambda m: None), Diarizer)


def test_switching_engine_releases_the_loaded_diarizer():
    m = Models(Config(), keep=True, log=lambda m: None, pressure=lambda: 1)
    m.diarizer()
    m.update_config(Config(diarization_engine="sherpa-onnx"))
    assert m._diarizer is None
    assert isinstance(m.diarizer(), SherpaDiarizer)


def test_full_sherpa_pass_counts_as_real_diarization_in_notes():
    assert describe_diarization(["system=sherpa-onnx:x", "mic=single-voice"], []) == ""


# ------------------------------------------------------------ model files


def tarball(tmp_path):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:bz2") as tar:
        for name, data in (("model.onnx", b"onnx"), ("LICENSE", b"MIT"), ("run.sh", b"#!/bin/sh")):
            info = tarfile.TarInfo(f"{sherpa_models.SEGMENTATION['name']}/{name}")
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
    return buf.getvalue()


def test_segmentation_model_is_downloaded_once_and_extracted(tmp_path):
    data, calls = tarball(tmp_path), []

    def fetch(url, sha, dest, log):
        calls.append((url, sha))
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(data)

    path = sherpa_models.segmentation_model(tmp_path, log=lambda m: None, fetch=fetch)
    assert path.read_bytes() == b"onnx" and (path.parent / "LICENSE").exists()
    assert not (path.parent / "run.sh").exists() and not list(tmp_path.glob("*.tar.bz2"))
    assert sherpa_models.segmentation_model(tmp_path, log=lambda m: None, fetch=fetch) == path and len(calls) == 1
    assert calls[0][0].startswith("https://github.com/k2-fsa/sherpa-onnx/releases/download/")


def test_embedding_model_names_are_pinned(tmp_path):
    with pytest.raises(ValueError, match="unknown sherpa embedding model"):
        sherpa_models.embedding_model("made-up", tmp_path, fetch=lambda *a: None)
    got = []
    path = sherpa_models.embedding_model(Config().sherpa_embedding_model, tmp_path,
                                         fetch=lambda url, sha, dest, log: got.append((url, sha)))
    assert path.name.endswith(".onnx") and got[0][1] == sherpa_models.EMBEDDINGS[Config().sherpa_embedding_model]


def test_download_checks_sha256_before_keeping_the_file(tmp_path):
    src = tmp_path / "src.onnx"
    src.write_bytes(b"weights")
    good = hashlib.sha256(b"weights").hexdigest()
    dest = tmp_path / "models" / "m.onnx"
    with pytest.raises(RuntimeError, match="checksum mismatch"):
        sherpa_models._download(src.as_uri(), "0" * 64, dest, log=lambda m: None)
    assert not dest.exists() and not list(dest.parent.glob("*.part"))
    sherpa_models._download(src.as_uri(), good, dest, log=lambda m: None)
    assert dest.read_bytes() == b"weights"
