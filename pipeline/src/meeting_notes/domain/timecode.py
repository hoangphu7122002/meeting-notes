"""Time and date text formats shared by notes, folder names and meeting.json."""

from __future__ import annotations

import re
from datetime import datetime


def timestamp(sec: float) -> str:
    """Seconds -> "HH:MM:SS" (negative values count as 0)."""
    sec = int(max(0, sec))
    return f"{sec // 3600:02d}:{sec % 3600 // 60:02d}:{sec % 60:02d}"


def parse_time(value, default: float = 0.0) -> float:
    """"[00:12:59]" / "12:59" / "00:12:59" -> seconds; anything else -> default."""
    m = re.search(r"(?:(\d{1,2}):)?(\d{1,2}):(\d{2})", str(value or ""))
    if not m:
        return default
    h, mi, se = (int(x) if x else 0 for x in m.groups())
    return float(h * 3600 + mi * 60 + se)


def folder_stamp(when: datetime) -> str:
    """Meeting folder date prefix, e.g. "2026-10-19 1430"."""
    return when.strftime("%Y-%m-%d %H%M")


def iso_seconds(when: datetime) -> str:
    """Local time with UTC offset, whole seconds (meeting.json / status.json)."""
    return when.astimezone().isoformat(timespec="seconds")
