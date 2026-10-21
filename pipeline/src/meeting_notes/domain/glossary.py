"""Custom vocabulary (names, products, jargon) parsed from the `glossary` config value."""

from __future__ import annotations


def glossary_entries(glossary: list[str] | str | None) -> list[tuple[str, str]]:
    """Parse glossary entries into (term, note) pairs. Accepts a list or one comma/newline separated string."""
    if not glossary:
        return []
    items = glossary.replace("\n", ",").split(",") if isinstance(glossary, str) else [str(g) for g in glossary]
    out: list[tuple[str, str]] = []
    seen: set[str] = set()
    for item in items:
        term, _, note = item.partition(":")
        term, note = " ".join(term.split()), " ".join(note.split())
        if term and term.lower() not in seen:
            seen.add(term.lower())
            out.append((term, note))
    return out
