"""Long-lived pipeline worker used by the app.

Avoids re-importing torch/MLX for each queued meeting. By default models are unloaded after each
stage (keep_models_warm=False) and the worker exits after `worker_idle_release_min` idle minutes,
so nothing stays resident while you work.

Protocol: one JSON object per line.
  stdin  {"cmd": "warmup"} | {"cmd": "process", "job": "<id>", "folder": "...", "from": null, "force": false}
         {"cmd": "cancel"} | {"cmd": "release"} | {"cmd": "ping"} | {"cmd": "quit"}
  stdout {"event": "worker", "status": "ready|warming|warm|released|busy", ...}
         pipeline events (see events.py) tagged with "job", then {"event": "job_end", "job": id, "exit": 0|1|2|3}
Exit codes per job: 0 ok, 1 failed, 2 bad request, 3 cancelled. EOF on stdin ends the worker.
"""

from __future__ import annotations

import json
import os
import queue
import sys
import threading
import time
from pathlib import Path

from .config import Config, redact
from .events import Cancelled, Reporter
from .models import Models


class Worker:
    def __init__(self):
        self.out = sys.stdout
        sys.stdout = sys.stderr  # stray prints from libraries must not corrupt the protocol
        self.lock = threading.Lock()
        self.commands: queue.Queue = queue.Queue()
        self.cancel = threading.Event()
        self.busy = False
        self.inflight = 0  # process commands received but not finished (guarded by lock)
        self.cfg = Config.load()
        self.models = Models(self.cfg, keep=self.cfg.keep_models_warm, log=lambda m: print(redact(m), file=sys.stderr, flush=True))

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
            if cmd.get("cmd") == "process":
                with self.lock:
                    self.inflight += 1
            if cmd.get("cmd") == "ping":
                self.send({"event": "pong", "busy": self.busy, "warm": self.models.loaded})
                continue
            self.commands.put(cmd)
        self.commands.put({"cmd": "quit"})

    def serve(self) -> int:
        threading.Thread(target=self._read_stdin, name="stdin", daemon=True).start()
        self.send({"event": "worker", "status": "ready", "pid": os.getpid()})
        while True:
            try:
                cmd = self.commands.get(timeout=15)
            except queue.Empty:
                if self._idle_exit():
                    return 0
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

    def _warmup(self) -> None:
        self.cfg = Config.load()
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
        from .pipeline import Processor

        job = str(cmd.get("job") or "job")
        folder = Path(str(cmd.get("folder") or "")).expanduser()
        if not folder.is_dir():
            self._finish_job()
            self.send({"event": "error", "job": job, "message": f"Not a folder: {folder}"})
            self.send({"event": "job_end", "job": job, "exit": 2})
            return
        self.cfg = Config.load()
        self.models.update_config(self.cfg)
        self.busy = True
        reporter = Reporter(json_mode=True, out=_Locked(self), job=job, cancel=self.cancel)
        code = 0
        try:
            Processor(folder, self.cfg, reporter, self.models).run("prepare" if cmd.get("force") else cmd.get("from"))
        except Cancelled:
            code = 3
        except Exception:
            code = 1
        finally:
            self.busy = False
            self._finish_job()
            self.models.last_used = time.monotonic()
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
