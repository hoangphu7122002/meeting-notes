"""Keep-warm policy for the worker's models (pure): hold whisper/pyannote between stages and jobs only while
memory allows. RAM safety beats speed on a 16 GB Mac: "auto" keeps a model only under "normal" pressure.

`keep_models_warm` (config) accepts True/"on", False/"off" or "auto" (default).
"""

from __future__ import annotations

from .live_backlog import PRESSURE_NORMAL

PRESSURE_CRITICAL = 4  # kern.memorystatus_vm_pressure_level: 1 normal, 2 warn, 4 critical (0 = unknown)

OFF, ON, AUTO = "off", "on", "auto"


def warm_mode(value: object) -> str:
    """Normalize a `keep_models_warm` value; anything unrecognized means "auto"."""
    if value is True or (isinstance(value, str) and value.strip().lower() in ("on", "true", "yes", "1")):
        return ON
    if value is False or value is None or (isinstance(value, str) and value.strip().lower() in ("off", "false", "no", "0")):
        return OFF
    return AUTO


def keep_warm(mode: str, pressure: int) -> bool:
    """Whether a loaded model may stay resident now.

    off: never. on: unless pressure is critical. auto: only under "normal" pressure (unknown counts as not normal)."""
    if mode == OFF:
        return False
    if mode == ON:
        return pressure < PRESSURE_CRITICAL
    return pressure == PRESSURE_NORMAL
