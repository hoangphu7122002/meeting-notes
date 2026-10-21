"""Stop-time reuse of live partials: which turns still need the offline decoder (strict rule, partial_merge)."""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass, field

from ..config import Config
from ..domain.partial_merge import clip_turns, merge_partials, usable_partials
from ..domain.segments import Segment
from ..domain.speakers import Turn
from .live_transcribe import live_signature


@dataclass
class ReusePlan:
    turns: list[Turn]  # what the offline pass decodes
    reused: list[Segment] = field(default_factory=list)
    extra: dict = field(default_factory=dict)  # extra transcribe_blocks kwargs (language prior)
    live: dict | None = None  # transcript.json "live" stats; None = no partials (today's path, unchanged)


def plan_reuse(turns: list[Turn], lines: list[dict], cfg: Config) -> ReusePlan:
    partials = usable_partials(lines, live_signature(cfg))
    if not partials:
        return ReusePlan(turns)
    merged = merge_partials(turns, partials)
    prior: dict[str, dict[str, float]] = defaultdict(lambda: defaultdict(float))
    for s in merged.segments:
        prior[s.speaker][s.language] += s.end - s.start
    live = {"reused_sec": round(merged.reused_sec, 1), "decoded_sec": round(merged.decoded_sec, 1),
            "chunks_reused": len(partials) - merged.rejected, "chunks_redone": merged.rejected}
    return ReusePlan(clip_turns(turns, merged.uncovered), merged.segments, {"prior": {k: dict(v) for k, v in prior.items()}}, live)
