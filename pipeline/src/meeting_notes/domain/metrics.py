"""Transcript accuracy metrics (WER, term recall) for benchmarks and tests."""

from __future__ import annotations

import re
import unicodedata


def words(text: str) -> list[str]:
    """Lowercase NFC words without punctuation (Vietnamese diacritics are kept: they change meaning)."""
    text = unicodedata.normalize("NFC", text.lower())
    text = re.sub(r"[^\w\s]", " ", text)
    return text.split()


def edit_distance(ref: list[str], hyp: list[str]) -> int:
    prev = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        cur = [i] + [0] * len(hyp)
        for j, h in enumerate(hyp, 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r != h))
        prev = cur
    return prev[-1]


def wer(ref: str, hyp: str) -> tuple[int, int]:
    """(errors, reference words): sum both over a corpus, then divide."""
    r, h = words(ref), words(hyp)
    return edit_distance(r, h), len(r)


def term_hits(ref: str, hyp: str, terms: list[str]) -> tuple[int, int]:
    """(terms found in hyp, terms present in ref), matched as whole lowercase word sequences."""
    def has(text_words: list[str], term: str) -> bool:
        t = words(term)
        return any(text_words[i:i + len(t)] == t for i in range(len(text_words) - len(t) + 1))

    rw, hw = words(ref), words(hyp)
    present = [t for t in terms if has(rw, t)]
    return sum(has(hw, t) for t in present), len(present)
