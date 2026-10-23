"""FluidAudio diarizer adapter with a fake CLI runner (no Swift binary, no download)."""

import json

import numpy as np
import pytest
from helpers import room, speechlike

from meeting_notes.adapters.outbound import fluidaudio_diarizer as fa
from meeting_notes.adapters.outbound.fluidaudio_diarizer import FluidAudioDiarizer, find_binary, parse_turns
from meeting_notes.adapters.outbound.model_cache import Models, make_diarizer
from meeting_notes.adapters.outbound.pyannote_diarizer import Diarizer
from meeting_notes.config import Config
from meeting_notes.domain.meeting_naming import describe_diarization
from meeting_notes.domain.speakers import TrackDiarization
from meeting_notes.domain.voice_check import VoiceCheck

SPEECH = np.concatenate([room(1), speechlike(6), room(1), speechlike(6)])
OUTPUT = json.dumps({"segments": [{"start": 7.0, "end": 13.0, "speaker": "S2"},
                                  {"start": 1.0, "end": 7.0, "speaker": "S1"},
                                  {"start": 5.0, "end": 5.0, "speaker": "S1"}]})


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


class FakeRunner:
    def __init__(self, stdout=OUTPUT, fail_on=None):
        self.stdout, self.fail_on, self.calls = stdout, fail_on, []

    def __call__(self, argv, timeout):
        self.calls.append((argv, timeout))
        if self.fail_on and self.fail_on in argv:
            raise RuntimeError("MeetingNotesDiarize exited 1: boom")
        if "--prepare" in argv:
            return json.dumps({"segments": []})
        assert open(argv[1], "rb").read(4) == b"RIFF"  # a real WAV is handed to the CLI
        return "log line\n" + self.stdout + "\n"


def make(tmp_path, runner, fallback=None):
    binary = tmp_path / "MeetingNotesDiarize"
    binary.write_text("")
    cfg = Config(diarization_engine="fluidaudio", fluidaudio_cli=str(binary))
    return FluidAudioDiarizer(cfg, log=lambda m: None, fallback=fallback or FakeFallback(), runner=runner)


def test_parse_turns_sorts_and_drops_empty_turns():
    assert parse_turns("noise\n" + OUTPUT) == [(1.0, 7.0, "S1"), (7.0, 13.0, "S2")]
    with pytest.raises(RuntimeError):
        parse_turns("  \n")


def test_diarize_prepares_once_then_shells_out_per_track(tmp_path):
    runner, seen = FakeRunner(), []
    d = make(tmp_path, runner)
    out = d.diarize(SPEECH, seen.append)
    d.diarize(SPEECH)
    assert out.method == "fluidaudio:community-1-coreml" and out.notes == []
    assert out.turns == [(1.0, 7.0, "S1"), (7.0, 13.0, "S2")] and seen == [1.0]
    argvs = [argv for argv, _ in runner.calls]
    assert ["--prepare" in a for a in argvs] == [True, False, False]
    assert all(a[a.index("--models") + 1] == str(fa.MODELS_DIR) for a in argvs)
    assert runner.calls[1][1] == pytest.approx(120.0 + len(SPEECH) / 16000)
    assert d._fallback.diarized == 0


def test_silence_skips_the_cli(tmp_path):
    runner = FakeRunner()
    out = make(tmp_path, runner).diarize(np.zeros(16000 * 3, np.float32))
    assert out.method == "vad" and runner.calls == []


def test_missing_binary_falls_back_to_pyannote_with_a_note(tmp_path):
    fb = FakeFallback()
    cfg = Config(diarization_engine="fluidaudio", fluidaudio_cli=str(tmp_path / "nope"))
    out = FluidAudioDiarizer(cfg, log=lambda m: None, fallback=fb, runner=FakeRunner()).diarize(SPEECH)
    assert fb.diarized == 1 and out.method == "pyannote:fake"
    assert out.notes[0].startswith("fluidaudio unavailable: RuntimeError: fluidaudio_cli not found")


def test_cli_failure_falls_back_too(tmp_path):
    out = make(tmp_path, FakeRunner(stdout="not json")).diarize(SPEECH)
    assert out.method == "pyannote:fake" and out.notes[0].startswith("fluidaudio failed: JSONDecodeError")
    out = make(tmp_path, FakeRunner(fail_on="--prepare")).diarize(SPEECH)
    assert out.notes[0] == "fluidaudio unavailable: RuntimeError: MeetingNotesDiarize exited 1: boom"


def test_find_binary_prefers_config_then_app_build(tmp_path, monkeypatch):
    with pytest.raises(RuntimeError, match="not built"):
        monkeypatch.setattr(fa, "REPO_ROOT", tmp_path)
        monkeypatch.setattr(fa.shutil, "which", lambda name: None)
        find_binary(Config())
    built = tmp_path / "app" / ".build" / "release" / "MeetingNotesDiarize"
    built.parent.mkdir(parents=True)
    built.write_text("")
    assert find_binary(Config()) == built


def test_run_cli_strips_hf_tokens(monkeypatch):
    captured = {}

    class Proc:
        returncode, stdout, stderr = 0, "{}", ""

    def fake_run(argv, **kw):
        captured.update(kw)
        return Proc()

    monkeypatch.setenv("HF_TOKEN", "secret")
    monkeypatch.setattr(fa.subprocess, "run", fake_run)
    assert fa.run_cli(["x"], 5.0) == "{}"
    assert "HF_TOKEN" not in captured["env"] and captured["timeout"] == 5.0


def test_voice_check_and_release_use_the_pyannote_fallback(tmp_path):
    fb = FakeFallback()
    d = make(tmp_path, FakeRunner(), fallback=fb)
    assert d.voice_check(SPEECH).single is True and fb.checked == 1
    d.engine()
    d.release()
    assert fb.released == 1 and d._binary is None and d._fallback is None


def test_engine_choice_and_switch_follow_config():
    assert isinstance(make_diarizer(Config(diarization_engine="fluidaudio"), log=lambda m: None), FluidAudioDiarizer)
    assert isinstance(make_diarizer(Config(), log=lambda m: None), Diarizer)
    m = Models(Config(), keep=True, log=lambda m: None, pressure=lambda: 1)
    m.diarizer()
    m.update_config(Config(diarization_engine="fluidaudio"))
    assert m._diarizer is None and isinstance(m.diarizer(), FluidAudioDiarizer)


def test_full_fluidaudio_pass_counts_as_real_diarization_in_notes():
    assert describe_diarization(["system=fluidaudio:community-1-coreml", "mic=single-voice"], []) == ""
