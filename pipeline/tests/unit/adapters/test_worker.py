import io
import json

from meeting_notes.adapters.inbound.worker import Worker
from meeting_notes.adapters.outbound.model_cache import Models
from meeting_notes.adapters.outbound.progress_reporter import Reporter
from meeting_notes.application.process_meeting import Processor


WARN = 2  # memory pressure injected into Models: deterministic regardless of the test machine


def make_worker(monkeypatch, deps=None, pressure=lambda: WARN):
    out = io.StringIO()
    monkeypatch.setattr("sys.stdout", out)
    w = Worker(make_models=lambda cfg, keep, log: Models(cfg, keep=keep, log=log, pressure=pressure), make_reporter=Reporter,
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
    assert w.models.mode == "auto" and not w.models.loaded  # under "warn" models are unloaded after each stage


def test_worker_keeps_models_warm_under_normal_pressure_and_releases_on_warn(meeting, stubs, deps, monkeypatch):
    level = {"now": 1}
    w, out = make_worker(monkeypatch, deps, pressure=lambda: level["now"])
    w._process({"cmd": "process", "job": "j1", "folder": str(meeting)})
    assert w.models.loaded and events(out)[-1]["event"] == "job_end"  # warm for the next queued job
    w._release_on_pressure()
    assert w.models.loaded  # still normal: nothing to do
    level["now"] = 2
    w._release_on_pressure()
    assert not w.models.loaded
    assert events(out)[-1] == {"event": "worker", "status": "released", "reason": "memory"}


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


class FakeLive:
    """make_live stand-in: emits one live_segment and a status per poll until stopped."""

    configs: list = []

    def __init__(self, folder, cfg, reporter, models):
        self.reporter = reporter
        FakeLive.configs.append(cfg)

    def run(self, stop):
        self.reporter.live_segment("mic", "Me", 0, 1.0, 4.5, "vi", "xin chào")
        while not stop.wait(0.01):
            pass
        self.reporter.live_status("stopped", 0.0, 0.0, 0.2)
        return {}


def make_live_worker(monkeypatch, deps=None):
    out = io.StringIO()
    monkeypatch.setattr("sys.stdout", out)
    w = Worker(make_models=lambda cfg, keep, log: Models(cfg, keep=keep, log=log, pressure=lambda: WARN), make_reporter=Reporter,
               make_processor=lambda folder, cfg, reporter, models: Processor(folder, cfg, reporter, deps, models),
               make_live=FakeLive)
    return w, out


def test_ready_announces_live_feature(monkeypatch):
    import sys

    w, out = make_live_worker(monkeypatch)
    monkeypatch.setattr(sys, "stdin", io.StringIO(""))
    assert w.serve() == 0
    assert events(out)[0]["features"] == ["live", "live_polish"]
    w2, out2 = make_worker(monkeypatch)
    monkeypatch.setattr(sys, "stdin", io.StringIO(json.dumps({"cmd": "live", "job": "live-1", "folder": "/tmp"}) + "\n"))
    w2.serve()
    ev = events(out2)
    assert ev[0]["features"] == [] and ev[1] == {"event": "worker", "status": "error", "message": "unknown command 'live'"}


def test_live_job_runs_until_live_stop(meeting, monkeypatch):
    import os
    import sys
    import threading
    import time

    w, out = make_live_worker(monkeypatch)
    r, wfd = os.pipe()
    monkeypatch.setattr(sys, "stdin", os.fdopen(r, "r"))
    writer = os.fdopen(wfd, "w")
    t = threading.Thread(target=w.serve)
    t.start()
    writer.write(json.dumps({"cmd": "live", "job": "live-a", "folder": str(meeting)}) + "\n")
    writer.flush()
    deadline = time.monotonic() + 2
    while not w.busy and time.monotonic() < deadline:
        time.sleep(0.01)
    time.sleep(0.1)
    assert w.busy and "job_end" not in out.getvalue()  # the live job waits for live_stop
    writer.write(json.dumps({"cmd": "live_stop", "job": "live-a"}) + "\n")
    writer.flush()
    while "job_end" not in out.getvalue() and time.monotonic() < deadline + 2:
        time.sleep(0.01)
    writer.close()  # EOF: worker quits
    t.join(2)
    ev = events(out)
    assert ev[1] == {"event": "live_segment", "track": "mic", "speaker": "Me", "seq": 0, "start": 1.0, "end": 4.5,
                     "language": "vi", "text": "xin chào", "job": "live-a"}
    assert ev[2]["event"] == "live_status" and ev[2]["state"] == "stopped" and ev[2]["job"] == "live-a"
    assert ev[3] == {"event": "job_end", "job": "live-a", "exit": 0}
    assert w.live_stops == {} and not w.busy and not t.is_alive()


def test_live_stop_or_process_before_the_live_job_starts_is_not_lost(meeting, monkeypatch):
    import sys

    for follow in [{"cmd": "live_stop", "job": "live-b"}, {"cmd": "process", "job": "p", "folder": str(meeting)}]:
        w, out = make_live_worker(monkeypatch)
        lines = json.dumps({"cmd": "live", "job": "live-b", "folder": str(meeting)}) + "\n" + json.dumps(follow) + "\n"
        monkeypatch.setattr(sys, "stdin", io.StringIO(lines))
        w._read_stdin()  # both arrive before the main loop starts the live job
        w._live(w.commands.get_nowait())  # returns at once: already stopped
        assert events(out)[-1] == {"event": "job_end", "job": "live-b", "exit": 0}


def test_live_bad_folder(monkeypatch, tmp_path):
    w, out = make_live_worker(monkeypatch)
    w._live({"cmd": "live", "job": "live-x", "folder": str(tmp_path / "missing")})
    assert events(out)[-1] == {"event": "job_end", "job": "live-x", "exit": 2}


def test_live_polish_from_the_app_overrides_config(meeting, monkeypatch):
    import sys

    FakeLive.configs.clear()
    w, out = make_live_worker(monkeypatch)
    lines = [{"cmd": "live", "job": "live-p", "folder": str(meeting), "polish": "rules"}, {"cmd": "live_stop", "job": "live-p"},
             {"cmd": "live", "job": "live-q", "folder": str(meeting), "polish": "bogus"}, {"cmd": "live_stop", "job": "live-q"}]
    monkeypatch.setattr(sys, "stdin", io.StringIO("".join(json.dumps(c) + "\n" for c in lines)))
    w.serve()
    assert [c.live_polish for c in FakeLive.configs] == ["rules", "off"] and w.cfg.live_polish == "off"
