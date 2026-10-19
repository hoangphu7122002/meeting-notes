"""Keep processing light: background QoS and bounded thread pools. Call before importing torch."""

from __future__ import annotations

import ctypes
import os

PRIO_DARWIN_PROCESS = 4
PRIO_DARWIN_BG = 0x1000


def limit_threads(n: int) -> None:
    n = max(1, int(n))
    for var in ("OMP_NUM_THREADS", "MKL_NUM_THREADS", "VECLIB_MAXIMUM_THREADS", "OPENBLAS_NUM_THREADS", "NUMEXPR_NUM_THREADS"):
        os.environ.setdefault(var, str(n))
    os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")


def apply_torch_threads(n: int) -> None:
    try:
        import torch

        torch.set_num_threads(max(1, int(n)))
        torch.set_num_interop_threads(1)
    except Exception:
        pass  # interop threads can only be set once per process


QOS_CLASS_UTILITY = 0x11


def low_priority() -> bool:
    """Utility QoS + nice 10: yields CPU to interactive apps without throttling I/O.

    Darwin background mode (`background_priority`) is gentler still but measured ~3x slower
    compute and 5-8x slower model loading, so it is opt-in.
    """
    ok = True
    try:
        os.nice(10)
    except OSError:
        ok = False
    try:
        libc = ctypes.CDLL("libc.dylib", use_errno=True)
        ok = libc.pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0) == 0 and ok
    except (OSError, AttributeError):
        ok = False
    return ok


def apply_priority(mode: str) -> bool:
    if mode == "background":
        return background_priority()
    if mode == "low":
        return low_priority()
    return True


def background_priority() -> bool:
    """macOS background QoS for this process and its children (same as `taskpolicy -b`)."""
    try:
        libc = ctypes.CDLL("libc.dylib", use_errno=True)
        return libc.setpriority(PRIO_DARWIN_PROCESS, 0, PRIO_DARWIN_BG) == 0
    except OSError:
        return False
