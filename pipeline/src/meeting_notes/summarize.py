"""Meeting summary with a local Ollama model (map-reduce for long transcripts)."""

from __future__ import annotations

import json
import re
import urllib.error
import urllib.request
from collections.abc import Callable

from .config import Config

LANGUAGE_NAMES = {
    "vi": "Vietnamese", "en": "English", "zh": "Chinese", "ja": "Japanese", "ko": "Korean",
    "fr": "French", "de": "German", "es": "Spanish", "th": "Thai", "id": "Indonesian",
}

SCHEMA = {
    "type": "object",
    "properties": {
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
    },
    "required": ["title", "summary", "decisions", "action_items", "open_questions"],
}

SYSTEM = """You are a meticulous meeting assistant. You turn a speaker-labelled meeting transcript into concise notes.
Rules:
- Use only information stated in the transcript. Never invent names, numbers, dates or commitments.
- Write every field in {language}, even if parts of the meeting use another language. Keep technical terms, product names and English jargon as spoken.
- title: 3-8 words naming the meeting topic, no date, no quotes.
- summary: 3-8 bullet points with the main points discussed, most important first.
- decisions: things the participants agreed or decided. Empty list if none.
- action_items: concrete tasks someone committed to or was asked to do. owner = the person's name if mentioned, otherwise the speaker label (e.g. "Me", "Speaker 2"); null if unclear. due = the deadline exactly as mentioned (e.g. "Friday", "next week"), null if none.
- open_questions: unresolved questions or topics needing follow-up. Empty list if none.
- The transcript comes from automatic speech recognition and may contain errors; interpret charitably.
Answer with JSON only."""

MAP_USER = """This is part {part} of {parts} of a meeting transcript. Extract notes for this part only.

Transcript:
{transcript}"""

REDUCE_USER = """Below are notes extracted from consecutive parts of one meeting. Merge them into final notes for the whole meeting: deduplicate, keep the most important points, keep every distinct action item.

Partial notes (JSON):
{notes}"""

SINGLE_USER = """Meeting transcript:
{transcript}"""


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

    def chat(self, system: str, user: str) -> dict:
        payload = {
            "model": self.cfg.ollama_model,
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
            "format": SCHEMA,
            "stream": False,
            "think": False,
            "keep_alive": "2m",
            "options": {"temperature": 0.2, "num_ctx": self.cfg.ollama_num_ctx},
        }
        with self._request("/api/chat", payload, timeout=self.cfg.ollama_timeout_sec) as resp:
            body = json.load(resp)
        if body.get("error"):
            raise OllamaError(body["error"])
        return parse_json(body.get("message", {}).get("content", ""))


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

    items = []
    for item in data.get("action_items") or []:
        if isinstance(item, str):
            item = {"task": item}
        task = " ".join(str(item.get("task", "")).split())
        if not task:
            continue
        owner = item.get("owner") or None
        due = item.get("due") or None
        if isinstance(owner, str) and owner.strip().lower() in ("", "null", "none", "unknown", "n/a"):
            owner = None
        if isinstance(due, str) and due.strip().lower() in ("", "null", "none", "unknown", "n/a"):
            due = None
        items.append({"task": task, "owner": owner, "due": due})
    return {
        "title": " ".join(str(data.get("title") or "").split()).strip("\"'“”"),
        "summary": strings(data.get("summary")),
        "decisions": strings(data.get("decisions")),
        "action_items": items,
        "open_questions": strings(data.get("open_questions")),
    }


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


def summarize(
    transcript_lines: list[str],
    language: str,
    cfg: Config,
    progress: Callable[[float, str], None] | None = None,
) -> dict:
    client = Ollama(cfg)
    client.ensure_model(progress)
    system = SYSTEM.format(language=LANGUAGE_NAMES.get(language, language))
    if not transcript_lines:
        return normalize_notes({"title": "", "summary": [], "decisions": [], "action_items": [], "open_questions": []})
    chunks = chunk_lines(transcript_lines, cfg.summary_chunk_chars)
    if len(chunks) == 1:
        if progress:
            progress(0.1, f"Summarizing with {cfg.ollama_model}")
        return client.chat(system, SINGLE_USER.format(transcript=chunks[0]))
    partials = []
    for i, chunk in enumerate(chunks, 1):
        if progress:
            progress((i - 1) / (len(chunks) + 1), f"Summarizing part {i}/{len(chunks)}")
        partials.append(client.chat(system, MAP_USER.format(part=i, parts=len(chunks), transcript=chunk)))
    if progress:
        progress(len(chunks) / (len(chunks) + 1), "Merging partial summaries")
    merged = json.dumps(partials, ensure_ascii=False)
    if len(merged) > cfg.summary_chunk_chars * 1.5:  # very long meetings: merge pairwise first
        while len(partials) > 1 and len(json.dumps(partials, ensure_ascii=False)) > cfg.summary_chunk_chars * 1.5:
            partials = [
                client.chat(system, REDUCE_USER.format(notes=json.dumps(partials[i:i + 2], ensure_ascii=False)))
                for i in range(0, len(partials), 2)
            ]
        merged = json.dumps(partials, ensure_ascii=False)
    return client.chat(system, REDUCE_USER.format(notes=merged))
