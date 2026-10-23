"""Transcript segments: whisper output filtering, block splitting by length/language, language statistics."""

from __future__ import annotations

import re
from collections import defaultdict
from collections.abc import Callable
from dataclasses import dataclass

import numpy as np

from .signal import SR, frame_db
from .speakers import Block


@dataclass
class Segment:
    start: float
    end: float
    speaker: str
    track: str
    language: str
    text: str

    def to_dict(self) -> dict:
        return {
            "start": round(self.start, 2), "end": round(self.end, 2), "speaker": self.speaker,
            "track": self.track, "language": self.language, "text": self.text,
        }


_REPEAT = re.compile(r"(?i)\b((?:\S+\s+){0,5}?\S+?)(?:[\s,.;!?]+\1\b){3,}")


def collapse_repeats(text: str) -> str:
    """Collapse a phrase repeated 4+ times in a row (a whisper decoding loop) to a single copy."""
    prev = None
    while prev != text:
        prev, text = text, _REPEAT.sub(r"\1", text)
    return text


def split_long_blocks(blocks: list[Block], audio_by_track: dict[str, np.ndarray], max_len: float = 45.0) -> list[Block]:
    """Split blocks longer than `max_len` at the quietest 0.3 s inside the last third of each piece."""
    out: list[Block] = []
    for b in blocks:
        start = b.start
        while b.end - start > max_len:
            lo, hi = start + max_len * 0.6, start + max_len
            db = frame_db(audio_by_track[b.track][int(lo * SR): int(hi * SR)])
            if db.size >= 15:
                smooth = np.convolve(db, np.ones(15) / 15, mode="valid")
                cut = lo + (int(np.argmin(smooth)) + 7) * 0.02
            else:
                cut = hi
            out.append(Block(start, cut, b.speaker, b.track, clip_parts(b.parts, start, cut)))
            start = cut
        out.append(Block(start, b.end, b.speaker, b.track, clip_parts(b.parts, start, b.end)))
    return out


def clip_parts(parts: list[tuple[float, float]], start: float, end: float) -> list[tuple[float, float]]:
    return [(max(s, start), min(e, end)) for s, e in parts if min(e, end) > max(s, start)]


def split_by_language(blocks: list[Block], detect: Callable[[Block, float, float], str], min_part: float = 1.5) -> list[Block]:
    """Split multi-turn blocks where the speaker switches language between turns.

    Whisper fixes one language per call (detected on the first 30 s), so a block that starts in
    Vietnamese and continues in English would otherwise be forced into Vietnamese.
    """
    out: list[Block] = []
    for b in blocks:
        parts = [p for p in b.parts if p[1] - p[0] >= min_part]
        if len(parts) < 2:
            out.append(b)
            continue
        langs = [detect(b, s, e) for s, e in parts]
        if len(set(langs)) == 1:
            out.append(b)
            continue
        # Cut points: start of each detected part whose language differs from the previous one.
        cuts = [parts[i][0] for i in range(1, len(parts)) if langs[i] != langs[i - 1]]
        bounds = [b.start, *cuts, b.end]
        for s, e in zip(bounds, bounds[1:]):
            out.append(Block(s, e, b.speaker, b.track, clip_parts(b.parts, s, e)))
    return out


def choose_language(probs: dict[str, float], allowed: list[str], prior: dict[str, float] | None, short: bool) -> str:
    """Pick the block language, restricted to `allowed`, leaning on the speaker's history for short blocks."""
    candidates = {k: v for k, v in probs.items() if not allowed or k in allowed} or probs
    best = max(candidates, key=candidates.get)
    if short and prior:
        favourite = max(prior, key=prior.get)
        if favourite in candidates and candidates[best] < 0.8:
            return favourite
    return best


def language_stats(segments: list[Segment]) -> dict[str, float]:
    stats: dict[str, float] = defaultdict(float)
    for s in segments:
        stats[s.language] += max(0.0, s.end - s.start) + 0.01 * len(s.text)
    return dict(sorted(stats.items(), key=lambda kv: -kv[1]))
