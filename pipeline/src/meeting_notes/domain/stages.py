"""Pipeline stage names, their share of the total run time and default speed estimates."""

from __future__ import annotations

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
