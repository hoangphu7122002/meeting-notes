"""Resumable processing of one meeting folder.

Stages and their outputs (a stage is skipped when its output exists, unless forced):
  prepare    -> .work/prepare.json, .work/<track>.16k.wav, <track>.m4a, mixed.m4a
  diarize    -> .work/diarization.json
  transcribe -> transcript.json
  summarize  -> .work/summary.json
  render     -> notes.md
  finalize   -> folder renamed to the meeting title, raw WAVs and scratch audio removed
"""

from __future__ import annotations

import json
import os
import re
import shutil
import traceback
from datetime import datetime
from pathlib import Path

import numpy as np

from . import audio as A
from .config import Config, redact
from .events import STAGES, Cancelled, Reporter
from .models import Models, preload_ollama
from .speakers import Turn, build_blocks, resolve_single_track, resolve_two_tracks, speaker_order

AUDIO_EXTS = {".wav", ".m4a", ".mp3", ".aac", ".flac", ".ogg", ".opus", ".caf", ".aiff", ".mp4", ".mov", ".webm"}
WORK = ".work"
DEFAULT_TITLES = {"default", "app", "llm", ""}  # titles the pipeline may replace


class PipelineError(RuntimeError):
    pass


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
            "started_at": datetime.fromtimestamp(stat.st_mtime).astimezone().isoformat(timespec="seconds"),
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


class Processor:
    def __init__(self, folder: Path, cfg: Config, reporter: Reporter, models: Models | None = None):
        self.m = MeetingFolder(folder)
        self.cfg = cfg
        self.r = reporter
        self.models = models or Models(cfg, keep=False, log=reporter.log)
        self.r.log_file = self.m.file("pipeline.log")
        self.warnings: list[str] = []
        self.forced: set[str] = set()

    # ------------------------------------------------------------ driver

    def run(self, from_stage: str | None = None) -> Path:
        status = read_json(self.m.file("status.json")) or {}
        if status.get("state") == "running" and status.get("pid") not in (None, os.getpid()) and pid_alive(int(status["pid"])):
            raise PipelineError(f"Already being processed by pid {status['pid']}")
        self.m.work.mkdir(exist_ok=True)
        self.forced = set(STAGES[STAGES.index(from_stage):]) if from_stage else set()
        self._status("running")
        self.r.audio_sec = self._audio_duration()
        if self.cfg.ollama_preload and self._will_summarize():
            preload_ollama(self.cfg)  # loads in parallel with diarization/transcription
        stage = None
        try:
            for stage in STAGES:
                getattr(self, f"stage_{stage}")(stage in self.forced)
                if stage == "transcribe" and self._will_summarize():
                    self._render_partial()
            self._status("done", timings=self.r.timings)
            transcript = read_json(self.m.file("transcript.json")) or {}
            self.r.done(self.m.path, self.m.file("notes.md"), transcript.get("title") or self.m.meeting.get("title", ""))
            return self.m.path
        except Cancelled:
            self.r.log("cancelled")
            self._status("cancelled", stage=stage)
            self.r.cancelled(self.m.path)
            raise
        except Exception as exc:
            message = redact(f"{exc}")
            self.r.log(redact(traceback.format_exc()))
            self.r.error(message)
            self._status("failed", error=message, stage=stage)
            raise

    def _audio_duration(self) -> float | None:
        for source in (self.m.work / "prepare.json", self.m.file("transcript.json")):
            value = (read_json(source) or {}).get("duration_sec")
            if value:
                return float(value)
        value = self.m.meeting.get("duration_sec") if self.m.file("meeting.json").exists() else None
        return float(value) if value else None

    def _will_summarize(self) -> bool:
        return "summarize" in self.forced or not (self.m.work / "summary.json").exists()

    def _render_partial(self) -> None:
        """Write notes.md with the transcript right away; the summary follows."""
        from .render import render_notes

        transcript = read_json(self.m.file("transcript.json")) or {}
        if not transcript.get("segments"):
            return
        self.m.file("notes.md").write_text(render_notes(self.m.meeting, transcript, None, pending=True), encoding="utf-8")
        self.r.partial(self.m.path, self.m.file("notes.md"))

    def _status(self, state: str, **extra) -> None:
        data = {"state": state, "pid": os.getpid(), "updated_at": datetime.now().astimezone().isoformat(timespec="seconds"),
                "warnings": self.warnings, **extra}
        write_json(self.m.file("status.json"), data)

    def _warn(self, message: str) -> None:
        self.warnings.append(message)
        self.r.warning(message)

    def _skip(self, stage: str, output: Path, force: bool) -> bool:
        if output.exists() and not force:
            self.r.stage_end(stage, "skipped", f"{output.name} exists")
            return True
        self.r.stage_start(stage)
        return False

    # ------------------------------------------------------------ stages

    def stage_prepare(self, force: bool) -> None:
        marker = self.m.work / "prepare.json"
        needs_audio = bool(self.forced & {"diarize", "transcribe"}) or not (
            (self.m.work / "diarization.json").exists() and self.m.file("transcript.json").exists()
        )
        if not force and not needs_audio:
            self.r.stage_end("prepare", "skipped", "transcript exists")
            return
        sources = self.m.track_sources()
        names = sorted(sources)
        if marker.exists() and not force and all((self.m.work / f"{n}.16k.wav").exists() for n in names):
            self.r.stage_end("prepare", "skipped", "audio ready")
            return
        self.r.stage_start("prepare", "Decoding audio")
        decoded = {}
        for i, name in enumerate(names):
            path, offset = sources[name]
            decoded[name] = (A.decode(path), offset)
            self.r.progress((i + 1) / (len(names) + 2), f"Decoded {path.name}")
        length = max(int(round(off * A.SR)) + len(x) for x, off in decoded.values())
        placed = {name: A.place(x, off, length) for name, (x, off) in decoded.items()}
        for name, x in placed.items():
            A.write_wav(self.m.work / f"{name}.16k.wav", x)
        # Listening copies: aligned per-track m4a + mixed m4a (from the original-rate sources).
        if len(sources) > 1:
            for name, (path, offset) in sources.items():
                dest = self.m.file(f"{name}.m4a")
                if path != dest and (force or not dest.exists()):
                    A.encode_m4a([(path, offset)], dest)
            if force or not self.m.file("mixed.m4a").exists():
                A.encode_m4a(list(sources.values()), self.m.file("mixed.m4a"))
        else:
            (path, offset), = sources.values()
            if path != self.m.file("mixed.m4a") and (force or not self.m.file("mixed.m4a").exists()):
                A.encode_m4a([(path, offset)], self.m.file("mixed.m4a"))
        write_json(marker, {"tracks": names, "duration_sec": round(length / A.SR, 2)})
        self.r.audio_sec = length / A.SR
        self.r.stage_end("prepare", message=f"{len(names)} track(s), {length / A.SR / 60:.1f} min")

    def _audio(self) -> dict[str, np.ndarray]:
        names = (read_json(self.m.work / "prepare.json") or {}).get("tracks", [])
        return {n: A.read_wav(self.m.work / f"{n}.16k.wav") for n in names}

    def stage_diarize(self, force: bool) -> None:
        out = self.m.work / "diarization.json"
        if self._skip("diarize", out, force):
            return
        tracks = self._audio()
        diarizer = self.models.diarizer()
        notes: list[str] = []
        methods: list[str] = []
        try:
            if "system" in tracks and "mic" in tracks:
                self.r.progress(0.0, "Finding remote speakers")
                sys_d = diarizer.diarize(tracks["system"], lambda f: self.r.progress(0.6 * f, "Finding remote speakers"))
                self.r.progress(0.6, "Finding local speakers")
                mic_d = diarizer.diarize(tracks["mic"], lambda f: self.r.progress(0.6 + 0.4 * f, "Finding local speakers"))
                remote = [(s, e) for s, e, _ in sys_d.turns]
                bleed_corr = A.bleed_ratio(tracks["mic"], tracks["system"], remote)
                bleed = bleed_corr > 0.35
                others = "Others" if sys_d.method == "vad" else None
                turns = resolve_two_tracks(mic_d.turns, sys_d.turns, bleed, self.cfg.me_name, self.cfg.mic_speakers, others)
                methods = [f"system={sys_d.method}", f"mic={mic_d.method}"]
                notes = sys_d.notes + [n for n in mic_d.notes if n not in sys_d.notes]
                if bleed:
                    notes.append(f"mic picks up speaker audio (corr {bleed_corr:.2f}); mic speech during remote speech was dropped")
            else:
                name = next(iter(tracks))
                d = diarizer.diarize(tracks[name], lambda f: self.r.progress(f, "Finding speakers"))
                if name == "mic":  # mic only (system audio not captured): the user, unless several voices
                    turns = resolve_two_tracks(d.turns, [], False, self.cfg.me_name, self.cfg.mic_speakers)
                else:
                    single = ("Others" if name == "system" else "Speaker") if d.method == "vad" else None
                    turns = resolve_single_track(d.turns, name, single)
                methods, notes = [f"{name}={d.method}"], d.notes
        finally:
            self.models.done_with_diarizer()
        note = describe_diarization(methods, notes)
        if any("pyannote unavailable" in n for n in notes):
            self._warn("pyannote diarization unavailable (accept the model terms on Hugging Face, see README); used fallback")
        write_json(out, {"methods": methods, "notes": notes, "note": note, "turns": [t.to_dict() for t in turns]})
        self.r.stage_end("diarize", message=f"{len({t.speaker for t in turns})} speaker(s), {', '.join(methods)}")

    def stage_transcribe(self, force: bool) -> None:
        out = self.m.file("transcript.json")
        if self._skip("transcribe", out, force):
            return
        from .transcribe import language_stats, split_long_blocks, transcribe_blocks

        diar = read_json(self.m.work / "diarization.json") or {}
        turns = [Turn(**t) for t in diar.get("turns", [])]
        tracks = self._audio()
        blocks = split_long_blocks(build_blocks(turns), tracks)
        self.r.progress(0.0, f"Loading {self.cfg.whisper_model.split('/')[-1]}")
        transcriber = self.models.transcriber()
        try:
            segments = transcribe_blocks(blocks, tracks, transcriber, self.cfg.languages, lambda f, msg: self.r.progress(f, msg))
        finally:
            self.models.done_with_transcriber()
        stats = language_stats(segments)
        language = next(iter(stats), (self.cfg.languages or ["en"])[0])
        meeting = self.m.meeting
        duration = (read_json(self.m.work / "prepare.json") or {}).get("duration_sec")
        spoken = {s.speaker for s in segments}
        transcript = {
            "version": 1,
            "title": meeting.get("title", "Meeting"),
            "started_at": meeting.get("started_at"),
            "duration_sec": duration,
            "language": language,
            "languages": {k: round(v, 1) for k, v in stats.items()},
            "speakers": [s for s in speaker_order(turns, self.cfg.me_name) if s in spoken],
            "diarization": {"methods": diar.get("methods", []), "note": diar.get("note", "")},
            "whisper_model": self.cfg.whisper_model,
            "pauses": meeting.get("pauses") or [],
            "segments": [s.to_dict() for s in segments],
        }
        write_json(out, transcript)
        if not segments:
            self._warn("No speech was transcribed")
        self.r.stage_end("transcribe", message=f"{len(segments)} segments, language {language}")

    def stage_summarize(self, force: bool) -> None:
        out = self.m.work / "summary.json"
        if self._skip("summarize", out, force):
            return
        from .render import transcript_lines
        from .summarize import summarize

        transcript = read_json(self.m.file("transcript.json")) or {}
        lines = transcript_lines(transcript.get("segments", []))
        if not lines:
            self.r.stage_end("summarize", "skipped", "empty transcript")
            return
        try:
            notes = summarize(lines, transcript.get("language", "en"), self.cfg, lambda f, msg: self.r.progress(f, msg))
        except Cancelled:
            raise
        except Exception as exc:
            self._warn(f"Summary failed: {redact(str(exc))}")
            write_json(self.m.work / "summary.error.json", {"error": redact(str(exc))})
            self.r.stage_end("summarize", "failed", "notes rendered without summary; re-run to retry")
            return
        notes["model"] = self.cfg.ollama_model
        write_json(out, notes)
        (self.m.work / "summary.error.json").unlink(missing_ok=True)
        self.r.stage_end("summarize", message=notes.get("title", ""))

    def stage_render(self, force: bool) -> None:
        from .render import render_notes

        self.r.stage_start("render")
        transcript = read_json(self.m.file("transcript.json")) or {}
        summary = read_json(self.m.work / "summary.json")
        error = (read_json(self.m.work / "summary.error.json") or {}).get("error")
        meeting = self.m.meeting
        if summary and summary.get("title") and meeting.get("title_source", "default") in DEFAULT_TITLES:
            transcript["title"] = summary["title"]
            write_json(self.m.file("transcript.json"), transcript)
        self.m.file("notes.md").write_text(render_notes(meeting, transcript, summary, error), encoding="utf-8")
        self.r.stage_end("render", message="notes.md written")

    def stage_finalize(self, force: bool) -> None:
        self.r.stage_start("finalize")
        meeting = self.m.meeting
        sources = meeting.get("tracks") or {}
        # Drop raw WAVs once the aligned m4a copies exist.
        if not self.cfg.keep_wav:
            for name, info in sources.items():
                raw = self.m.file(info["file"])
                m4a = self.m.file(f"{name}.m4a") if len(sources) > 1 else self.m.file("mixed.m4a")
                disposable = raw.suffix.lower() == ".wav" or raw.name.startswith("source.")
                if disposable and raw != m4a and raw.exists() and m4a.exists() and m4a.stat().st_size > 0:
                    raw.unlink()
                    info["file"] = m4a.name
                    info["start_offset_sec"] = 0.0
            write_json(self.m.file("meeting.json"), meeting)
            for p in self.m.work.glob("*.16k.wav"):
                p.unlink()
            (self.m.work / "prepare.json").unlink(missing_ok=True)
        # Rename the folder after the meeting title.
        summary = read_json(self.m.work / "summary.json") or {}
        if meeting.get("title_source", "default") in DEFAULT_TITLES:
            title = summary.get("title")
            if title:
                meeting["title"], meeting["title_source"] = title, "llm"
                write_json(self.m.file("meeting.json"), meeting)
        else:
            title = meeting.get("title")  # set by the user
        if self.cfg.rename_folder and title:
            name = folder_name(self.m.path.name, meeting.get("started_at"), title)
            if not re.fullmatch(re.escape(name) + r"( \d+)?", self.m.path.name):
                new_path = unique_path(self.m.path.parent, name)
                self.m.path.rename(new_path)
                self.m = MeetingFolder(new_path)
                self.r.log_file = self.m.file("pipeline.log")
        self.r.stage_end("finalize", message=self.m.path.name)


# ---------------------------------------------------------------- helpers

def describe_diarization(methods: list[str], notes: list[str]) -> str:
    joined = " ".join(methods)
    if "pyannote" in joined:
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
        prefix = datetime.fromisoformat(started_at).strftime("%Y-%m-%d %H%M")
    else:
        prefix = datetime.now().strftime("%Y-%m-%d %H%M")
    return f"{prefix} {sanitize_title(title)}"


def unique_path(parent: Path, name: str) -> Path:
    candidate = parent / name
    i = 2
    while candidate.exists():
        candidate = parent / f"{name} {i}"
        i += 1
    return candidate


def import_audio(src: Path, notes_dir: Path, title: str | None = None) -> Path:
    """Create a meeting folder from an existing audio/video file (the source is copied, never moved)."""
    if not src.exists():
        raise PipelineError(f"{src} not found")
    started = datetime.fromtimestamp(src.stat().st_mtime).astimezone()
    notes_dir.mkdir(parents=True, exist_ok=True)
    folder = unique_path(notes_dir, f"{started.strftime('%Y-%m-%d %H%M')} {sanitize_title(title or src.stem)}")
    folder.mkdir()
    dest = folder / f"source{src.suffix.lower()}"
    shutil.copy2(src, dest)
    write_json(folder / "meeting.json", {
        "version": 1, "title": title or src.stem, "title_source": "user" if title else "default",
        "started_at": started.isoformat(timespec="seconds"),
        "tracks": {"mixed": {"file": dest.name, "start_offset_sec": 0.0}}, "warnings": [],
    })
    return folder
