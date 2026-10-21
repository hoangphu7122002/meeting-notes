"""Meeting summary with a local Ollama model.

Short transcripts: one structured call. Long transcripts:
1. each part (summary_extract_chars) is extracted into JSON items (decision / action / question, with the time
   of the line) plus a few topic points;
2. key lines, found by explicit cue words (decision words, a commitment with a deadline, a question said to be
   open), are checked against those items; a key line no item holds with the right kind is written into one
   item by a short call (1:1, so it cannot be dropped);
3. Python merges everything (union + fuzzy dedupe; no LLM merge, which used to drop most items);
4. one small call writes the title and overview bullets from the part points.
"""

from __future__ import annotations

from collections.abc import Callable

from ..config import Config
from ..domain.glossary import glossary_entries
from ..domain.key_lines import (KEY_LINES_MAX, as_kind, chunk_lines, line_text, same_line, sentence_lines,
                                strong_kind)
from ..domain.notes_merge import clean_extract, merge_extracts, similar
from ..domain.notes_rules import clean_strings, ground_notes, normalize_notes, speakers_in
from ..domain.notes_schema import (KINDS, LANGUAGE_NAMES, OVERVIEW_SCHEMA, TEMPLATES, extract_schema, schema,
                                   template_name, text_key, write_schema)
from ..domain.timecode import parse_time
from .errors import OllamaError
from .ports import LlmClient
from .prompts import (EXTRACT_SYSTEM, EXTRACT_USER, OVERVIEW_SYSTEM, OVERVIEW_USER, SINGLE_USER, SYSTEM,
                      WRITE_EXAMPLES, WRITE_SYSTEM, WRITE_USER)

WRITE_BATCH = 12  # key lines per rewrite call


def build_system(language: str, template: str = "general", glossary: list[str] | None = None,
                 speakers: list[str] | None = None, base: str = SYSTEM) -> str:
    tpl = TEMPLATES[template_name(template)]
    sections = ""
    if tpl["sections"]:
        sections = "- sections: an object with these lists:\n" + "".join(
            f"  - {key}: {instr}\n" for key, (_, _, instr) in tpl["sections"].items())
    extra = ""
    entries = glossary_entries(glossary)
    if entries:
        extra += "\nGlossary (correct spellings of names and terms that may come up):\n" + "".join(
            f"- {term}" + (f" ({note})" if note else "") + "\n" for term, note in entries[:80])
    if speakers:
        extra += "\nSpeaker labels in this transcript: " + ", ".join(speakers) + ' ("Me" is the person who recorded the meeting).\n'
    example = ""
    if language in WRITE_EXAMPLES:
        shots = WRITE_EXAMPLES[language]
        example = "\nExamples (input item, then its output object):\n" + "".join(
            f"{shots[k]}\n{shots[k + 1]}\n" for k in range(0, len(shots), 2))
    return base.format(focus=tpl["focus"], language=LANGUAGE_NAMES.get(language, language), sections=sections,
                       glossary=extra, example=example, text_key=text_key(language))


def summarize(
    transcript_lines: list[str],
    language: str,
    cfg: Config,
    progress: Callable[[float, str], None] | None = None,
    template: str | None = None,
    *,
    llm: LlmClient,
) -> dict:
    template = template_name(template or cfg.summary_template)
    if not transcript_lines:
        return normalize_notes({"title": "", "summary": [], "decisions": [], "action_items": [], "open_questions": []})
    client = llm
    client.ensure_model(progress)
    expected_tokens = 700.0
    fmt = schema(template)
    speakers = speakers_in(transcript_lines)

    def ticker(lo: float, hi: float, message: str):
        if progress is None:
            return None
        return lambda n: progress(lo + (hi - lo) * min(0.95, n / expected_tokens), message)

    system = build_system(language, template, cfg.glossary, speakers)
    full_text = "\n".join(transcript_lines)

    def finish(notes: dict) -> dict:
        notes = ground_notes(notes, full_text, speakers, cfg.glossary)
        notes["language"] = language
        notes["template"] = template
        return notes

    chunks = chunk_lines(transcript_lines, cfg.summary_chunk_chars)
    if len(chunks) == 1:
        message = f"Summarizing with {cfg.ollama_model}"
        if progress:
            progress(0.05, message)
        return finish(client.chat(system, SINGLE_USER.format(transcript=chunks[0]), ticker(0.05, 1.0, message), fmt))
    return finish(summarize_long(client, transcript_lines, language, template, cfg, speakers, progress))


def summarize_long(client: LlmClient, lines: list[str], language: str, template: str, cfg: Config,
                   speakers: list[str], progress: Callable[[float, str], None] | None = None) -> dict:
    """Extract items per part, then make sure every key line (explicit decision words, a commitment with a
    deadline, a question said to be open) is an item of the right kind: part items from a key line take its kind,
    key lines no part picked up are written into items by one short call. Everything is merged in Python (never
    by an LLM); one small call writes the title and overview bullets."""
    lines = sentence_lines(lines)
    chunks = chunk_lines(lines, cfg.summary_extract_chars)
    tpl, lang = TEMPLATES[template], LANGUAGE_NAMES.get(language, language)
    total = len(chunks) + 1.5  # the key-line call and the overview are about one part and a half

    def report(done: float, message: str) -> None:
        if progress:
            progress(min(done / total, 0.99), message)

    system = build_system(language, template, cfg.glossary, speakers, base=EXTRACT_SYSTEM)
    fmt = extract_schema(template)
    parts = []
    for i, chunk in enumerate(chunks, 1):
        report(i - 1, f"Summarizing part {i}/{len(chunks)}")
        part = clean_extract(client.chat(system, EXTRACT_USER.format(part=i, parts=len(chunks), transcript=chunk,
                                                                     language=lang), None, fmt, raw=True),
                             parse_time(chunk[:12]))
        # Ground owners/dues against this part's own text, before the merge can fill them across parts.
        ground_notes(part, chunk, speakers, cfg.glossary)
        part.pop("grounding", None)
        parts.append(part)
    found = [{**item, "kind": kind} for p in parts for field, kind in
             (("decisions", "decision"), ("action_items", "action"), ("open_questions", "question")) for item in p[field]]

    # Small models skim: a clear decision or deadline in a long part is sometimes skipped or filed as the wrong kind.
    # A key line some part item already holds with the line's kind keeps that item (other-kind copies are dropped);
    # otherwise the line is written into an item afresh, which also fixes the kind with its owner and deadline.
    missed, drop, seen = [], set(), []
    for i, line in enumerate(lines):
        kind = strong_kind(line_text(line))
        if not kind or any(similar(line_text(line), t) for t in seen):
            continue
        seen.append(line_text(line))
        hits = [n for n, item in enumerate(found) if n not in drop and same_line(item, line, kind)]
        same = [n for n in hits if found[n]["kind"] == kind]
        for n in same:
            found[n] = as_kind(found[n], kind, line)
        drop.update(n for n in hits if n not in same)
        if not same:
            missed.append(i)
    found = [item for n, item in enumerate(found) if n not in drop]
    if missed:
        report(len(chunks), "Checking decisions and action items")
        found += write_key_lines(client, lines, missed[:KEY_LINES_MAX], language, template, cfg, speakers)

    by_kind: dict = {"decisions": [], "action_items": [], "open_questions": []}
    for item in found:
        field = {"decision": "decisions", "action": "action_items", "question": "open_questions"}[item["kind"]]
        by_kind[field].append({k: v for k, v in item.items() if k != "kind"})
    notes = merge_extracts([by_kind] + [{"sections": p.get("sections") or {}} for p in parts])
    # The same statement extracted as both a decision and a task: keep the task (it carries owner and due).
    notes["decisions"] = [d for d in notes["decisions"] if not any(similar(d, a["task"]) for a in notes["action_items"])]

    report(total - 0.5, "Writing the overview")
    points = "\n".join(f"- {pt}" for p in parts for pt in p["points"]) or "-"
    decisions = "\n".join(f"- {d}" for d in notes["decisions"]) or "-"
    try:
        overview = client.chat(OVERVIEW_SYSTEM.format(focus=tpl["focus"], language=lang),
                               OVERVIEW_USER.format(points=points, decisions=decisions), None, OVERVIEW_SCHEMA, raw=True)
    except (OllamaError, ValueError):
        overview = {}
    title = " ".join(str(overview.get("title") or "").split()).strip("\"'“”")
    summary = clean_strings(overview.get("summary"))[:8] or [p["points"][0] for p in parts if p["points"]][:8]
    return {"title": title, "summary": summary, **notes}


def write_key_lines(client: LlmClient, lines: list[str], ids: list[int], language: str, template: str, cfg: Config,
                    speakers: list[str]) -> list[dict]:
    """One item per key line. A line the model does not answer for keeps its own text and its cue's kind, so a
    key line is never lost. Owners and dues are grounded against the line and its neighbours."""
    lang, key = LANGUAGE_NAMES.get(language, language), text_key(language)
    system = build_system(language, template, cfg.glossary, speakers, base=WRITE_SYSTEM)
    written: dict[int, dict] = {}
    for b in range(0, len(ids), WRITE_BATCH):
        batch = ids[b:b + WRITE_BATCH]
        listing = "\n".join(f"id {i} | {strong_kind(line_text(lines[i]))} | before: {lines[i - 1] if i else '-'} | "
                            f"line: {lines[i]}" for i in batch)
        try:
            data = client.chat(system, WRITE_USER.format(items=listing, language=lang), None, write_schema(language),
                               raw=True)
        except (OllamaError, ValueError):
            continue
        for w in data.get("items") or []:
            if isinstance(w, dict) and isinstance(w.get("id"), int) and w["id"] in batch:
                written.setdefault(w["id"], w)
    out = []
    for i in ids:
        w, line = written.get(i) or {}, lines[i]
        kind = w.get("kind") if w.get("kind") in KINDS else strong_kind(line_text(line))
        text = " ".join(str(w.get(key) or "").split()) or line_text(line)
        item = as_kind({"text": text, "owner": w.get("owner"), "due": w.get("due"), "time": parse_time(line[:12])},
                       kind, line)
        if kind == "action":
            ground_notes({"action_items": [item]}, "\n".join(lines[max(0, i - 2):i + 2]), speakers, cfg.glossary)
        out.append(item)
    return out
