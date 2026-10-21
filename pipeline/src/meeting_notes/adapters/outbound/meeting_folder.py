"""A meeting folder on disk: meeting.json, .work/, small JSON/file helpers (implements MeetingStore)."""

from __future__ import annotations

import json
import os
import shutil
from datetime import datetime
from pathlib import Path

from ...application.errors import PipelineError
from ...domain.meeting_naming import AUDIO_EXTS
from ...domain.timecode import iso_seconds

WORK = ".work"


def read_json(path: Path) -> dict | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def write_json(path: Path, data: dict) -> None:
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except (ProcessLookupError, PermissionError):
        return False
    except OSError:
        return False


def unique_path(parent: Path, name: str) -> Path:
    candidate = parent / name
    i = 2
    while candidate.exists():
        candidate = parent / f"{name} {i}"
        i += 1
    return candidate


class MeetingFolder:
    def __init__(self, path: Path):
        self.path = path.resolve()
        self.work = self.path / WORK

    def file(self, name: str) -> Path:
        return self.path / name

    @property
    def meeting(self) -> dict:
        data = read_json(self.file("meeting.json"))
        if data is None:
            data = self._infer_meeting()
            write_json(self.file("meeting.json"), data)
        return data

    def _infer_meeting(self) -> dict:
        """Folder without meeting.json (e.g. dropped-in audio): treat the audio as one mixed track."""
        known = {"mic", "system", "mixed"}
        tracks = {}
        for name in known:
            for ext in (".wav", ".m4a"):
                if self.file(name + ext).exists():
                    tracks[name] = {"file": name + ext, "start_offset_sec": 0.0}
                    break
        if not tracks:
            files = sorted(p for p in self.path.iterdir() if p.suffix.lower() in AUDIO_EXTS)
            if not files:
                raise PipelineError(f"No meeting.json or audio file in {self.path}")
            tracks["mixed"] = {"file": files[0].name, "start_offset_sec": 0.0}
        stat = self.file(next(iter(tracks.values()))["file"]).stat()
        return {
            "version": 1, "title": "Meeting", "title_source": "default",
            "started_at": iso_seconds(datetime.fromtimestamp(stat.st_mtime)),
            "tracks": tracks, "warnings": [],
        }

    def track_sources(self) -> dict[str, tuple[Path, float]]:
        """Track name -> (file, start offset). Falls back to the aligned .m4a once the WAV is gone."""
        out = {}
        for name, info in (self.meeting.get("tracks") or {}).items():
            path = self.file(info["file"])
            offset = float(info.get("start_offset_sec") or 0.0)
            if not path.exists():
                alt = self.file(Path(info["file"]).stem + ".m4a")
                if not alt.exists():
                    continue
                path, offset = alt, 0.0  # m4a outputs are already aligned
            out[name] = (path, offset)
        if not out:
            raise PipelineError("No audio track found (expected mic.wav / system.wav or meeting.json tracks)")
        return out


class MeetingStore:
    """Opens meeting folders; the file helpers the use cases need, behind one object."""

    def open(self, path: Path) -> MeetingFolder:
        return MeetingFolder(path)

    def read_json(self, path: Path) -> dict | None:
        return read_json(path)

    def write_json(self, path: Path, data: dict) -> None:
        write_json(path, data)

    def pid_alive(self, pid: int) -> bool:
        return pid_alive(pid)

    def unique_path(self, parent: Path, name: str) -> Path:
        return unique_path(parent, name)

    def copy_file(self, src: Path, dest: Path) -> None:
        shutil.copy2(src, dest)

    def exists(self, path: Path) -> bool:
        return path.exists()

    def mkdir(self, path: Path) -> None:
        path.mkdir(parents=True, exist_ok=True)

    def write_text(self, path: Path, text: str) -> None:
        path.write_text(text, encoding="utf-8")

    def unlink(self, path: Path) -> None:
        path.unlink(missing_ok=True)

    def rename(self, src: Path, dest: Path) -> None:
        src.rename(dest)

    def size(self, path: Path) -> int:
        return path.stat().st_size

    def mtime(self, path: Path) -> float:
        return path.stat().st_mtime

    def glob(self, folder: Path, pattern: str) -> list[Path]:
        return sorted(folder.glob(pattern))
