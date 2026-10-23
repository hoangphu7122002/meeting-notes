"""CLI command handlers: failures keep their exit code and leave a traceback on stderr."""

from argparse import Namespace
from types import SimpleNamespace

from meeting_notes.adapters.inbound import commands
from meeting_notes.adapters.inbound.commands import cmd_doctor, cmd_import, cmd_process, cmd_setup
from meeting_notes.application.errors import Cancelled
from meeting_notes.config import Config


def broken_processor(folder, cfg, reporter):
    raise ImportError("broken install: no module named mlx_whisper")


def test_process_failure_exits_1_and_prints_traceback(tmp_path, capsys):
    deps = SimpleNamespace(make_reporter=lambda json_mode: None, make_processor=broken_processor)
    args = Namespace(folder=str(tmp_path), json=False, force=False, from_stage=None)
    assert cmd_process(args, None, deps) == 1
    err = capsys.readouterr().err
    assert "Traceback" in err and "broken install" in err


def test_process_cancelled_exits_3_quietly(tmp_path, capsys):
    def cancelled(folder, cfg, reporter):
        raise Cancelled()

    deps = SimpleNamespace(make_reporter=lambda json_mode: None, make_processor=cancelled)
    args = Namespace(folder=str(tmp_path), json=False, force=False, from_stage=None)
    assert cmd_process(args, None, deps) == 3
    assert capsys.readouterr().err == ""


def test_import_processing_failure_exits_1_and_prints_traceback(tmp_path, capsys):
    deps = SimpleNamespace(import_audio=lambda audio, notes, title: tmp_path, make_reporter=lambda json_mode: None,
                           make_processor=broken_processor)
    args = Namespace(audio="a.wav", notes_dir=str(tmp_path), title=None, no_process=False, json=False)
    cfg = SimpleNamespace(notes_path=tmp_path)
    assert cmd_import(args, cfg, deps) == 1
    err = capsys.readouterr().err
    assert "Traceback" in err and "broken install" in err


class FakeLlm:
    def ensure_model(self, progress):
        progress(1.0, "pulled")

    def list_models(self):
        return ["qwen3:4b"]


def setup_deps(prepared, fail=False):
    def prepare(cfg, log):
        prepared.append(cfg.diarization_engine)
        log("diarization: downloading FluidAudio models (~21 MB, files 1/4, 25%)")
        if fail:
            raise RuntimeError("offline")
        return "/x/MeetingNotesDiarize"

    return SimpleNamespace(download_model=lambda repo: None, check_hf_access=lambda models: {}, make_llm=lambda cfg: FakeLlm(),
                           prepare_fluidaudio=prepare, fluidaudio_status=lambda cfg: "helper /x; models cached",
                           find_ffmpeg=lambda: "/opt/homebrew/bin/ffmpeg", cached_status=lambda repo: True)


def test_setup_prefetches_fluidaudio_models_for_the_default_engine_only(monkeypatch, capsys):
    monkeypatch.setattr(commands, "hf_token", lambda: None)
    prepared = []
    assert cmd_setup(Namespace(), Config(), setup_deps(prepared)) == 0
    assert cmd_setup(Namespace(), Config(diarization_engine="pyannote"), setup_deps(prepared)) == 0
    assert prepared == ["fluidaudio"]
    err = capsys.readouterr().err
    assert "files 1/4" in err and "FluidAudio ready: /x/MeetingNotesDiarize" in err and "Setup complete." in err


def test_setup_goes_on_when_the_fluidaudio_download_fails(monkeypatch, capsys):
    monkeypatch.setattr(commands, "hf_token", lambda: None)
    assert cmd_setup(Namespace(), Config(), setup_deps([], fail=True)) == 0
    err = capsys.readouterr().err
    assert "FluidAudio not ready (offline); diarization will fall back to pyannote" in err and "Setup complete." in err


def test_doctor_reports_the_engine_and_calls_the_hf_token_optional(monkeypatch, capsys):
    monkeypatch.setattr(commands, "hf_token", lambda: None)
    assert cmd_doctor(Namespace(offline=True), Config(), setup_deps([])) == 0
    out = capsys.readouterr().out
    assert "diarization_engine: fluidaudio" in out and "fluidaudio: helper /x; models cached" in out
    assert "hf_token: missing (optional: only the pyannote fallback uses it)" in out
