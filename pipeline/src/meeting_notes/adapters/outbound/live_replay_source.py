"""Replay a finished recording as if it were being recorded (`meeting-notes live --simulate <speed>`).

LiveAudioSource for tests and benchmarks: decodes each track once (ffmpeg, 16 kHz) and releases audio at
`speed` x real time from the first poll. Read-only on the meeting folder's audio.
"""

from __future__ import annotations

import json
import time
from collections.abc import Callable
from pathlib import Path

import numpy as np

from ...domain.signal import SR


class ReplaySource:
    def __init__(self, folder: Path, speed: float, decode: Callable[[Path], np.ndarray], clock=time.monotonic):
        meta = json.loads((folder / "meeting.json").read_text(encoding="utf-8"))
        self.audio: dict[str, np.ndarray] = {}
        self.offsets: dict[str, float] = {}
        for name, info in (meta.get("tracks") or {}).items():
            path, offset = folder / info["file"], float(info.get("start_offset_sec") or 0.0)
            if not path.exists():
                path, offset = folder / (Path(info["file"]).stem + ".m4a"), 0.0  # finalized: aligned m4a copies
            if path.exists():
                self.audio[name], self.offsets[name] = decode(path), offset
        self.speed, self.clock = max(speed, 0.01), clock
        self.t0: float | None = None
        self.sent = {name: 0 for name in self.audio}

    def _elapsed(self) -> float:
        if self.t0 is None:
            self.t0 = self.clock()
        return (self.clock() - self.t0) * self.speed

    def tracks(self) -> list[str]:
        return sorted(self.audio)

    def position(self, track: str) -> float:
        end = self.offsets[track] + len(self.audio[track]) / SR
        return min(end, max(self.offsets[track], self._elapsed()))

    def poll(self, track: str, max_sec: float) -> tuple[float, np.ndarray]:
        x, sent = self.audio[track], self.sent[track]
        upto = int(round((self.position(track) - self.offsets[track]) * SR))
        upto = min(upto, sent + int(max_sec * SR))
        self.sent[track] = max(sent, upto)
        return self.offsets[track] + sent / SR, x[sent:self.sent[track]]

    def finished(self) -> bool:
        return all(self.sent[t] >= len(x) for t, x in self.audio.items())
