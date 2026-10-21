"""Metrics shared by the T3/T4 benches: normalised WER/CER (reusing the repo helpers), gating, language agreement."""

from __future__ import annotations

import numpy as np

from meeting_notes.domain.intervals import Interval, merge_gaps, overlap, total
from meeting_notes.domain.metrics import edit_distance, term_hits, wer, words

CER_MAX_CELLS = 6_000_000  # pure-python edit distance: skip CER beyond this reference x hypothesis size


def text_of(segs: list[dict], track: str | None = None) -> str:
    keep = [s for s in segs if track is None or s["track"] == track]
    return " ".join(s["text"] for s in sorted(keep, key=lambda s: (s["start"], s["end"])))


def cer_counts(ref: str, hyp: str) -> tuple[int, int]:
    r, h = " ".join(words(ref)), " ".join(words(hyp))
    if len(r) * len(h) > CER_MAX_CELLS:
        return 0, 0
    return edit_distance(list(r), list(h)), len(r)


def compare(ref: list[dict], hyp: list[dict]) -> dict:
    """WER/CER of `hyp` against `ref` (reference = offline transcript), summed over tracks."""
    we = wn = ce = cn = 0
    for track in sorted({s["track"] for s in ref} | {s["track"] for s in hyp}):
        r, h = text_of(ref, track), text_of(hyp, track)
        e, n = wer(r, h)
        c, m = cer_counts(r, h)
        we, wn, ce, cn = we + e, wn + n, ce + c, cn + m
    return {"wer": we / wn if wn else None, "cer": ce / cn if cn else None, "wer_errors": we, "ref_words": wn,
            "hyp_words": len(words(text_of(hyp)))}


def coverage(seg: dict, turns: list[Interval]) -> float:
    dur = seg["end"] - seg["start"]
    if dur <= 0:
        return 0.0
    return sum(overlap((seg["start"], seg["end"]), t) for t in turns) / dur


def gate(segs: list[dict], turns, min_cover: float = 0.5) -> list[dict]:
    """Segments mostly inside a diarization turn of their track (offline never decodes outside turns)."""
    by_track: dict[str, list[Interval]] = {}
    for t in turns:
        by_track.setdefault(t.track, []).append((t.start, t.end))
    by_track = {k: merge_gaps(v, 0.0) for k, v in by_track.items()}
    return [s for s in segs if coverage(s, by_track.get(s["track"], [])) >= min_cover]


def language_agreement(ref: list[dict], hyp: list[dict]) -> dict:
    """Share of overlapping speech seconds where the live segment language equals the offline one."""
    same = both = 0.0
    for h in hyp:
        for r in ref:
            if r["track"] != h["track"]:
                continue
            o = overlap((h["start"], h["end"]), (r["start"], r["end"]))
            both += o
            same += o if r["language"] == h["language"] else 0.0
    return {"agree_sec": same, "overlap_sec": both, "pct": same / both if both else None}


def term_recall(ref: list[dict], hyp: list[dict], glossary: list[str]) -> dict:
    hits, present = term_hits(text_of(ref), text_of(hyp), glossary)
    return {"hits": hits, "present": present, "recall": hits / present if present else None}


def pct(values: list[float], q: float) -> float | None:
    return float(np.percentile(values, q)) if values else None


def speech_seconds(segs: list[dict]) -> float:
    return total(merge_gaps([(s["start"], s["end"]) for s in segs], 0.0))


def speech_recall(ref: list[dict], hyp: list[dict]) -> float | None:
    """Share of offline speech seconds that has a live segment on the same track (the rest was lost live)."""
    covered = dur = 0.0
    for r in ref:
        pieces = merge_gaps([(max(h["start"], r["start"]), min(h["end"], r["end"])) for h in hyp
                             if h["track"] == r["track"] and h["end"] > r["start"] and h["start"] < r["end"]], 0.0)
        covered += total(pieces)
        dur += r["end"] - r["start"]
    return covered / dur if dur else None
