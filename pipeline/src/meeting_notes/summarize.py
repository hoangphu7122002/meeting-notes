"""Meeting summary with a local Ollama model (map-reduce for long transcripts)."""

from __future__ import annotations

import json
import re
import unicodedata
import urllib.error
import urllib.request
from collections.abc import Callable

from .config import Config

LANGUAGE_NAMES = {
    "vi": "Vietnamese", "en": "English", "zh": "Chinese", "ja": "Japanese", "ko": "Korean",
    "fr": "French", "de": "German", "es": "Spanish", "th": "Thai", "id": "Indonesian",
}

# Extra sections per template: key -> (English heading, Vietnamese heading, instruction).
TEMPLATES: dict[str, dict] = {
    "general": {
        "focus": "a general meeting: main topics, outcomes and follow-ups",
        "sections": {},
    },
    "one_on_one": {
        "focus": "a 1:1 meeting between a manager and a report: wellbeing, progress, feedback and growth",
        "sections": {
            "feedback": ("Feedback", "Phản hồi", "feedback given or received, attributed to who gave it"),
            "growth": ("Growth and career", "Phát triển và sự nghiệp", "goals, skills, career or development points discussed"),
        },
    },
    "standup": {
        "focus": "a daily standup: what each person did, will do next, and what blocks them",
        "sections": {
            "updates": ("Updates by person", "Cập nhật theo người",
                        "one item per person: \"<name>: done ...; next ...\" using only what they said"),
            "blockers": ("Blockers", "Vướng mắc", "anything blocking progress, with who is blocked"),
        },
    },
    "interview": {
        "focus": "a job interview: the candidate's background, answers, strengths and concerns",
        "sections": {
            "strengths": ("Strengths", "Điểm mạnh", "strengths shown by the candidate, each backed by what was said"),
            "concerns": ("Concerns", "Điểm cần lưu ý", "gaps or concerns, each backed by what was said; no speculation"),
        },
    },
}
TEMPLATE_ALIASES = {"1:1": "one_on_one", "1-1": "one_on_one", "oneonone": "one_on_one", "one-on-one": "one_on_one",
                    "daily": "standup", "stand-up": "standup", "default": "general", "": "general"}


def template_name(name: str | None) -> str:
    key = (name or "general").strip().lower()
    key = TEMPLATE_ALIASES.get(key, key).replace("-", "_")
    return key if key in TEMPLATES else "general"


def schema(template: str = "general") -> dict:
    sections = TEMPLATES[template_name(template)]["sections"]
    props: dict = {
        "title": {"type": "string"},
        "summary": {"type": "array", "items": {"type": "string"}},
        "decisions": {"type": "array", "items": {"type": "string"}},
        "action_items": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "task": {"type": "string"},
                    "owner": {"type": ["string", "null"]},
                    "due": {"type": ["string", "null"]},
                },
                "required": ["task", "owner", "due"],
            },
        },
        "open_questions": {"type": "array", "items": {"type": "string"}},
    }
    required = ["title", "summary", "decisions", "action_items", "open_questions"]
    if sections:
        props["sections"] = {
            "type": "object",
            "properties": {k: {"type": "array", "items": {"type": "string"}} for k in sections},
            "required": list(sections),
        }
        required.append("sections")
    return {"type": "object", "properties": props, "required": required}


SCHEMA = schema("general")  # kept for callers that import it

SYSTEM = """You are a meticulous meeting assistant. You turn a speaker-labelled meeting transcript into concise, factual notes.
This is {focus}.

Language: write every field in {language}, even where people speak another language. Keep product names, technical terms and English jargon as spoken.

Grounding rules (most important):
- Use only what the transcript says. Never invent people, numbers, dates, deadlines or commitments.
- owner: the name of the person who will do the task, only if the transcript names them or the speaker committed themselves ("I will ..." -> that speaker's label, e.g. "Me", "Speaker 2"). If unclear, null. Never guess an owner.
- due: the deadline in the transcript's own words (e.g. "before Friday", "thứ sáu tuần này"). Do not compute, convert or translate dates. If no deadline was said for that task, null.
- If something is uncertain, leave it out or put it under open_questions.

Fields:
- title: 3-8 words naming the meeting topic; no date, no quotes.
- summary: 3-8 short bullet points, most important first. One fact per bullet.
- decisions: what was agreed or decided, as stated. Empty list if nothing was decided.
- action_items: concrete tasks someone committed to or was asked to do, one per task, starting with a verb.
- open_questions: questions left unanswered or topics deferred to later. Empty list if none.
{sections}{glossary}
The transcript comes from speech recognition and may misspell names and terms; interpret charitably and use the glossary spellings when a word clearly refers to a glossary entry.
Answer with JSON only."""

MAP_USER = """This is part {part} of {parts} of a meeting transcript. Extract notes for this part only (title may be provisional).

Transcript:
{transcript}"""

REDUCE_USER = """Below are notes extracted from consecutive parts of one meeting, in order. Merge them into the final notes for the whole meeting:
- deduplicate; keep the most important points; summary at most 8 bullets;
- keep every distinct action item with its owner and due exactly as given (null stays null; never fill in a missing owner or due);
- a question answered or decided in a later part is no longer open;
- give one title for the whole meeting.

Partial notes (JSON):
{notes}"""

SINGLE_USER = """Meeting transcript:
{transcript}"""


def build_system(language: str, template: str = "general", glossary: list[str] | None = None,
                 speakers: list[str] | None = None) -> str:
    from .config import glossary_entries

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
    return SYSTEM.format(focus=tpl["focus"], language=LANGUAGE_NAMES.get(language, language), sections=sections,
                         glossary=extra)


class OllamaError(RuntimeError):
    pass


class Ollama:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        self.base = cfg.ollama_url.rstrip("/")

    def _request(self, path: str, payload: dict | None = None, timeout: float = 10):
        data = json.dumps(payload).encode() if payload is not None else None
        req = urllib.request.Request(self.base + path, data=data, headers={"Content-Type": "application/json"})
        try:
            return urllib.request.urlopen(req, timeout=timeout)
        except urllib.error.URLError as exc:
            raise OllamaError(
                f"Ollama is not reachable at {self.base} ({exc.reason if hasattr(exc, 'reason') else exc}). "
                "Start it with: brew services start ollama"
            ) from exc

    def ensure_model(self, progress: Callable[[float, str], None] | None = None) -> None:
        with self._request("/api/tags") as resp:
            models = {m["name"] for m in json.load(resp).get("models", [])}
        name = self.cfg.ollama_model
        if name in models or f"{name}:latest" in models:
            return
        with self._request("/api/pull", {"model": name, "stream": True}, timeout=3600) as resp:
            for line in resp:
                info = json.loads(line or b"{}")
                if info.get("error"):
                    raise OllamaError(f"ollama pull {name}: {info['error']}")
                if progress and info.get("total"):
                    progress(info.get("completed", 0) / info["total"], f"Downloading {name}")

    def chat(self, system: str, user: str, tick: Callable[[int], None] | None = None, fmt: dict | None = None) -> dict:
        """One structured completion. Streams so `tick(tokens_so_far)` can report progress / cancel."""
        payload = {
            "model": self.cfg.ollama_model,
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
            "format": fmt or SCHEMA,
            "stream": True,
            "think": False,
            "keep_alive": self.cfg.ollama_keep_alive,
            "options": {"temperature": 0.2, "num_ctx": self.cfg.ollama_num_ctx},
        }
        if self.cfg.ollama_num_thread > 0:
            payload["options"]["num_thread"] = self.cfg.ollama_num_thread
        parts: list[str] = []
        with self._request("/api/chat", payload, timeout=self.cfg.ollama_timeout_sec) as resp:
            for n, line in enumerate(resp, 1):
                if not line.strip():
                    continue
                chunk = json.loads(line)
                if chunk.get("error"):
                    raise OllamaError(chunk["error"])
                parts.append(chunk.get("message", {}).get("content", ""))
                if tick and n % 8 == 0:
                    tick(n)
                if chunk.get("done"):
                    break
        return parse_json("".join(parts))


def parse_json(content: str) -> dict:
    content = re.sub(r"<think>.*?</think>", "", content, flags=re.S).strip()
    match = re.search(r"\{.*\}", content, flags=re.S)
    if not match:
        raise OllamaError("model did not return JSON")
    return normalize_notes(json.loads(match.group(0)))


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


# ---------------------------------------------------------------- grounding

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
    from .config import glossary_entries

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


def summarize(
    transcript_lines: list[str],
    language: str,
    cfg: Config,
    progress: Callable[[float, str], None] | None = None,
    template: str | None = None,
) -> dict:
    template = template_name(template or cfg.summary_template)
    if not transcript_lines:
        return normalize_notes({"title": "", "summary": [], "decisions": [], "action_items": [], "open_questions": []})
    client = Ollama(cfg)
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
    partials = []
    n = len(chunks) + 1
    for i, chunk in enumerate(chunks, 1):
        if progress:
            progress((i - 1) / n, f"Summarizing part {i}/{len(chunks)}")
        part = client.chat(system, MAP_USER.format(part=i, parts=len(chunks), transcript=chunk),
                           ticker((i - 1) / n, i / n, f"Summarizing part {i}/{len(chunks)}"), fmt)
        # Ground each part against its own text so a merge cannot resurrect an invented owner or date.
        partials.append(ground_notes(part, chunk, speakers, cfg.glossary))
    for p in partials:
        p.pop("grounding", None)
    if progress:
        progress(len(chunks) / n, "Merging partial summaries")
    limit = cfg.summary_chunk_chars * 1.5
    while len(partials) > 1 and len(json.dumps(partials, ensure_ascii=False)) > limit:  # very long meetings: pairwise first
        partials = [
            client.chat(system, REDUCE_USER.format(notes=json.dumps(partials[i:i + 2], ensure_ascii=False)), None, fmt)
            if i + 1 < len(partials) else partials[i]
            for i in range(0, len(partials), 2)
        ]
    merged = json.dumps(partials, ensure_ascii=False)
    return finish(client.chat(system, REDUCE_USER.format(notes=merged), ticker((n - 1) / n, 1.0, "Merging partial summaries"), fmt))
