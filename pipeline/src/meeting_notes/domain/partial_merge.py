"""Reuse live partial transcripts after Stop (design A, strict rule; docs/research/realtime-feasibility.md).

A live chunk is reused only when it was cut at a natural pause (not forced at max length), no second
diarization speaker of its track covers >= STRICT_MINORITY_SEC of it, and none of its segments has a minority
speaker above AMBIGUOUS. Everything else (tail, skipped, silent, bleed and rejected chunks) stays `uncovered`
and is decoded offline exactly like today, so the final transcript keeps the offline quality.
"""

from __future__ import annotations

import json
from collections import defaultdict
from dataclasses import dataclass, field

from .intervals import Interval, merge_gaps, overlap, subtract, total
from .segments import Segment
from .speakers import Turn

PARTIAL_VERSION = 1
MIN_COVER = 0.5  # share of a segment inside same-track turns; below = bleed / not speech per diarization
AMBIGUOUS = 0.30  # minority speaker share of a segment above which the whole chunk is re-decoded
STRICT_MINORITY_SEC = 1.0  # a second speaker this long inside a chunk: re-decode the chunk


@dataclass
class MergeResult:
    segments: list[Segment] = field(default_factory=list)
    uncovered: dict[str, list[Interval]] = field(default_factory=dict)  # per track, inside turns
    reused_sec: float = 0.0  # diarized speech covered by reused chunks
    decoded_sec: float = 0.0  # diarized speech left to the Stop-time pass
    rejected: int = 0  # decoded chunks re-decoded by the strict rule


def config_signature(fields: dict) -> str:
    """Stable 64-bit FNV-1a hex digest of the settings that change live decoding (model, prompt, VAD, ...)."""
    h = 0xCBF29CE484222325
    for byte in json.dumps(fields, sort_keys=True, ensure_ascii=False).encode("utf-8"):
        h = ((h ^ byte) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return f"{h:016x}"


def usable_partials(lines: list[dict], signature: str) -> list[dict]:
    """Decoded chunks of the current format and configuration (others are re-decoded at Stop)."""
    return [c for c in lines if c.get("v") == PARTIAL_VERSION and c.get("status") == "decoded"
            and c.get("signature") == signature]


def _speaker_seconds(span: Interval, turns: list[Turn]) -> dict[str, float]:
    per: dict[str, float] = defaultdict(float)
    for t in turns:
        if (o := overlap(span, (t.start, t.end))) > 0:
            per[t.speaker] += o
    return per


def _reuse_chunk(chunk: dict, turns: list[Turn]) -> list[Segment] | None:
    """Segments of an acceptable chunk with diarization speakers, or None when it must be re-decoded."""
    if chunk.get("forced"):
        return None
    per = _speaker_seconds((chunk["start"], chunk["end"]), turns)
    if sum(per.values()) - max(per.values(), default=0.0) >= STRICT_MINORITY_SEC:
        return None
    out = []
    for seg in chunk.get("segments", []):
        dur = max(seg["end"] - seg["start"], 1e-6)
        seg_per = _speaker_seconds((seg["start"], seg["end"]), turns)
        if sum(seg_per.values()) / dur < MIN_COVER:
            continue  # outside the resolved turns: mic bleed or not speech for diarization (offline skips it too)
        best = max(seg_per, key=seg_per.get)
        if sum(seg_per.values()) - seg_per[best] > AMBIGUOUS * dur:
            return None
        out.append(Segment(seg["start"], seg["end"], best, chunk["track"], chunk.get("language", ""), seg["text"]))
    return out


def merge_partials(turns: list[Turn], partials: list[dict]) -> MergeResult:
    """Reusable live segments (speaker = diarization speaker with the largest overlap) and the turn time
    still to decode per track."""
    by_track: dict[str, list[Turn]] = defaultdict(list)
    for t in turns:
        by_track[t.track].append(t)
    res = MergeResult()
    covered: dict[str, list[Interval]] = defaultdict(list)
    for chunk in sorted(partials, key=lambda c: (c["track"], c["start"])):
        segments = _reuse_chunk(chunk, by_track.get(chunk["track"], []))
        if segments is None:
            res.rejected += 1
            continue
        covered[chunk["track"]].append((chunk["start"], chunk["end"]))
        res.segments += segments
    for track, ts in by_track.items():
        need = merge_gaps([(t.start, t.end) for t in ts], 0.0)
        res.uncovered[track] = subtract(need, merge_gaps(covered[track], 0.0))
        res.decoded_sec += total(res.uncovered[track])
        res.reused_sec += total(need) - total(res.uncovered[track])
    res.segments.sort(key=lambda s: (s.start, s.end))
    return res


def clip_turns(turns: list[Turn], uncovered: dict[str, list[Interval]], min_sec: float = 0.05) -> list[Turn]:
    """Turn pieces inside the uncovered intervals: the input of the Stop-time `transcribe_blocks` pass."""
    out = []
    for t in turns:
        for s, e in uncovered.get(t.track, []):
            lo, hi = max(s, t.start), min(e, t.end)
            if hi - lo >= min_sec:
                out.append(Turn(lo, hi, t.speaker, t.track))
    return out
