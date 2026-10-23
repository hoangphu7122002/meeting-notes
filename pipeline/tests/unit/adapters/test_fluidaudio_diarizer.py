"""FluidAudio diarizer adapter with a fake CLI runner (no Swift binary, no download)."""

import json
import subprocess

import numpy as np
import pytest
from helpers import room, speechlike

from meeting_notes.adapters.outbound import fluidaudio_diarizer as fa
from meeting_notes.adapters.outbound.fluidaudio_diarizer import FluidAudioDiarizer, find_binary, parse_turns
from meeting_notes.adapters.outbound.model_cache import Models, make_diarizer
from meeting_notes.adapters.outbound.pyannote_diarizer import Diarizer
from meeting_notes.config import Config
from meeting_notes.domain.meeting_naming import describe_diarization, engine_used
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

    def __call__(self, argv, timeout, on_line=None):
        self.calls.append((argv, timeout))
        if self.fail_on and self.fail_on in argv:
            raise RuntimeError("MeetingNotesDiarize exited 1: boom")
        if "--prepare" in argv:
            for line in ("progress 0.0 listing", "progress 0.5 downloading 2/4", "progress 0.6 downloading 3/4",
                         "progress 1.0 compiling Segmentation", "progress 1.0 compiling FBank"):
                on_line(line)
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


def touch(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("")
    path.chmod(0o755)
    return path


def test_find_binary_order_bundle_then_repo_build_then_path(tmp_path, monkeypatch):
    monkeypatch.setattr(fa, "REPO_ROOT", tmp_path / "repo")
    monkeypatch.setattr(fa, "APP_BUNDLES", (str(tmp_path / "home/Applications/MeetingNotes.app"),))
    monkeypatch.setattr(fa.shutil, "which", lambda name: None)
    with pytest.raises(RuntimeError, match="not found"):
        find_binary(Config(), env={})
    on_path = touch(tmp_path / "bin" / "MeetingNotesDiarize")
    monkeypatch.setattr(fa.shutil, "which", lambda name: str(on_path))
    assert find_binary(Config(), env={}) == on_path
    debug = touch(tmp_path / "repo/app/.build/debug/MeetingNotesDiarize")
    assert find_binary(Config(), env={}) == debug
    release = touch(tmp_path / "repo/app/.build/release/MeetingNotesDiarize")
    assert find_binary(Config(), env={}) == release
    installed = touch(tmp_path / "home/Applications/MeetingNotes.app/Contents/MacOS/MeetingNotesDiarize")
    assert find_binary(Config(), env={}) == installed
    bundled = touch(tmp_path / "Other.app/Contents/MacOS/MeetingNotesDiarize")
    assert find_binary(Config(), env={fa.APP_ENV: str(bundled)}) == bundled  # the running app's own copy first
    assert find_binary(Config(), env={fa.APP_ENV: str(tmp_path / "gone")}) == installed  # stale env: skipped
    override = touch(tmp_path / "custom")
    assert find_binary(Config(fluidaudio_cli=str(override)), env={fa.APP_ENV: str(bundled)}) == override
    with pytest.raises(RuntimeError, match="fluidaudio_cli not found"):  # an explicit override never falls through
        find_binary(Config(fluidaudio_cli=str(tmp_path / "typo")), env={fa.APP_ENV: str(bundled)})


def test_status_reports_helper_and_model_cache(tmp_path, monkeypatch):
    monkeypatch.setattr(fa, "MODELS_DIR", tmp_path / "models")
    binary = touch(tmp_path / "MeetingNotesDiarize")
    assert fa.status(Config(fluidaudio_cli=str(binary))) == f"helper {binary}; models download on first use (~21 MB, no login)"
    (tmp_path / "models/speaker-diarization/Segmentation.mlmodelc").mkdir(parents=True)
    line = fa.status(Config(fluidaudio_cli=str(tmp_path / "nope")))
    assert line.startswith("helper missing:") and line.endswith("falls back to pyannote; models cached")


def test_prepare_logs_download_progress_sparingly(tmp_path):
    logs = []
    d = make(tmp_path, FakeRunner())
    d.log = logs.append
    d.prepare()
    assert logs == ["diarization: downloading FluidAudio models (~21 MB, files 2/4, 50%)",
                    "diarization: compiling FluidAudio models for this Mac (first use, ~30 s)"]
    cached = []
    progress = fa.ProgressLog(cached.append)
    for line in ("progress 0.5 downloading 0/0", "progress 0.5 compiling Segmentation.mlmodelc", "noise", "progress x y"):
        progress(line)
    assert cached == []


def script(tmp_path, body):
    path = tmp_path / "fake-cli"
    path.write_text("#!/bin/sh\n" + body)
    path.chmod(0o755)
    return str(path)


def test_run_cli_streams_stderr_returns_stdout_and_strips_hf_tokens(tmp_path, monkeypatch):
    monkeypatch.setenv("HF_TOKEN", "secret")
    cli = script(tmp_path, 'echo "progress 0.5 downloading 1/2" >&2\necho "token=${HF_TOKEN:-none}"\n'
                           'i=0; while [ $i -lt 3000 ]; do echo "{\\"pad\\": $i}"; i=$((i+1)); done\n')
    lines = []
    out = fa.run_cli([cli], 10.0, lines.append)
    assert lines == ["progress 0.5 downloading 1/2"]
    assert out.startswith("token=none\n") and out.count("pad") == 3000  # > 64 KB of stdout never blocks


def test_run_cli_errors_carry_stderr_but_not_progress(tmp_path):
    cli = script(tmp_path, 'echo "progress 0.1 listing" >&2\necho "download failed: offline" >&2\nexit 1\n')
    with pytest.raises(RuntimeError, match=r"fake-cli exited 1: download failed: offline$"):
        fa.run_cli([cli], 10.0)
    with pytest.raises(subprocess.TimeoutExpired):
        fa.run_cli([script(tmp_path, "sleep 5\n")], 0.2)


def test_voice_check_and_release_use_the_pyannote_fallback(tmp_path):
    fb = FakeFallback()
    d = make(tmp_path, FakeRunner(), fallback=fb)
    assert d.voice_check(SPEECH).single is True and fb.checked == 1
    d.engine()
    d.release()
    assert fb.released == 1 and d._binary is None and d._fallback is None


def test_release_forgets_a_missing_helper_so_the_next_job_retries(tmp_path):
    runner = FakeRunner(fail_on="--prepare")
    d = make(tmp_path, runner)
    assert d.engine() is None and d._error
    d.release()
    runner.fail_on = None
    assert d.engine() is not None


def test_fallback_chain_without_helper_or_token_ends_in_ungated_clustering(tmp_path, monkeypatch):
    """FluidAudio missing -> pyannote (no HF_TOKEN: unavailable) -> clustering on ungated embeddings."""
    pyannote = Diarizer(Config(), log=lambda m: None)
    pyannote._pipeline_error = "HF_TOKEN not set"
    pyannote._embedder = lambda chunk: np.array([1.0, 0.0, float(np.abs(chunk).mean() > 0)])
    cfg = Config(fluidaudio_cli=str(tmp_path / "nope"))
    out = FluidAudioDiarizer(cfg, log=lambda m: None, fallback=pyannote).diarize(SPEECH)
    assert out.method == "clustering" and out.turns
    assert out.notes[0].startswith("fluidaudio unavailable") and out.notes[1] == "pyannote unavailable: HF_TOKEN not set"


def test_engine_choice_and_switch_follow_config():
    quiet = {"log": lambda m: None}
    assert Config().diarization_engine == "fluidaudio"
    assert isinstance(make_diarizer(Config(), **quiet), FluidAudioDiarizer)
    assert isinstance(make_diarizer(Config(diarization_engine="nonsense"), **quiet), FluidAudioDiarizer)
    assert isinstance(make_diarizer(Config(diarization_engine=" Pyannote "), **quiet), Diarizer)
    m = Models(Config(diarization_engine="pyannote"), keep=True, log=lambda m: None, pressure=lambda: 1)
    m.diarizer()
    m.update_config(Config())
    assert m._diarizer is None and isinstance(m.diarizer(), FluidAudioDiarizer)


def test_full_fluidaudio_pass_counts_as_real_diarization_in_notes():
    assert describe_diarization(["system=fluidaudio:community-1-coreml", "mic=single-voice"], []) == ""


@pytest.mark.parametrize("methods, engine", [
    (["system=fluidaudio:community-1-coreml", "mic=single-voice"], "fluidaudio"),
    (["system=fluidaudio:community-1-coreml", "mic=pyannote:pyannote/speaker-diarization-community-1"], "fluidaudio+pyannote"),
    (["system=pyannote:pyannote/speaker-diarization-community-1", "mic=pyannote:x"], "pyannote"),
    (["system=clustering", "mic=single-voice"], "clustering"),
    (["system=vad", "mic=single-voice"], "vad"),
    (["mic=single-voice"], "single-voice"),
    ([], "none"),
])
def test_engine_used_names_what_actually_ran(methods, engine):
    assert engine_used(methods) == engine
