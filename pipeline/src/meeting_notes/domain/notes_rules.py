"""Rules that clean and verify model output against the transcript: normalizing, grounding, language."""

from __future__ import annotations

import re
import unicodedata

from .glossary import glossary_entries


def normalize_notes(data: dict) -> dict:
    def strings(value) -> list[str]:
        if isinstance(value, str):
            value = [value]
        return [" ".join(str(v).split()) for v in (value or []) if str(v).strip()]

    def blank(value) -> bool:
        return not isinstance(value, str) or value.strip().lower() in ("", "null", "none", "unknown", "n/a", "không rõ", "chưa rõ")

    items = []
    for item in data.get("action_items") or []:
        if isinstance(item, str):
            item = {"task": item}
        task = " ".join(str(item.get("task", "")).split())
        if not task:
            continue
        owner, due = item.get("owner"), item.get("due")
        owner = None if blank(owner) else " ".join(owner.split())
        due = None if blank(due) else " ".join(due.split())
        items.append({"task": task, "owner": owner, "due": due})
    notes = {
        "title": " ".join(str(data.get("title") or "").split()).strip("\"'“”"),
        "summary": strings(data.get("summary")),
        "decisions": strings(data.get("decisions")),
        "action_items": items,
        "open_questions": strings(data.get("open_questions")),
    }
    sections = data.get("sections")
    if isinstance(sections, dict):
        cleaned = {str(k): strings(v) for k, v in sections.items()}
        if any(cleaned.values()):
            notes["sections"] = cleaned
    return notes


def fold(text: str) -> str:
    """Lowercase, NFC, without diacritics or punctuation: tolerant matching against ASR text."""
    text = unicodedata.normalize("NFD", text.lower().replace("đ", "d"))
    text = "".join(c for c in text if unicodedata.category(c) != "Mn")
    return " ".join(re.sub(r"[^\w\s]", " ", text).split())


# Function words that do not make a deadline grounded on their own.
_DUE_STOP = {"the", "a", "an", "by", "before", "on", "at", "in", "of", "this", "next", "end", "until", "trước", "vào",
             "của", "cuối", "này", "tới", "sau", "ngày", "là", "lúc", "khi", "hạn"}


def _has_phrase(haystack: str, phrase: str) -> bool:
    return bool(phrase) and f" {phrase} " in f" {haystack} "


def ground_notes(notes: dict, transcript: str, speakers: list[str] | None = None, glossary: list[str] | None = None) -> dict:
    """Drop owners and due dates that the transcript does not support (small models invent them).

    owner is kept when it is a speaker label or is named in the transcript (accent-insensitive, also as a
    glossary spelling of a name heard in the transcript); due is kept when its content words occur in the
    transcript. Removed values become null and are counted in notes["grounding"].
    """
    hay = fold(transcript)
    labels = {fold(s) for s in speakers or []}
    names_heard = {fold(t) for t, _ in glossary_entries(glossary) if _has_phrase(hay, fold(t))}
    dropped = {"owner": 0, "due": 0}
    for item in notes.get("action_items", []):
        owner = item.get("owner")
        if owner:
            f = fold(owner)
            # "anh Tuấn" / "Tuấn (PM)": accept when any 1-3 word name inside it is heard or is a label.
            words = f.split()
            parts = {" ".join(words[i:j]) for i in range(len(words)) for j in range(i + 1, min(len(words), i + 3) + 1)}
            ok = f in labels or any(p in labels or p in names_heard or (_has_phrase(hay, p) and len(p) >= 3) for p in parts
                                    if p not in _DUE_STOP and p not in {"anh", "chi", "em", "ban", "mr", "ms"})
            if not ok:
                item["owner"] = None
                dropped["owner"] += 1
        due = item.get("due")
        if due:
            content = [w for w in fold(due).split() if w not in {fold(x) for x in _DUE_STOP}]
            if not content:
                content = fold(due).split()
            hits = sum(_has_phrase(hay, w) for w in content)
            if not content or hits / len(content) < 0.6:
                item["due"] = None
                dropped["due"] += 1
    if any(dropped.values()):
        notes["grounding"] = {"dropped_owner": dropped["owner"], "dropped_due": dropped["due"]}
    return notes


def summary_language(languages: dict[str, float] | None, fallback: str, setting: str = "auto") -> str:
    """Notes language: the configured one, else Vietnamese when it is at least 40% of the speech
    (the user is Vietnamese-first), else the main spoken language."""
    if setting and setting != "auto":
        return setting
    stats = {k: float(v) for k, v in (languages or {}).items() if v}
    total = sum(stats.values())
    if not total:
        return fallback or "en"
    if stats.get("vi", 0) / total >= 0.4:
        return "vi"
    return max(stats, key=stats.get)


def speakers_in(lines: list[str]) -> list[str]:
    seen: list[str] = []
    for line in lines:
        m = re.match(r"\[[\d:]+\] ([^:]+):", line)
        if m and m.group(1) not in seen:
            seen.append(m.group(1))
    return seen


def clean_strings(value) -> list[str]:
    if isinstance(value, str):
        value = [value]
    return [" ".join(str(v).split()) for v in (value or []) if str(v).strip()]
