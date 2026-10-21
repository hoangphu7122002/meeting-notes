"""Interval arithmetic on (start, end) second pairs, and frame masks to intervals."""

from __future__ import annotations

import numpy as np

Interval = tuple[float, float]


def runs(mask: np.ndarray, frame_sec: float) -> list[Interval]:
    """Contiguous True runs of a boolean frame mask as (start, end) seconds."""
    if mask.size == 0:
        return []
    padded = np.concatenate([[False], mask, [False]])
    diff = np.diff(padded.astype(np.int8))
    starts = np.flatnonzero(diff == 1)
    ends = np.flatnonzero(diff == -1)
    return [(s * frame_sec, e * frame_sec) for s, e in zip(starts, ends)]


def merge_gaps(intervals: list[Interval], max_gap: float) -> list[Interval]:
    out: list[list[float]] = []
    for s, e in sorted(intervals):
        if out and s - out[-1][1] <= max_gap:
            out[-1][1] = max(out[-1][1], e)
        else:
            out.append([s, e])
    return [(s, e) for s, e in out]


def subtract(intervals: list[Interval], remove: list[Interval]) -> list[Interval]:
    """Set difference of two interval lists."""
    remove = merge_gaps(remove, 0.0)
    out: list[Interval] = []
    for s, e in sorted(intervals):
        cur = s
        for rs, re_ in remove:
            if re_ <= cur or rs >= e:
                continue
            if rs > cur:
                out.append((cur, rs))
            cur = max(cur, re_)
            if cur >= e:
                break
        if cur < e:
            out.append((cur, e))
    return out


def total(intervals: list[Interval]) -> float:
    return sum(e - s for s, e in intervals)


def overlap(a: Interval, b: Interval) -> float:
    return max(0.0, min(a[1], b[1]) - max(a[0], b[0]))


def dilate(intervals: list[Interval], before: float, after: float) -> list[Interval]:
    return merge_gaps([(max(0.0, s - before), e + after) for s, e in intervals], 0.0)
