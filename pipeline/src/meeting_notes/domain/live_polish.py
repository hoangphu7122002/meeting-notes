"""Live polish Tier 1: deterministic display cleanup of live partials (docs/research/live-polish.md 4.1).

Pure text rules over the decoded chunks of one paragraph: NFC, spacing, joining a sentence split across chunks,
sentence-start casing, glossary spelling, collapsing decode loops, hiding pure interjections, and a final period
when the paragraph closes. Rules never add, translate or reorder words and never touch diacritics or tone marks
(comparisons fold case only). Polish is a display layer: raw partials stay as decoded and the Stop-time
transcript stays authoritative.
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass, field

from .segments import collapse_repeats

# Pure interjections only. Discourse markers ("thì", "kiểu", "nói chung là") and answers ("ừ" = yes) carry meaning
# and are kept; "à" is dropped only as an interjection, never as a sentence-final particle ("thế à?").
FILLERS = frozenset({"ờ", "ơ", "ừm", "ờm", "ưm", "hừm", "uh", "um", "uhm", "umm", "erm", "er", "hmm", "mm"})
FILLER_NOT_FINAL = frozenset({"à"})
ABBREVIATIONS = frozenset({"e.g.", "i.e.", "etc.", "vs.", "mr.", "mrs.", "ms.", "dr.", "v.v.", "tp.", "st.", "no."})
TERMINAL = ".!?…"

_SPACES = re.compile(r"\s+")
_SPACE_BEFORE_PUNCT = re.compile(r"\s+([,.;:!?…])")
_DUP_COMMA = re.compile(r",(\s*,)+")
_SENTENCE_START = re.compile(r"(?:^|(?<=[.!?…] ))(\S+)")
_TRAILING = ".,;:!?…\"')”’"


def nfc(text: str) -> str:
    return unicodedata.normalize("NFC", text)


def glossary_terms(glossary: list[str]) -> list[str]:
    """Spellings from config glossary entries ("Tuấn: product lead" -> "Tuấn"), longest first."""
    terms = {nfc(entry.split(":", 1)[0].strip()) for entry in glossary}
    return sorted((t for t in terms if t), key=len, reverse=True)


@dataclass(frozen=True)
class PolishRules:
    glossary: tuple[str, ...] = ()  # exact spellings (see glossary_terms)
    drop_fillers: bool = True
    pause_sec: float = 2.5  # a same-track gap at least this long starts a new paragraph
    max_words: int = 80  # a paragraph this long is closed after the chunk that reached it


def drop_fillers(text: str) -> str:
    """Remove standalone interjection tokens (with a comma right after them)."""
    words = text.split(" ")
    kept: list[str] = []
    for i, word in enumerate(words):
        core = word.rstrip(",").lower()
        last = i == len(words) - 1 or word.endswith(tuple(TERMINAL))
        stripped = core.rstrip(TERMINAL)
        if core in FILLERS or (core in FILLER_NOT_FINAL and not last):
            continue
        if stripped in FILLERS:  # "ok ờ." -> "ok."
            if kept:
                kept[-1] = kept[-1].rstrip(",") + word[len(stripped):].lstrip(",")
            continue
        kept.append(word)
    return " ".join(kept)


def tidy_spacing(text: str) -> str:
    text = _SPACES.sub(" ", text).strip()
    text = _SPACE_BEFORE_PUNCT.sub(r"\1", text)
    text = _DUP_COMMA.sub(",", text)
    return text.lstrip(",;: ").strip()


def _can_capitalize(token: str) -> bool:
    """Plain lowercase words only: iPhone, macOS, x86, URLs, paths and handles stay as they are."""
    word = token.rstrip(_TRAILING)
    return (word[:1].isalpha() and word[:1].islower()
            and not any(c.isupper() or c.isdigit() or c in "./_@:" for c in word[1:]))


def capitalize_sentences(text: str) -> str:
    def fix(match: re.Match) -> str:
        token = match.group(1)
        before = text[: match.start(1)].rstrip().rsplit(" ", 1)[-1].lower()
        if match.start(1) > 0 and (before in ABBREVIATIONS or before.endswith(("...", "…"))):  # trailing off
            return token
        return token[0].upper() + token[1:] if _can_capitalize(token) else token

    return _SENTENCE_START.sub(fix, text)


def apply_glossary(text: str, terms: tuple[str, ...] | list[str]) -> str:
    """Case-insensitive whole-word match -> the glossary's exact spelling (diacritics must already match)."""
    for term in terms:
        pattern = re.compile(r"(?<!\w)" + re.escape(term) + r"(?!\w)", re.IGNORECASE)
        text = pattern.sub(term, text)
    return text


def join_chunks(texts: list[str]) -> str:
    """Join chunk texts; a period whisper put at a chunk end is dropped when the next chunk continues lowercase."""
    out = ""
    for text in texts:
        text = text.strip()
        if not text:
            continue
        if out and text[0].islower() and out.endswith(".") and not out.endswith("..."):
            last = out.rsplit(" ", 1)[-1].lower()
            if last not in ABBREVIATIONS:
                out = out[:-1]
        out = f"{out} {text}" if out else text
    return out


def polish_text(texts: list[str], rules: PolishRules, closed: bool = False) -> str:
    """Tier 1 text of one paragraph from its raw chunk texts (in order)."""
    pieces = [collapse_repeats(tidy_spacing(nfc(t))) for t in texts]
    if rules.drop_fillers:
        pieces = [tidy_spacing(drop_fillers(p)) for p in pieces]
    text = tidy_spacing(join_chunks(pieces))
    text = capitalize_sentences(text)
    text = apply_glossary(text, rules.glossary)
    if closed and text and text[-1] not in TERMINAL and (text[-1].isalnum() or text[-1] in "\"')”’"):
        text += "."
    return nfc(text)


@dataclass
class Paragraph:
    track: str
    speaker: str
    para: int
    start: float
    end: float
    seqs: list[int] = field(default_factory=list)
    texts: list[str] = field(default_factory=list)
    closed: bool = False
    text: str = ""  # last emitted polished text

    @property
    def words(self) -> int:
        return sum(len(t.split()) for t in self.texts)


class LivePolisher:
    """Groups live chunks into paragraphs (speaker change, pause, length) and keeps their Tier 1 text.

    `add` and `close_all` return the paragraphs whose polished text changed, to be sent to the display."""

    def __init__(self, rules: PolishRules):
        self.rules = rules
        self.open: dict[str, Paragraph] = {}
        self.count: dict[str, int] = {}
        self.seen: set[tuple[str, int]] = set()
        self.last_track: str | None = None

    def add(self, track: str, speaker: str, seq: int, start: float, end: float, text: str) -> list[Paragraph]:
        if (track, seq) in self.seen:
            return []
        self.seen.add((track, seq))
        changed: list[Paragraph] = []
        if self.last_track is not None and self.last_track != track:
            changed += self._close(self.last_track)  # speaker change
        self.last_track = track
        para = self.open.get(track)
        if para is not None and start - para.end >= self.rules.pause_sec:
            changed += self._close(track)
            para = None
        if para is None:
            n = self.count.get(track, 0)
            self.count[track] = n + 1
            para = self.open[track] = Paragraph(track, speaker, n, start, end)
        para.seqs.append(seq)
        para.texts.append(text)
        para.end = max(para.end, end)
        if para.words >= self.rules.max_words:
            changed += self._close(track)
        else:
            changed += self._render(para)
        return changed

    def close_all(self) -> list[Paragraph]:
        changed: list[Paragraph] = []
        for track in list(self.open):
            changed += self._close(track)
        return changed

    def _close(self, track: str) -> list[Paragraph]:
        para = self.open.pop(track, None)
        if para is None:
            return []
        para.closed = True
        return self._render(para)

    def _render(self, para: Paragraph) -> list[Paragraph]:
        text = polish_text(para.texts, self.rules, para.closed)
        if not text or text == para.text:
            return []
        para.text = text
        return [para]
