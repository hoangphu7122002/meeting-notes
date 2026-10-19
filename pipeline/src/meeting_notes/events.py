"""Progress reporting: JSON lines on stdout (for the app) or plain text on stderr.

Also tracks per-stage timings, estimates the remaining time from learned speed factors,
and implements cooperative cancellation (every progress call is a cancellation point).
"""

from __future__ import annotations

import json
import os
import sys
import threading
import time
from pathlib import Path

from .config import redact

# Rough share of total processing time per stage, used for the overall fraction.
STAGE_WEIGHTS = {
    "prepare": 0.03,
    "diarize": 0.25,
    "transcribe": 0.42,
    "summarize": 0.27,
    "render": 0.02,
    "finalize": 0.01,
}
STAGES = list(STAGE_WEIGHTS)

# Seconds of processing per second of audio, plus a fixed overhead (model load etc.).
# Updated from real runs in TIMINGS_PATH (exponential moving average).
DEFAULT_SPEED = {
    "prepare": (0.004, 0.5),
    "diarize": (0.06, 4.0),
    "transcribe": (0.10, 3.0),
    "summarize": (0.05, 12.0),
    "render": (0.0, 0.1),
    "finalize": (0.0, 0.3),
}
TIMINGS_PATH = Path(os.environ.get("MEETING_NOTES_CACHE", "~/.cache/meeting-notes")).expanduser() / "timings.json"


class Cancelled(Exception):
    pass


def load_speed() -> dict[str, list[float]]:
    speed = {k: list(v) for k, v in DEFAULT_SPEED.items()}
    try:
        for k, v in json.loads(TIMINGS_PATH.read_text()).items():
            if k in speed and isinstance(v, list) and len(v) == 2:
                speed[k] = [float(v[0]), float(v[1])]
    except (OSError, ValueError):
        pass
    return speed


def learn_speed(stage: str, elapsed: float, audio_sec: float) -> None:
    """Fold a measured stage duration into the per-audio-second factor."""
    if audio_sec < 20 or stage not in DEFAULT_SPEED:
        return
    speed = load_speed()
    factor, overhead = speed[stage]
    measured = max(0.0, elapsed - overhead) / audio_sec
    speed[stage] = [round(0.6 * factor + 0.4 * measured, 5), overhead]
    try:
        TIMINGS_PATH.parent.mkdir(parents=True, exist_ok=True)
        TIMINGS_PATH.write_text(json.dumps(speed, indent=1))
    except OSError:
        pass


class Reporter:
    def __init__(self, json_mode: bool = False, log_file: Path | None = None, out=None, job: str | None = None,
                 cancel: threading.Event | None = None):
        self.json_mode = json_mode
        self.log_file = log_file
        self.job = job
        self.cancel = cancel or threading.Event()
        # In JSON mode stdout is reserved for events: anything else printing to stdout goes to stderr.
        self.out = out or sys.stdout
        if json_mode and out is None:
            sys.stdout = sys.stderr
        self.stage: str | None = None
        self.fraction = 0.0
        self.audio_sec: float | None = None
        self.speed = load_speed()
        self.timings: dict[str, float] = {}
        self._stage_t0 = time.monotonic()
        self._run_t0 = time.monotonic()
        self.skipped: set[str] = set()

    # ------------------------------------------------------------ estimates

    def _overall(self) -> float:
        if self.stage is None:
            return 0.0
        idx = STAGES.index(self.stage)
        done = sum(STAGE_WEIGHTS[s] for s in STAGES[:idx])
        return round(min(1.0, done + STAGE_WEIGHTS[self.stage] * self.fraction), 4)

    def _estimate(self, stage: str) -> float:
        factor, overhead = self.speed[stage]
        return overhead + factor * (self.audio_sec or 0.0)

    def eta(self) -> float | None:
        """Estimated seconds until the whole run finishes."""
        if self.audio_sec is None or self.stage is None:
            return None
        idx = STAGES.index(self.stage)
        elapsed = time.monotonic() - self._stage_t0
        if self.fraction >= 0.15 and elapsed > 2:
            current = elapsed / self.fraction * (1 - self.fraction)
        else:
            current = max(0.0, self._estimate(self.stage) - elapsed) if self.fraction < 1 else 0.0
        later = sum(self._estimate(s) for s in STAGES[idx + 1:] if s not in self.skipped)
        return round(current + later, 1)

    # ------------------------------------------------------------ output

    def _emit(self, event: dict) -> None:
        if isinstance(event.get("message"), str):
            event["message"] = redact(event["message"])
        if self.job:
            event["job"] = self.job
        line = json.dumps(event, ensure_ascii=False)
        if self.log_file:
            try:
                with self.log_file.open("a", encoding="utf-8") as f:
                    f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {line}\n")
            except OSError:
                pass
        if self.json_mode:
            self.out.write(line + "\n")
            self.out.flush()
        else:
            text = event.get("message") or ""
            prefix = event.get("stage") or event["event"]
            if event["event"] == "progress":
                text = f"{int(event.get('fraction', 0) * 100):3d}% {text}"
            elif event["event"] == "stage":
                text = f"{event['status']} {text}".strip()
                if event.get("elapsed_sec") is not None and event["status"] == "done":
                    text += f" ({event['elapsed_sec']:.1f}s)"
            elif event["event"] in ("done", "partial"):
                text = f"notes: {event.get('notes')}"
            print(f"[{prefix}] {text}", file=sys.stderr, flush=True)

    def check(self) -> None:
        if self.cancel.is_set():
            raise Cancelled("cancelled")

    def stage_start(self, stage: str, message: str = "") -> None:
        self.check()
        self.stage, self.fraction = stage, 0.0
        self._stage_t0 = time.monotonic()
        self._emit({"event": "stage", "stage": stage, "status": "start", "message": message,
                    "overall": self._overall(), "eta_sec": self.eta()})

    def stage_end(self, stage: str, status: str = "done", message: str = "") -> None:
        self.stage, self.fraction = stage, 1.0
        elapsed = None
        if status == "skipped":
            self.skipped.add(stage)
        else:
            elapsed = round(time.monotonic() - self._stage_t0, 2)
            self.timings[stage] = elapsed
            if status == "done" and self.audio_sec:
                learn_speed(stage, elapsed, self.audio_sec)
        self._emit({"event": "stage", "stage": stage, "status": status, "message": message,
                    "overall": self._overall(), "elapsed_sec": elapsed, "eta_sec": self.eta()})

    def progress(self, fraction: float, message: str = "") -> None:
        self.check()
        self.fraction = max(0.0, min(1.0, fraction))
        self._emit({
            "event": "progress", "stage": self.stage, "fraction": round(self.fraction, 4),
            "message": message, "overall": self._overall(), "eta_sec": self.eta(),
        })

    def warning(self, message: str) -> None:
        self._emit({"event": "warning", "stage": self.stage, "message": message})

    def error(self, message: str) -> None:
        self._emit({"event": "error", "stage": self.stage, "message": message})

    def cancelled(self, folder: Path) -> None:
        self._emit({"event": "cancelled", "stage": self.stage, "folder": str(folder), "message": "Processing cancelled"})

    def partial(self, folder: Path, notes: Path) -> None:
        """First result: notes.md with the transcript exists, summary still running."""
        self._emit({"event": "partial", "folder": str(folder), "notes": str(notes),
                    "elapsed_sec": round(time.monotonic() - self._run_t0, 1)})

    def done(self, folder: Path, notes: Path, title: str) -> None:
        self._emit({"event": "done", "folder": str(folder), "notes": str(notes), "title": title, "overall": 1.0,
                    "timings": self.timings, "total_sec": round(time.monotonic() - self._run_t0, 1)})

    def log(self, message: str) -> None:
        """Diagnostic line: log file + stderr, never stdout."""
        message = redact(message)
        if self.log_file:
            try:
                with self.log_file.open("a", encoding="utf-8") as f:
                    f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {message}\n")
            except OSError:
                pass
        print(message, file=sys.stderr, flush=True)
