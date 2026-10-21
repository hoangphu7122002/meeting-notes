"""Key lines of a long transcript: cue-word detection, line parsing and chunking (pure text helpers)."""

from __future__ import annotations

import re

from .notes_merge import similar, tokens
from .notes_rules import fold, normalize_notes
from .timecode import parse_time

_LINE = re.compile(r"^(\[[\d:]+\] [^:]+:)\s*(.*)$", re.S)
# Lines that almost always hold an item: explicit decision words, a commitment with a deadline, or a question
# said to be open. Matched on folded text (no accents), so ASR accent errors do not matter.
_DATE = (r"(monday|tuesday|wednesday|thursday|friday|saturday|sunday|tomorrow|next week|end of|january|february|march|"
         r"april|may|june|july|august|september|october|november|december|thu [2-7]|thu (hai|ba|tu|nam|sau|bay)|"
         r"chu nhat|ngay \d+|\d+ thang \d+|thang \d+|ngay mai|tuan sau|tuan toi|cuoi tuan|cuoi thang|\d+ \d+)")
STRONG_CUES = {  # checked in this order: "chưa chốt" (not settled yet) is a question, not a decision
    "question": re.compile(r"\b(haven t decided|not decided|undecided|still open|open question|not sure yet|"
                           r"chua (can )?(quyet|chot)|khong chot|chua tra loi|chua thong nhat|de buoi sau|hop sau ban)\b"),
    "decision": re.compile(r"\b(chot|quyet dinh|thong nhat|duoc duyet|da duyet|phe duyet|the decision is|we decided|"
                           r"we agreed|we ve agreed|decided to|agreed to|is approved|was approved|been approved|"
                           r"moi nguoi dong y)\b"),
    "action": re.compile(r"\b(i ll|i will|we ll|we will|can you|could you|please|se|nho|giup|phu trach)\b.*"
                         r"\b(by|before|until|truoc|han|deadline|vao)\b.*\b" + _DATE),
}
KEY_LINES_MAX = 36  # key lines written per meeting (3 calls); repeats of the same sentence count once


def strong_kind(text: str) -> str | None:
    """"decision" | "action" | "question" when the text carries an explicit cue for that kind, else None."""
    f = fold(text)
    return next((kind for kind, rx in STRONG_CUES.items() if rx.search(f)), None)


def same_line(item: dict, line: str, kind: str | None = None) -> bool:
    """The item was extracted from this line: near-identical text, or the same timestamp and shared content words
    (fewer needed when the kinds agree: an item translated from its line shares only names, terms and numbers).
    A timestamp alone is not enough: a paragraph of several sentences shares one."""
    text = item.get("text") or item.get("task") or ""
    if similar(text, line_text(line)):
        return True
    if item.get("time") != parse_time(line[:12], -1.0):
        return False
    words = {w for w in tokens(line_text(line)) if len(w) > 1}
    other = {w for w in tokens(text) if len(w) > 1}
    shared = len(words & other)
    return shared >= (2 if kind and item.get("kind") == kind else 3) or bool(other and shared / len(other) >= 0.4)


def line_text(line: str) -> str:
    """The spoken text of a "[time] Speaker: text" line."""
    m = _LINE.match(line)
    return m.group(2).strip() if m else line.strip()


# The speaker commits themselves: a first-person pronoun right before "will" (not "anh Tuấn sẽ", a third person).
_SELF = re.compile(r"(^|[^\w])(i ll|i will|i m going to|i can|em se|minh se|toi se|chi se|anh se|de em|de minh|de toi|"
                   r"em nhan|minh nhan|toi nhan)\b")
_PRONOUNS = {"anh", "chi", "em", "minh", "toi", "ban", "i", "we", "chung toi"}  # not "Me": that is a label


def self_owner(line: str) -> str | None:
    """The speaker label of a line whose speaker commits themselves, else None."""
    m = re.match(r"\[[\d:]+\] ([^:]+):", line)
    return m.group(1) if m and _SELF.search(fold(line_text(line))) else None


def as_kind(item: dict, kind: str, line: str | None = None) -> dict:
    """The item as a decision, action or question. An action whose owner is missing or only a pronoun ("em",
    "I") gets the speaker of `line` when that speaker commits themselves."""
    text = item.get("text") or item.get("task") or ""
    out = {"kind": kind, "time": item.get("time", 0.0)}
    if kind != "action":
        return {**out, "text": text}
    action = normalize_notes({"action_items": [{"task": text, "owner": item.get("owner"), "due": item.get("due")}]})
    action = action["action_items"][0] if action["action_items"] else {"task": text, "owner": None, "due": None}
    if line and (not action["owner"] or fold(action["owner"]) in _PRONOUNS):
        action["owner"] = self_owner(line)
    return {**out, **action}


def sentence_lines(lines: list[str]) -> list[str]:
    """One sentence per line, each keeping its paragraph's "[time] Speaker:" prefix. Small models skim long
    paragraphs and miss a decision in the middle of one; a short line per sentence keeps every item visible."""
    out = []
    for line in lines:
        m = _LINE.match(line)
        if not m:
            out.append(line)
            continue
        sentences = [x for x in re.split(r"(?<=[.?!…])\s+", m.group(2).strip()) if x]
        out += [f"{m.group(1)} {x}" for x in sentences] or [line]
    return out


def chunk_lines(lines: list[str], max_chars: int) -> list[str]:
    chunks, cur, size = [], [], 0
    for line in lines:
        if cur and size + len(line) + 1 > max_chars:
            chunks.append("\n".join(cur))
            cur, size = [], 0
        cur.append(line)
        size += len(line) + 1
    if cur:
        chunks.append("\n".join(cur))
    return chunks
