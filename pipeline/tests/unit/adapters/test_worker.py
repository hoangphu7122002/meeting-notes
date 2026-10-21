import io
import json

from meeting_notes.adapters.inbound.worker import Worker
from meeting_notes.adapters.outbound.model_cache import Models
from meeting_notes.adapters.outbound.progress_reporter import Reporter
from meeting_notes.application.process_meeting import Processor


def make_worker(monkeypatch, deps=None):
    out = io.StringIO()
    monkeypatch.setattr("sys.stdout", out)
    w = Worker(make_models=lambda cfg, keep, log: Models(cfg, keep=keep, log=log), make_reporter=Reporter,
               make_processor=lambda folder, cfg, reporter, models: Processor(folder, cfg, reporter, deps, models))
    return w, out


def events(out):
    return [json.loads(line) for line in out.getvalue().splitlines()]


def test_worker_process_job(meeting, stubs, deps, monkeypatch):
    w, out = make_worker(monkeypatch, deps)
    w._process({"cmd": "process", "job": "j1", "folder": str(meeting)})
    ev = events(out)
    assert all(e.get("job") == "j1" for e in ev)
    assert ev[-1] == {"event": "job_end", "job": "j1", "exit": 0}
    assert any(e["event"] == "done" for e in ev)
    assert w.models.keep is False and not w.models.loaded  # models unloaded after each stage by default


def test_worker_bad_folder(monkeypatch, tmp_path):
    w, out = make_worker(monkeypatch)
    w._process({"cmd": "process", "job": "x", "folder": str(tmp_path / "missing")})
    assert events(out)[-1]["exit"] == 2


def test_worker_cancel(meeting, stubs, deps, monkeypatch):
    w, out = make_worker(monkeypatch, deps)

    def slow_blocks(blocks, tracks, transcriber, allowed, progress=None, **kw):
        w.cancel.set()  # simulates {"cmd": "cancel"} arriving mid-transcription
        progress(0.5, "halfway")
        raise AssertionError("should have been cancelled")

    deps.transcribe_blocks = slow_blocks
    w._process({"cmd": "process", "job": "c", "folder": str(meeting)})
    ev = events(out)
    assert ev[-1]["exit"] == 3 and any(e["event"] == "cancelled" for e in ev)
    assert json.loads((meeting / "status.json").read_text())["state"] == "cancelled"
    assert not w.busy and not w.cancel.is_set()


def test_worker_exits_when_idle(monkeypatch):
    w, out = make_worker(monkeypatch)
    w.cfg.worker_idle_release_min = 0
    assert w._idle_exit()
    assert events(out)[-1]["status"] == "exit"


def test_cancel_before_job_starts_is_not_lost(meeting, stubs, deps, monkeypatch):
    import sys

    w, out = make_worker(monkeypatch, deps)
    lines = io.StringIO(json.dumps({"cmd": "process", "job": "early", "folder": str(meeting)}) + "\n"
                        + json.dumps({"cmd": "cancel"}) + "\n")
    monkeypatch.setattr(sys, "stdin", lines)
    w._read_stdin()  # both commands arrive before the main loop picks up the job
    w._process(w.commands.get_nowait())
    assert events(out)[-1] == {"event": "job_end", "job": "early", "exit": 3}
    assert w.inflight == 0 and not w.cancel.is_set()
    # A stale cancel with nothing in flight does not affect the next job.
    w.commands.get_nowait()  # the quit sentinel from EOF
    monkeypatch.setattr(sys, "stdin", io.StringIO(json.dumps({"cmd": "cancel"}) + "\n"))
    w._read_stdin()
    assert not w.cancel.is_set()
