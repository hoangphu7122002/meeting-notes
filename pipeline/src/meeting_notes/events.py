"""Progress reporting: JSON lines on stdout (for the app) or plain text on stderr."""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

from .config import redact

# Rough share of total processing time per stage, used for the overall fraction.
STAGE_WEIGHTS = {
    "prepare": 0.05,
    "diarize": 0.25,
    "transcribe": 0.45,
    "summarize": 0.22,
    "render": 0.02,
    "finalize": 0.01,
}
STAGES = list(STAGE_WEIGHTS)


class Reporter:
    def __init__(self, json_mode: bool = False, log_file: Path | None = None):
        self.json_mode = json_mode
        self.log_file = log_file
        # In JSON mode stdout is reserved for events: anything else printing to stdout goes to stderr.
        self.out = sys.stdout
        if json_mode:
            sys.stdout = sys.stderr
        self.stage: str | None = None
        self.fraction = 0.0

    def _overall(self) -> float:
        if self.stage is None:
            return 0.0
        idx = STAGES.index(self.stage)
        done = sum(STAGE_WEIGHTS[s] for s in STAGES[:idx])
        return round(min(1.0, done + STAGE_WEIGHTS[self.stage] * self.fraction), 4)

    def _emit(self, event: dict) -> None:
        for key in ("message",):
            if isinstance(event.get(key), str):
                event[key] = redact(event[key])
        line = json.dumps(event, ensure_ascii=False)
        if self.log_file:
            with self.log_file.open("a", encoding="utf-8") as f:
                f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {line}\n")
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
            elif event["event"] == "done":
                text = f"notes: {event.get('notes')}"
            print(f"[{prefix}] {text}", file=sys.stderr, flush=True)

    def stage_start(self, stage: str, message: str = "") -> None:
        self.stage, self.fraction = stage, 0.0
        self._emit({"event": "stage", "stage": stage, "status": "start", "message": message, "overall": self._overall()})

    def stage_end(self, stage: str, status: str = "done", message: str = "") -> None:
        self.stage, self.fraction = stage, 1.0
        self._emit({"event": "stage", "stage": stage, "status": status, "message": message, "overall": self._overall()})

    def progress(self, fraction: float, message: str = "") -> None:
        self.fraction = max(0.0, min(1.0, fraction))
        self._emit({
            "event": "progress", "stage": self.stage, "fraction": round(self.fraction, 4),
            "message": message, "overall": self._overall(),
        })

    def warning(self, message: str) -> None:
        self._emit({"event": "warning", "stage": self.stage, "message": message})

    def error(self, message: str) -> None:
        self._emit({"event": "error", "stage": self.stage, "message": message})

    def done(self, folder: Path, notes: Path, title: str) -> None:
        self._emit({"event": "done", "folder": str(folder), "notes": str(notes), "title": title, "overall": 1.0})

    def log(self, message: str) -> None:
        """Diagnostic line: log file + stderr, never stdout."""
        message = redact(message)
        if self.log_file:
            with self.log_file.open("a", encoding="utf-8") as f:
                f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {message}\n")
        print(message, file=sys.stderr, flush=True)
