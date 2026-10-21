"""Create a meeting folder from an existing audio/video file."""

from __future__ import annotations

from datetime import datetime
from pathlib import Path

from ..domain.meeting_naming import sanitize_title
from ..domain.timecode import folder_stamp
from .errors import PipelineError
from .ports import MeetingStore


def import_audio(src: Path, notes_dir: Path, title: str | None = None, *, store: MeetingStore) -> Path:
    """Create a meeting folder from an existing audio/video file (the source is copied, never moved)."""
    if not src.exists():
        raise PipelineError(f"{src} not found")
    started = datetime.fromtimestamp(src.stat().st_mtime).astimezone()
    notes_dir.mkdir(parents=True, exist_ok=True)
    folder = store.unique_path(notes_dir, f"{folder_stamp(started)} {sanitize_title(title or src.stem)}")
    folder.mkdir()
    dest = folder / f"source{src.suffix.lower()}"
    store.copy_file(src, dest)
    store.write_json(folder / "meeting.json", {
        "version": 1, "title": title or src.stem, "title_source": "user" if title else "default",
        "started_at": started.isoformat(timespec="seconds"),
        "tracks": {"mixed": {"file": dest.name, "start_offset_sec": 0.0}}, "warnings": [],
    })
    return folder
