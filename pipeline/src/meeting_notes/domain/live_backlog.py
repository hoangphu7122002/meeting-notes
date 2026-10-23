"""Live transcription back-pressure: decide per poll whether to decode, wait, or leave audio to Stop (pure).

Capture never waits on this: the app only writes WAVs. Skipped spans are not lost, the Stop-time pass
decodes them like today.
"""

from __future__ import annotations

from dataclasses import dataclass

PROCESS, DEFER, SKIP = "process", "defer", "skip"

PRESSURE_NORMAL = 1  # kern.memorystatus_vm_pressure_level: 1 normal, 2 warn, 4 critical (0 = unknown)
PRESSURE_WARN = 2
PRESSURE_CRITICAL = 4
THERMAL_SERIOUS = 2  # com.apple.system.thermalpressurelevel: 0 nominal, 1 moderate, 2 heavy, 3+ trapping


@dataclass(frozen=True)
class LoadSample:
    memory_pressure: int = 0
    cpu_busy: float = 0.0  # 1-minute load average / CPU count
    thermal: int = 0
    on_battery: bool = False


@dataclass(frozen=True)
class BacklogPolicy:
    max_backlog_sec: float = 120.0  # undecoded audio beyond this is skipped, oldest first
    on_battery: bool = False  # run live on battery power
    max_cpu_busy: float = 0.9
    pause_pressure: int = PRESSURE_CRITICAL  # defer at this memory pressure level or worse (warn = 2, critical = 4)


@dataclass(frozen=True)
class Decision:
    action: str  # PROCESS | DEFER | SKIP
    reason: str | None = None  # memory | cpu | thermal | battery | backlog


def decide(backlog_sec: float, load: LoadSample, policy: BacklogPolicy) -> Decision:
    """Skip everything on battery (unless allowed) and the oldest audio over the backlog limit; defer while the
    Mac is at `pause_pressure` or worse (default critical) or under CPU or thermal pressure; otherwise decode the next chunk."""
    if load.on_battery and not policy.on_battery:
        return Decision(SKIP, "battery")
    if backlog_sec > policy.max_backlog_sec:
        return Decision(SKIP, "backlog")
    if load.memory_pressure >= policy.pause_pressure:
        return Decision(DEFER, "memory")
    if load.thermal >= THERMAL_SERIOUS:
        return Decision(DEFER, "thermal")
    if load.cpu_busy >= policy.max_cpu_busy:
        return Decision(DEFER, "cpu")
    return Decision(PROCESS)


def pause_pressure_level(name: object) -> int:
    """Config value "warn" | "critical" -> pressure level; anything else is critical (the default)."""
    return PRESSURE_WARN if str(name or "").strip().lower() == "warn" else PRESSURE_CRITICAL


def status_of(decision: Decision) -> str:
    """live_status state for a decision: running | deferred | throttled."""
    return {PROCESS: "running", DEFER: "deferred", SKIP: "throttled"}[decision.action]
