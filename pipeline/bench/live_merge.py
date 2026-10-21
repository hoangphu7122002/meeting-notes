"""Prototype of `domain/partial_merge.py` (realtime.md 4.1): reuse live partial segments after Stop.

Pure functions over plain dicts and `Turn`s (the diarization turns already carry the resolved mic/system
labels and the mic bleed rule: mic turns overlapping remote speech were dropped by `resolve_two_tracks`).
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass, field

from meeting_notes.domain.intervals import Interval, merge_gaps, overlap, subtract
from meeting_notes.domain.speakers import Turn

MIN_COVER = 0.5  # share of a segment inside same-track turns; below = bleed / not diarized speech -> dropped
AMBIGUOUS = 0.30  # minority speaker share of a segment above which the span is re-decoded


@dataclass
class MergeResult:
    segments: list[dict] = field(default_factory=list)
    uncovered: dict[str, list[Interval]] = field(default_factory=dict)  # per track, inside turns
    dropped: list[dict] = field(default_factory=list)  # outside turns (bleed rule)
    ambiguous: list[dict] = field(default_factory=list)
    minority_sec: float = 0.0  # speech seconds attributed to the majority speaker that belong to a minority one


STRICT_MINORITY_SEC = 1.0  # strict rule: a chunk with this much speech of a second speaker is re-decoded whole


def merge_partials(turns: list[Turn], partials: list[dict], min_cover: float = MIN_COVER,
                   ambiguous: float = AMBIGUOUS, strict: bool = False) -> MergeResult:
    """Assign each live segment the diarization speaker with the largest overlap.

    - Segment mostly outside same-track turns: dropped (mic bleed / not speech per diarization).
    - Minority speaker > `ambiguous` of the segment: dropped and its span is returned as uncovered.
    - Uncovered = turn time not inside a live chunk that was decoded (tail, skipped chunks) + ambiguous spans.
    - `strict` (variant beyond the 4.1 text): also re-decode whole chunks that were cut by force or that span
      a second speaker for >= STRICT_MINORITY_SEC (whisper fixes one language per call and may merge speakers).
    """
    by_track: dict[str, list[Turn]] = defaultdict(list)
    for t in turns:
        by_track[t.track].append(t)
    res = MergeResult()
    decoded: dict[str, list[Interval]] = defaultdict(list)
    bad: dict[str, list[Interval]] = defaultdict(list)
    for chunk in partials:
        if chunk.get("tail"):
            continue  # not decoded live: left to the Stop-time pass
        decoded[chunk["track"]].append((chunk["start"], chunk["end"]))
        if strict and _redo_chunk(chunk, by_track[chunk["track"]]):
            res.ambiguous += chunk["segments"]
            bad[chunk["track"]].append((chunk["start"], chunk["end"]))
            continue
        for seg in chunk["segments"]:
            dur = max(seg["end"] - seg["start"], 1e-6)
            per: dict[str, float] = defaultdict(float)
            for t in by_track[seg["track"]]:
                per[t.speaker] += overlap((seg["start"], seg["end"]), (t.start, t.end))
            if sum(per.values()) / dur < min_cover:
                res.dropped.append(seg)
                continue
            ranked = sorted(per.items(), key=lambda kv: -kv[1])
            minority = sum(v for _, v in ranked[1:])
            if minority / dur > ambiguous:
                res.ambiguous.append(seg)
                bad[seg["track"]].append((seg["start"], seg["end"]))
                continue
            res.minority_sec += minority
            res.segments.append({**seg, "speaker": ranked[0][0]})
    for track, ts in by_track.items():
        need = merge_gaps([(t.start, t.end) for t in ts], 0.0)
        covered = subtract(merge_gaps(decoded[track], 0.0), bad[track])
        res.uncovered[track] = subtract(need, covered)
    res.segments.sort(key=lambda s: (s["start"], s["end"]))
    return res


def _redo_chunk(chunk: dict, turns: list[Turn]) -> bool:
    per: dict[str, float] = defaultdict(float)
    for t in turns:
        per[t.speaker] += overlap((chunk["start"], chunk["end"]), (t.start, t.end))
    minority = sum(per.values()) - max(per.values(), default=0.0)
    return bool(chunk.get("forced")) and sum(per.values()) > 0 or minority >= STRICT_MINORITY_SEC


def clip_turns(turns: list[Turn], uncovered: dict[str, list[Interval]]) -> list[Turn]:
    """Turn pieces inside the uncovered intervals: input of the Stop-time `transcribe_blocks` pass."""
    out = []
    for t in turns:
        for s, e in uncovered.get(t.track, []):
            lo, hi = max(s, t.start), min(e, t.end)
            if hi - lo >= 0.05:
                out.append(Turn(lo, hi, t.speaker, t.track))
    return out
