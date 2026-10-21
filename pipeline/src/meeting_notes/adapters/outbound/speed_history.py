"""Per-stage speed factors learned from real runs (exponential moving average in a cache file)."""

from __future__ import annotations

import json
import os
from pathlib import Path

from ...domain.stages import DEFAULT_SPEED

TIMINGS_PATH = Path(os.environ.get("MEETING_NOTES_CACHE", "~/.cache/meeting-notes")).expanduser() / "timings.json"


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
