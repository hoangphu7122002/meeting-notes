"""CLI command handlers: failures keep their exit code and leave a traceback on stderr."""

from argparse import Namespace
from types import SimpleNamespace

from meeting_notes.adapters.inbound.commands import cmd_import, cmd_process
from meeting_notes.application.errors import Cancelled


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
