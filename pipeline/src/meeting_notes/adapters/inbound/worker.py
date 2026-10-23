"""Long-lived pipeline worker used by the app.

Avoids re-importing torch/MLX for each queued meeting. With keep_models_warm = "auto" (default) models stay
loaded between stages and queued jobs only while memory pressure is "normal"; on "warn" or worse they are
released (at stage boundaries, and every IDLE_POLL_SEC while idle, announced as status "released" with
"reason": "memory"). The worker exits after `worker_idle_release_min` idle minutes, so nothing stays resident
while you work.

Protocol: one JSON object per line.
  stdin  {"cmd": "warmup"} | {"cmd": "process", "job": "<id>", "folder": "...", "from": null, "force": false}
         {"cmd": "live", "job": "live-<id>", "folder": "...", "polish"?: "off|rules|llm"} | {"cmd": "live_stop", "job": "live-<id>"}
         {"cmd": "cancel"} | {"cmd": "release"} | {"cmd": "ping"} | {"cmd": "quit"}
  stdout {"event": "worker", "status": "ready|warming|warm|released|busy", ...} (ready carries "features": ["live", "live_polish"])
         pipeline events (see adapters/outbound/progress_reporter.py) tagged with "job", then {"event": "job_end", "job": id, "exit": 0|1|2|3}
         live jobs: {"event": "live_segment", ...} / {"event": "live_status", ...} / {"event": "live_polish", ...}
         (display-only polished paragraph, only when polish is on), then job_end
A live job runs in the serial loop until live_stop (also implied by process, quit or EOF); it never releases the
transcriber, so the Stop-time process job finds whisper warm.
Exit codes per job: 0 ok, 1 failed, 2 bad request, 3 cancelled. EOF on stdin ends the worker.
"""

from __future__ import annotations

import dataclasses
import json
import os
import queue
import sys
import threading
import time
from collections.abc import Callable
from pathlib import Path
from typing import TYPE_CHECKING

from ...application.errors import Cancelled
from ...config import Config, redact

if TYPE_CHECKING:
    from ...application.ports import ManagedModels, ProgressReporter


IDLE_POLL_SEC = 5.0  # idle loop tick: memory-pressure release and idle exit


class Worker:
    """Serves the app's JSON-lines protocol. Models, reporters and processors come from entrypoints/wiring.py."""

    def __init__(self, make_models: Callable[..., ManagedModels], make_reporter: Callable[..., ProgressReporter],
                 make_processor: Callable[..., object], load_config: Callable[[], Config] = Config.load,
                 make_live: Callable[..., object] | None = None):
        self.make_models = make_models
        self.make_live = make_live  # (folder, cfg, reporter, models) -> object with run(stop); None = no live feature
        self.live_stops: dict[str, threading.Event] = {}  # live jobs received and not finished (guarded by lock)
        self.make_reporter = make_reporter
        self.make_processor = make_processor
        self.load_config = load_config
        self.out = sys.stdout
        sys.stdout = sys.stderr  # stray prints from libraries must not corrupt the protocol
        self.lock = threading.Lock()
        self.commands: queue.Queue = queue.Queue()
        self.cancel = threading.Event()
        self.busy = False
        self.inflight = 0  # process commands received but not finished (guarded by lock)
        self.cfg = self.load_config()
        self.models = make_models(self.cfg, self.cfg.keep_models_warm, lambda m: print(redact(m), file=sys.stderr, flush=True))

    def send(self, event: dict) -> None:
        with self.lock:
            self.out.write(json.dumps(event, ensure_ascii=False) + "\n")
            self.out.flush()

    def _read_stdin(self) -> None:
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                cmd = json.loads(line)
            except json.JSONDecodeError:
                self.send({"event": "worker", "status": "error", "message": "invalid JSON command"})
                continue
            if cmd.get("cmd") == "cancel":
                # Applies to the job that is running or already received (no race with job start).
                with self.lock:
                    if self.inflight > 0:
                        self.cancel.set()
                continue
            if cmd.get("cmd") in ("live_stop", "process"):
                self._stop_live(cmd.get("job") if cmd.get("cmd") == "live_stop" else None)  # a job never waits on live
                if cmd.get("cmd") == "live_stop":
                    continue
            if cmd.get("cmd") == "live":
                with self.lock:
                    self.live_stops[str(cmd.get("job") or "live")] = threading.Event()
            if cmd.get("cmd") == "process":
                with self.lock:
                    self.inflight += 1
            if cmd.get("cmd") == "ping":
                self.send({"event": "pong", "busy": self.busy, "warm": self.models.loaded})
                continue
            if cmd.get("cmd") == "quit":
                self._stop_live(None)
            self.commands.put(cmd)
        self._stop_live(None)
        self.commands.put({"cmd": "quit"})

    def _stop_live(self, job: str | None) -> None:
        """live_stop for one live job, or for all of them (job None)."""
        with self.lock:
            for name, event in self.live_stops.items():
                if job is None or name == job:
                    event.set()

    def serve(self) -> int:
        threading.Thread(target=self._read_stdin, name="stdin", daemon=True).start()
        self.send({"event": "worker", "status": "ready", "pid": os.getpid(), "features": ["live", "live_polish"] if self.make_live else []})
        while True:
            try:
                cmd = self.commands.get(timeout=IDLE_POLL_SEC)
            except queue.Empty:
                if self._idle_exit():
                    return 0
                self._release_on_pressure()
                continue
            name = cmd.get("cmd")
            if name == "quit":
                self.models.release()
                return 0
            if name == "release":
                self.models.release()
                self.send({"event": "worker", "status": "released"})
            elif name == "warmup":
                self._warmup()
            elif name == "process":
                self._process(cmd)
            elif name == "live" and self.make_live:
                self._live(cmd)
            else:
                self.send({"event": "worker", "status": "error", "message": f"unknown command {name!r}"})

    def _idle_exit(self) -> bool:
        """Free models and exit after `worker_idle_release_min` idle minutes; the app respawns on demand."""
        idle_min = (time.monotonic() - self.models.last_used) / 60
        if idle_min < self.cfg.worker_idle_release_min:
            return False
        self.models.release()
        self.send({"event": "worker", "status": "exit", "idle_min": round(idle_min, 1)})
        return True

    def _release_on_pressure(self) -> None:
        """Between jobs: drop warm models as soon as memory pressure leaves "normal" (RAM safety beats speed)."""
        if self.models.release_if_pressure():
            self.send({"event": "worker", "status": "released", "reason": "memory"})

    def _warmup(self) -> None:
        self.cfg = self.load_config()
        self.models.update_config(self.cfg)
        self.send({"event": "worker", "status": "warming"})
        t = time.monotonic()
        try:
            timings = self.models.warmup()
        except Exception as exc:
            self.send({"event": "worker", "status": "error", "message": redact(f"warmup failed: {exc}")})
            return
        self.send({"event": "worker", "status": "warm", "timings": timings, "elapsed_sec": round(time.monotonic() - t, 2)})

    def _process(self, cmd: dict) -> None:
        job = str(cmd.get("job") or "job")
        folder = Path(str(cmd.get("folder") or "")).expanduser()
        if not folder.is_dir():
            self._finish_job()
            self.send({"event": "error", "job": job, "message": f"Not a folder: {folder}"})
            self.send({"event": "job_end", "job": job, "exit": 2})
            return
        self.cfg = self.load_config()
        self.models.update_config(self.cfg)
        self.busy = True
        reporter = self.make_reporter(json_mode=True, out=_Locked(self), job=job, cancel=self.cancel)
        code = 0
        try:
            self.make_processor(folder, self.cfg, reporter, self.models).run("prepare" if cmd.get("force") else cmd.get("from"))
        except Cancelled:
            code = 3
        except Exception:
            code = 1
        finally:
            self.busy = False
            self._finish_job()
            self.models.last_used = time.monotonic()
        self.send({"event": "job_end", "job": job, "exit": code})
        self._release_on_pressure()

    def _live(self, cmd: dict) -> None:
        """Live transcription of a meeting being recorded, until live_stop."""
        job = str(cmd.get("job") or "live")
        with self.lock:
            stop = self.live_stops.setdefault(job, threading.Event())
        folder = Path(str(cmd.get("folder") or "")).expanduser()
        code = 0
        if not folder.is_dir():
            self.send({"event": "error", "job": job, "message": f"Not a folder: {folder}"})
            code = 2
        else:
            self.cfg = self.load_config()
            self.models.update_config(self.cfg)
            self.busy = True
            reporter = self.make_reporter(json_mode=True, out=_Locked(self), job=job)
            cfg = self.cfg
            if cmd.get("polish") in ("off", "rules", "llm"):  # app setting overrides config.toml for this job
                cfg = dataclasses.replace(cfg, live_polish=str(cmd["polish"]))
            try:
                self.make_live(folder, cfg, reporter, self.models).run(stop)
            except Exception as exc:
                print(redact(f"live job failed: {exc}"), file=sys.stderr, flush=True)
                self.send({"event": "error", "job": job, "message": redact(f"Live transcription stopped: {exc}")})
                code = 1
            finally:
                self.busy = False
                self.models.last_used = time.monotonic()
        with self.lock:
            self.live_stops.pop(job, None)
        self.send({"event": "job_end", "job": job, "exit": code})

    def _finish_job(self) -> None:
        with self.lock:
            self.inflight = max(0, self.inflight - 1)
            self.cancel.clear()


class _Locked:
    """File-like wrapper so reporter writes share the worker's stdout lock."""

    def __init__(self, worker: Worker):
        self.worker = worker

    def write(self, text: str) -> None:
        with self.worker.lock:
            self.worker.out.write(text)

    def flush(self) -> None:
        with self.worker.lock:
            self.worker.out.flush()
