"""Notes vocabulary: languages, summary templates and the JSON schemas the model must answer with."""

from __future__ import annotations

import re

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
