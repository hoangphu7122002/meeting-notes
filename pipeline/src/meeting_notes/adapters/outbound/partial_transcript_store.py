"""`.work/transcript.partial.jsonl`: append-only live partials, one JSON line per chunk (PartialTranscriptStore).

Each append is flushed and fsynced, so a crash loses at most the line being written; a truncated last line is
ignored on load and terminated before the next append.
"""

from __future__ import annotations

import json
import os
from pathlib import Path


class PartialTranscriptFile:
    def __init__(self, path: Path):
        self.path = path

    def load(self) -> list[dict]:
        try:
            text = self.path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            return []
        out = []
        for line in text.splitlines():
            try:
                value = json.loads(line)
            except ValueError:
                continue  # truncated (crash mid-write) or foreign line
            if isinstance(value, dict) and {"track", "seq", "start", "end"} <= value.keys():
                out.append(value)
        return out

    def append(self, chunk: dict) -> None:
        self.path.parent.mkdir(exist_ok=True)  # .work only: never recreates a deleted meeting folder
        line = json.dumps(chunk, ensure_ascii=False, separators=(",", ":")) + "\n"
        with self.path.open("a+b") as f:
            if f.tell() > 0:
                f.seek(-1, os.SEEK_END)
                if f.read(1) != b"\n":
                    line = "\n" + line  # close a truncated line so this one stays parseable
            f.write(line.encode("utf-8"))
            f.flush()
            os.fsync(f.fileno())
