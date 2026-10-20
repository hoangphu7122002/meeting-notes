"""notes.md rendering."""

from __future__ import annotations

from datetime import datetime

from .summarize import LANGUAGE_NAMES

HEADINGS = {
    "en": {
        "date": "Date", "duration": "Duration", "speakers": "Speakers", "language": "Language",
        "summary": "Summary", "decisions": "Key decisions", "actions": "Action items",
        "questions": "Open questions", "transcript": "Transcript", "none": "None.", "due": "due",
        "no_summary": "Summary unavailable", "diarization": "Speaker labels",
        "pending": "Summary in progress…", "paused": "recording paused",
    },
    "vi": {
        "date": "Ngày", "duration": "Thời lượng", "speakers": "Người nói", "language": "Ngôn ngữ",
        "summary": "Tóm tắt", "decisions": "Quyết định chính", "actions": "Việc cần làm",
        "questions": "Câu hỏi mở", "transcript": "Bản ghi", "none": "Không có.", "due": "hạn",
        "no_summary": "Chưa có tóm tắt", "diarization": "Nhãn người nói",
        "pending": "Đang tạo tóm tắt…", "paused": "tạm dừng ghi âm",
    },
}


def timestamp(sec: float) -> str:
    sec = int(max(0, sec))
    return f"{sec // 3600:02d}:{sec % 3600 // 60:02d}:{sec % 60:02d}"


def paragraphs(segments: list[dict], max_gap: float = 2.5, max_len: float = 90.0) -> list[dict]:
    """Group consecutive segments of the same speaker into readable paragraphs."""
    out: list[dict] = []
    for s in segments:
        last = out[-1] if out else None
        if last and last["speaker"] == s["speaker"] and s["start"] - last["end"] <= max_gap and s["end"] - last["start"] <= max_len:
            last["text"] += " " + s["text"]
            last["end"] = max(last["end"], s["end"])
        else:
            out.append({"start": s["start"], "end": s["end"], "speaker": s["speaker"], "text": s["text"]})
    return out


def render_notes(meeting: dict, transcript: dict, summary: dict | None, summary_error: str | None = None,
                 pending: bool = False) -> str:
    lang = (summary or {}).get("language") or transcript.get("language") or "en"
    h = HEADINGS.get(lang, HEADINGS["en"])
    if meeting.get("title_source") == "user":
        title = meeting.get("title") or "Meeting"
    else:
        title = (summary or {}).get("title") or meeting.get("title") or "Meeting"
    lines = [f"# {title}", ""]

    meta = []
    started = meeting.get("started_at")
    if started:
        try:
            meta.append(f"**{h['date']}:** {datetime.fromisoformat(started).strftime('%Y-%m-%d %H:%M')}")
        except ValueError:
            meta.append(f"**{h['date']}:** {started}")
    duration = transcript.get("duration_sec") or meeting.get("duration_sec")
    if duration:
        meta.append(f"**{h['duration']}:** {round(duration / 60)} min")
    if transcript.get("speakers"):
        meta.append(f"**{h['speakers']}:** {', '.join(transcript['speakers'])}")
    spoken = transcript.get("language") or lang
    meta.append(f"**{h['language']}:** {LANGUAGE_NAMES.get(spoken, spoken)}")
    lines += [" · ".join(meta), ""]

    if summary:
        lines += [f"## {h['summary']}", ""]
        lines += [f"- {s}" for s in summary["summary"]] or [h["none"]]
        lines += ["", f"## {h['decisions']}", ""]
        lines += [f"- {d}" for d in summary["decisions"]] or [h["none"]]
        lines += ["", f"## {h['actions']}", ""]
        if summary["action_items"]:
            for a in summary["action_items"]:
                extra = []
                if a.get("owner"):
                    extra.append(f"**{a['owner']}**")
                if a.get("due"):
                    extra.append(f"{h['due']}: {a['due']}")
                lines.append(f"- [ ] {a['task']}" + (f" — {', '.join(extra)}" if extra else ""))
        else:
            lines.append(h["none"])
        lines += ["", f"## {h['questions']}", ""]
        lines += [f"- {q}" for q in summary["open_questions"]] or [h["none"]]
        lines.append("")
        lines += section_lines(summary, lang)
    elif pending:
        lines += [f"> _{h['pending']}_", ""]
    else:
        lines += [f"> **{h['no_summary']}:** {summary_error or 'not generated'}", ""]

    lines += [f"## {h['transcript']}", ""]
    diar = transcript.get("diarization", {})
    if diar.get("note"):
        lines += [f"_{h['diarization']}: {diar['note']}_", ""]
    pauses = sorted(transcript.get("pauses") or [], key=lambda x: x.get("at_sec", 0))
    for p in paragraphs(transcript.get("segments", [])):
        while pauses and pauses[0].get("at_sec", 0) <= p["start"]:
            lines += [pause_line(pauses.pop(0), h), ""]
        lines += [f"**[{timestamp(p['start'])}] {p['speaker']}:** {p['text']}", ""]
    lines += [line for x in pauses for line in (pause_line(x, h), "")]
    return "\n".join(lines).rstrip() + "\n"


def section_lines(summary: dict, lang: str) -> list[str]:
    """Template-specific sections (standup blockers, interview strengths, ...) after the standard ones."""
    from .summarize import TEMPLATES, template_name

    defs = TEMPLATES[template_name(summary.get("template"))]["sections"]
    out: list[str] = []
    for key, items in (summary.get("sections") or {}).items():
        if not items:
            continue
        en, vi, _ = defs.get(key, (key.replace("_", " ").capitalize(), key.replace("_", " ").capitalize(), ""))
        out += [f"## {vi if lang == 'vi' else en}", "", *[f"- {x}" for x in items], ""]
    return out


def pause_line(pause: dict, h: dict) -> str:
    minutes = max(1, round(float(pause.get("duration_sec", 0)) / 60))
    return f"_[{timestamp(pause.get('at_sec', 0))}] — {h['paused']} ({minutes} min) —_"


def transcript_lines(segments: list[dict]) -> list[str]:
    """Compact transcript for the LLM prompt."""
    return [f"[{timestamp(p['start'])}] {p['speaker']}: {p['text']}" for p in paragraphs(segments)]
