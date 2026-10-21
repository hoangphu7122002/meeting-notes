"""System load for live back-pressure (LoadProbe): memory pressure, CPU load, thermal state, power source.

Memory pressure and thermal state come from cheap kernel/notify calls (ctypes); the power source from
`pmset -g batt`, cached for 30 s. Any failure reads as "no pressure" so live never stops on a probe error.
"""

from __future__ import annotations

import ctypes
import os
import subprocess
import time

from ...domain.live_backlog import LoadSample

BATTERY_CACHE_SEC = 30.0


def _libc():
    try:
        return ctypes.CDLL("libc.dylib", use_errno=True)
    except OSError:
        return None


def memory_pressure_level(libc=None) -> int:
    """kern.memorystatus_vm_pressure_level: 1 normal, 2 warn, 4 critical; 0 when unknown."""
    libc = libc or _libc()
    if libc is None:
        return 0
    value, size = ctypes.c_int(0), ctypes.c_size_t(ctypes.sizeof(ctypes.c_int))
    ok = libc.sysctlbyname(b"kern.memorystatus_vm_pressure_level", ctypes.byref(value), ctypes.byref(size), None, 0) == 0
    return value.value if ok else 0


def thermal_level(libc=None) -> int:
    """com.apple.system.thermalpressurelevel via notify(3): 0 nominal, 1 moderate, 2 heavy, 3 trapping, 4 sleeping."""
    libc = libc or _libc()
    if libc is None:
        return 0
    token, state = ctypes.c_int(0), ctypes.c_uint64(0)
    try:
        if libc.notify_register_check(b"com.apple.system.thermalpressurelevel", ctypes.byref(token)) != 0:
            return 0
        ok = libc.notify_get_state(token, ctypes.byref(state)) == 0
        libc.notify_cancel(token)
    except AttributeError:
        return 0
    return int(state.value) if ok else 0


def on_battery() -> bool:
    try:
        out = subprocess.run(["pmset", "-g", "batt"], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return False
    return "Battery Power" in out


class SystemLoadProbe:
    def __init__(self, clock=time.monotonic):
        self.clock = clock
        self.libc = _libc()
        self._battery: tuple[float, bool] | None = None

    def sample(self) -> LoadSample:
        now = self.clock()
        if self._battery is None or now - self._battery[0] >= BATTERY_CACHE_SEC:
            self._battery = (now, on_battery())
        try:
            busy = os.getloadavg()[0] / (os.cpu_count() or 1)
        except OSError:
            busy = 0.0
        return LoadSample(memory_pressure_level(self.libc), busy, thermal_level(self.libc), self._battery[1])
