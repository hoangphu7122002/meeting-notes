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
EXTRACT_MAX_ITEMS = 5  # per list and part; a part of a few minutes of talk rarely holds more


def extract_schema(template: str = "general") -> dict:
    """Per-part extraction. Lists and strings are capped so a part cannot turn into a copy of the transcript
    (qwen3:4b otherwise sometimes lists every line, which costs minutes and buries the real items)."""
    text = {"type": "string", "maxLength": 200}

    def items(*fields: str, nullable: tuple[str, ...] = ()) -> dict:
        props = {f: {"type": ["string", "null"]} if f in nullable else text for f in fields}
        props["time"] = {"type": "string"}
        return {"type": "array", "maxItems": EXTRACT_MAX_ITEMS,
                "items": {"type": "object", "properties": props, "required": [*fields, "time"]}}

    sections = TEMPLATES[template_name(template)]["sections"]
    props: dict = {
        "decisions": items("text"),
        "action_items": items("task", "owner", "due", nullable=("owner", "due")),
        "open_questions": items("text"),
        "points": {"type": "array", "maxItems": 3, "items": text},
    }
    required = ["decisions", "action_items", "open_questions", "points"]
    if sections:
        props["sections"] = {
            "type": "object",
            "properties": {k: {"type": "array", "maxItems": 8, "items": text} for k in sections},
            "required": list(sections),
        }
        required.append("sections")
    return {"type": "object", "properties": props, "required": required}


OVERVIEW_SCHEMA = {
    "type": "object",
    "properties": {"title": {"type": "string"}, "summary": {"type": "array", "items": {"type": "string"}}},
    "required": ["title", "summary"],
}

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

EXTRACT_SYSTEM = """You extract meeting notes from one part of a speaker-labelled meeting transcript.
This is {focus}.

Language: write every text field in {language}, even where people speak another language. Keep names, numbers, dates, product names and technical terms as spoken.

Extract only what this part states explicitly:
- decisions: something agreed, decided, approved or settled (e.g. "chốt", "quyết định", "đã duyệt", "mọi người đồng ý", "we decided", "the decision is", "we agreed"). Say what was decided, with its numbers and dates.
- action_items: a concrete task someone commits to or is asked to do (e.g. "X sẽ ...", "em sẽ ...", "chị sẽ ...", "I'll ...", "I will ...", "can you ..."). task starts with a verb and keeps the object and details.
  owner: who will do it, only if named in the line or the speaker commits themselves ("I will ...", "em sẽ ..." -> that speaker's label, e.g. "Me", "Speaker 2"); otherwise null. Never guess.
  due: the deadline in the transcript's own words; null if none was said for that task. Do not compute or convert dates.
- open_questions: questions explicitly left undecided, unresolved or deferred to later.
- points: 1-3 short bullets naming the main topics or outcomes of this part.
- time: the [HH:MM:SS] timestamp of the line where the item is said.
Write each item in your own short words (at most 20 words). Never copy whole transcript lines.
Not items: status updates (progress percentages, numbers, "no updates", customer feedback), opinions, greetings, small talk, rhetorical questions and vague intentions ("need more time to review X", "let's keep an eye on X", "can we take X offline", "test again after release"). Most parts contain only 0-2 items; empty lists are fine. Never invent items, people, numbers or dates.
{sections}{glossary}
The transcript comes from speech recognition and may misspell names and terms; interpret charitably and use the glossary spellings when a word clearly refers to a glossary entry.
Answer with JSON only."""

EXTRACT_USER = """Part {part} of {parts} of the meeting transcript:
{transcript}

Write every item in {language}."""

KINDS = ("decision", "action", "question")


def write_schema(language: str) -> dict:
    """The text key names the notes language ("text_in_vietnamese"): writing that key steers a small model into
    the language better than the instruction alone."""
    key = text_key(language)
    return {
        "type": "object",
        "properties": {"items": {"type": "array", "items": {
            "type": "object",
            "properties": {"id": {"type": "integer"}, "kind": {"type": "string", "enum": list(KINDS)},
                           key: {"type": "string", "maxLength": 240},
                           "owner": {"type": ["string", "null"]}, "due": {"type": ["string", "null"]}},
            "required": ["id", "kind", key, "owner", "due"]}}},
        "required": ["items"],
    }


def text_key(language: str) -> str:
    return "text_in_" + re.sub(r"\W+", "_", LANGUAGE_NAMES.get(language, language).lower())


WRITE_BATCH = 12  # key lines per rewrite call

WRITE_SYSTEM = """You turn key lines of a meeting transcript into short meeting notes.
This is {focus}.

Language: write every text in {language}, even when the line is in another language. Keep names, numbers, dates, product names and technical terms as spoken (English jargon such as bug, timeout, deploy, dashboard stays in English).

Each input item has an id, a kind (decision, action or question), the line before it for context and the line itself. Output exactly one object per id:
- id: the same id.
- kind: the given kind, unless the line clearly is another kind (decision: something agreed, decided or approved; action: a task someone will do or is asked to do; question: a question left open or deferred).
- {text_key}: the item in {language}, at most 20 words. action: start with a verb and keep the object and details. decision: what was decided, with its numbers and dates. question: the open question.
- owner (action only, else null): who will do it, only if the lines name them or the speaker commits themselves ("I will ...", "em sẽ ..." -> that speaker's label, e.g. "Me", "Speaker 2"). Otherwise null. Never guess.
- due (action only, else null): the deadline in the line's own words; null if none was said. Do not compute or convert dates.
Use only the given lines; never invent people, numbers or dates.
{example}{glossary}
Lines come from speech recognition and may misspell names and terms; use the glossary spellings when a word clearly refers to a glossary entry.
Answer with JSON only."""

# Worked examples per notes language: small models otherwise copy English lines into Vietnamese notes and
# take the speaker as the owner of a task they assign to someone else.
WRITE_EXAMPLES = {
    "vi": ("id 7 | action | before: [00:10:00] Me: Ai gửi hóa đơn được không? | line: [00:10:02] Speaker 1: "
           "I'll send the invoice to the client by Monday.",
           '{"id": 7, "kind": "action", "text_in_vietnamese": "Gửi hóa đơn cho khách hàng", "owner": "Speaker 1", '
           '"due": "by Monday"}',
           "id 8 | action | before: - | line: [00:11:00] Me: Anh Hùng sẽ cập nhật lịch trực trước thứ sáu nhé.",
           '{"id": 8, "kind": "action", "text_in_vietnamese": "Cập nhật lịch trực", "owner": "Hùng", '
           '"due": "trước thứ sáu"}'),
    "en": ("id 7 | action | before: [00:10:00] Me: Ai gửi hóa đơn được không? | line: [00:10:02] Speaker 1: "
           "Em sẽ gửi hóa đơn cho khách hàng trước thứ hai.",
           '{"id": 7, "kind": "action", "text_in_english": "Send the invoice to the client", "owner": "Speaker 1", '
           '"due": "trước thứ hai"}',
           "id 8 | action | before: - | line: [00:11:00] Me: Hung will update the on-call schedule by Friday.",
           '{"id": 8, "kind": "action", "text_in_english": "Update the on-call schedule", "owner": "Hung", "due": "by Friday"}'),
}

WRITE_USER = """Items:
{items}

Write every text in {language}, one object per id."""

OVERVIEW_SYSTEM = """You write the title and overview of a meeting from notes already extracted from its parts.
This is {focus}.
Write in {language}. Use only the notes; never invent facts.
- title: 3-8 words naming the meeting topic; no date, no quotes.
- summary: 3-8 short bullet points for the whole meeting, most important first, one fact per bullet; mention the key decisions.
Answer with JSON only."""

OVERVIEW_USER = """Main points per part, in order:
{points}

Decisions:
{decisions}"""

SINGLE_USER = """Meeting transcript:
{transcript}"""


def build_system(language: str, template: str = "general", glossary: list[str] | None = None,
                 speakers: list[str] | None = None, base: str = SYSTEM) -> str:
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
    example = ""
    if language in WRITE_EXAMPLES:
        shots = WRITE_EXAMPLES[language]
        example = "\nExamples (input item, then its output object):\n" + "".join(
            f"{shots[k]}\n{shots[k + 1]}\n" for k in range(0, len(shots), 2))
    return base.format(focus=tpl["focus"], language=LANGUAGE_NAMES.get(language, language), sections=sections,
                       glossary=extra, example=example, text_key=text_key(language))


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

    def chat(self, system: str, user: str, tick: Callable[[int], None] | None = None, fmt: dict | None = None,
             raw: bool = False) -> dict:
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
        return parse_json("".join(parts), raw)


def parse_json(content: str, raw: bool = False) -> dict:
    content = re.sub(r"<think>.*?</think>", "", content, flags=re.S).strip()
    match = re.search(r"\{.*\}", content, flags=re.S)
    if not match:
        raise OllamaError("model did not return JSON")
    data = json.loads(match.group(0))
    return data if raw else normalize_notes(data)


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


# ---------------------------------------------------------------- deterministic merge

def parse_time(value, default: float = 0.0) -> float:
    """"[00:12:59]" / "12:59" / "00:12:59" -> seconds; anything else -> default."""
    m = re.search(r"(?:(\d{1,2}):)?(\d{1,2}):(\d{2})", str(value or ""))
    if not m:
        return default
    h, mi, se = (int(x) if x else 0 for x in m.groups())
    return float(h * 3600 + mi * 60 + se)


def _tokens(text: str) -> set[str]:
    return set(fold(text).split())


def similar(a: str, b: str) -> bool:
    """Same item said twice: high word overlap (accent- and punctuation-insensitive)."""
    ta, tb = _tokens(a), _tokens(b)
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


def _strings(value) -> list[str]:
    if isinstance(value, str):
        value = [value]
    return [" ".join(str(v).split()) for v in (value or []) if str(v).strip()]


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
        "points": _strings(data.get("points")),
    }
    if isinstance(data.get("sections"), dict):
        out["sections"] = {str(k): _strings(v) for k, v in data["sections"].items()}
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


def _same_line(item: dict, line: str, kind: str | None = None) -> bool:
    """The item was extracted from this line: near-identical text, or the same timestamp and shared content words
    (fewer needed when the kinds agree: an item translated from its line shares only names, terms and numbers).
    A timestamp alone is not enough: a paragraph of several sentences shares one."""
    text = item.get("text") or item.get("task") or ""
    if similar(text, line_text(line)):
        return True
    if item.get("time") != parse_time(line[:12], -1.0):
        return False
    words = {w for w in _tokens(line_text(line)) if len(w) > 1}
    other = {w for w in _tokens(text) if len(w) > 1}
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
    return finish(summarize_long(client, transcript_lines, language, template, cfg, speakers, progress))


def summarize_long(client: "Ollama", lines: list[str], language: str, template: str, cfg: Config,
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
        hits = [n for n, item in enumerate(found) if n not in drop and _same_line(item, line, kind)]
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
    summary = _strings(overview.get("summary"))[:8] or [p["points"][0] for p in parts if p["points"]][:8]
    return {"title": title, "summary": summary, **notes}


def write_key_lines(client: "Ollama", lines: list[str], ids: list[int], language: str, template: str, cfg: Config,
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
