"""Meeting folder names, titles and the audio file types the pipeline accepts."""

from __future__ import annotations

import re
from datetime import datetime

from .timecode import folder_stamp

AUDIO_EXTS = {".wav", ".m4a", ".mp3", ".aac", ".flac", ".ogg", ".opus", ".caf", ".aiff", ".mp4", ".mov", ".webm"}
DEFAULT_TITLES = {"default", "app", "llm", ""}  # titles the pipeline may replace


def describe_diarization(methods: list[str], notes: list[str]) -> str:
    joined = " ".join(methods)
    if "pyannote" in joined or "sherpa-onnx" in joined:  # full diarization ran
        return ""
    if "clustering" in joined:
        return "speakers estimated by voice clustering (pyannote not available); labels may be imperfect"
    if "mic=" in joined and "system=" in joined:
        return "\"Me\" = microphone, \"Others\" = system audio; individual remote speakers not separated"
    return "speakers not separated"


_FOLDER_PREFIX = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{4})")


def sanitize_title(title: str, max_len: int = 60) -> str:
    title = re.sub(r"[/\\:*?\"<>|\x00-\x1f]", " ", title)
    title = " ".join(title.split()).strip(" .")
    if len(title) > max_len:
        title = title[:max_len].rsplit(" ", 1)[0] or title[:max_len]
    return title or "Meeting"


def folder_name(current: str, started_at: str | None, title: str) -> str:
    match = _FOLDER_PREFIX.match(current)
    if match:
        prefix = match.group(1)
    elif started_at:
        prefix = folder_stamp(datetime.fromisoformat(started_at))
    else:
        prefix = folder_stamp(datetime.now())
    return f"{prefix} {sanitize_title(title)}"
