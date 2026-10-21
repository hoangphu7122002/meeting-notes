"""Deterministic merge of per-part extractions: fuzzy dedupe that folds duplicates and never drops an item."""

from __future__ import annotations

from .notes_rules import clean_strings, fold, normalize_notes
from .timecode import parse_time


def tokens(text: str) -> set[str]:
    return set(fold(text).split())


def similar(a: str, b: str) -> bool:
    """Same item said twice: high word overlap (accent- and punctuation-insensitive)."""
    ta, tb = tokens(a), tokens(b)
    if not ta or not tb:
        return False
    inter = len(ta & tb)
    if inter / len(ta | tb) >= 0.7:
        return True
    small = min(len(ta), len(tb))
    return small >= 4 and inter / small >= 0.9  # one phrasing contains the other


def _compatible(a: str | None, b: str | None) -> bool:
    return not a or not b or fold(a) == fold(b)


def merge_items(items: list[dict], key: str) -> list[dict]:
    """Union with fuzzy dedupe. An item is only ever folded into an earlier near-duplicate (its merge target),
    never dropped: the wording with more words wins, a missing owner/due is filled, the earliest time is kept.
    Action items merge only when owners and due dates do not conflict."""
    out: list[dict] = []
    for item in items:
        text = item.get(key) or ""
        if not text:
            continue
        target = next((o for o in out if similar(o[key], text) and _compatible(o.get("owner"), item.get("owner"))
                       and _compatible(o.get("due"), item.get("due"))), None)
        if target is None:
            out.append(dict(item))
            continue
        if len(fold(text).split()) > len(fold(target[key]).split()):  # more words = more detail
            target[key] = text
        for field in ("owner", "due"):
            if field in item and not target.get(field) and item.get(field):
                target[field] = item[field]
        target["time"] = min(target.get("time", 0.0), item.get("time", 0.0))
    return sorted(out, key=lambda o: o.get("time", 0.0))


def clean_extract(data: dict, part_start: float = 0.0) -> dict:
    """Normalize one part's extraction: strip blanks, parse times (default: the part's first timestamp)."""
    def entries(value, key: str) -> list[dict]:
        out = []
        for item in value or []:
            if isinstance(item, str):
                item = {key: item}
            if not isinstance(item, dict):
                continue
            text = " ".join(str(item.get(key) or "").split())
            if text:
                out.append({**item, key: text, "time": parse_time(item.get("time"), part_start)})
        return out

    actions = []
    for item in entries(data.get("action_items"), "task"):
        notes = normalize_notes({"action_items": [item]})["action_items"]
        if notes:
            actions.append({**notes[0], "time": item["time"]})
    out = {
        "decisions": entries(data.get("decisions"), "text"),
        "action_items": actions,
        "open_questions": entries(data.get("open_questions"), "text"),
        "points": clean_strings(data.get("points")),
    }
    if isinstance(data.get("sections"), dict):
        out["sections"] = {str(k): clean_strings(v) for k, v in data["sections"].items()}
    return out


def merge_extracts(parts: list[dict]) -> dict:
    """Combine per-part extractions into notes (without title/summary). Deterministic: nothing is dropped
    except exact or near duplicates, which are folded into the first occurrence."""
    def gather(field: str) -> list[dict]:
        return [item for p in parts for item in p.get(field, [])]

    decisions = merge_items(gather("decisions"), "text")
    actions = merge_items(gather("action_items"), "task")
    questions = merge_items(gather("open_questions"), "text")
    notes = {
        "decisions": [d["text"] for d in decisions],
        "action_items": [{"task": a["task"], "owner": a.get("owner"), "due": a.get("due")} for a in actions],
        "open_questions": [q["text"] for q in questions],
    }
    names = [k for p in parts for k in (p.get("sections") or {})]
    if names:
        sections = {}
        for name in dict.fromkeys(names):
            merged = merge_items([{"text": t, "time": float(i)} for i, p in enumerate(parts)
                                  for t in (p.get("sections") or {}).get(name, [])], "text")
            sections[name] = [m["text"] for m in merged]
        if any(sections.values()):
            notes["sections"] = sections
    return notes
