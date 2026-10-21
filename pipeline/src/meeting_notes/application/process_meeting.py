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

import os
import re
import traceback
from datetime import datetime
from pathlib import Path

import numpy as np

from ..config import Config, redact
from ..domain.meeting_naming import DEFAULT_TITLES, describe_diarization, folder_name
from ..domain.notes_markdown import render_notes, transcript_lines
from ..domain.notes_rules import summary_language
from ..domain.segments import language_stats, split_long_blocks
from ..domain.signal import SR, place
from ..domain.speakers import Turn, build_blocks, speaker_order
from ..domain.stages import STAGES
from ..domain.timecode import iso_seconds
from .diarize_tracks import diarize_tracks
from .errors import Cancelled, PipelineError
from .ports import ModelProvider, ProgressReporter
from .processor_deps import ProcessorDeps


class Processor:
    def __init__(self, folder: Path, cfg: Config, reporter: ProgressReporter, deps: ProcessorDeps,
                 models: ModelProvider | None = None):
        self.deps = deps
        self.store = deps.store
        self.audio = deps.audio
        self.m = self.store.open(folder)
        self.cfg = cfg
        self.r = reporter
        self.models = models or deps.make_models(cfg, False, reporter.log)
        self.r.log_file = self.m.file("pipeline.log")
        self.warnings: list[str] = []
        self.forced: set[str] = set()

    # ------------------------------------------------------------ driver

    def run(self, from_stage: str | None = None) -> Path:
        status = self.store.read_json(self.m.file("status.json")) or {}
        if status.get("state") == "running" and status.get("pid") not in (None, os.getpid()) and self.store.pid_alive(int(status["pid"])):
            raise PipelineError(f"Already being processed by pid {status['pid']}")
        self.store.mkdir(self.m.work)
        self.forced = set(STAGES[STAGES.index(from_stage):]) if from_stage else set()
        self._status("running")
        self.r.audio_sec = self._audio_duration()
        if self.cfg.ollama_preload and self._will_summarize():
            self.deps.preload(self.cfg)  # loads in parallel with diarization/transcription
        stage = None
        try:
            for stage in STAGES:
                getattr(self, f"stage_{stage}")(stage in self.forced)
                if stage == "transcribe" and self._will_summarize():
                    self._render_partial()
            self._status("done", timings=self.r.timings)
            transcript = self.store.read_json(self.m.file("transcript.json")) or {}
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
            value = (self.store.read_json(source) or {}).get("duration_sec")
            if value:
                return float(value)
        value = self.m.meeting.get("duration_sec") if self.store.exists(self.m.file("meeting.json")) else None
        return float(value) if value else None

    def _will_summarize(self) -> bool:
        return "summarize" in self.forced or not self.store.exists(self.m.work / "summary.json")

    def _render_partial(self) -> None:
        """Write notes.md with the transcript right away; the summary follows."""
        transcript = self.store.read_json(self.m.file("transcript.json")) or {}
        if not transcript.get("segments"):
            return
        self.store.write_text(self.m.file("notes.md"), render_notes(self.m.meeting, transcript, None, pending=True))
        self.r.partial(self.m.path, self.m.file("notes.md"))

    def _status(self, state: str, **extra) -> None:
        data = {"state": state, "pid": os.getpid(), "updated_at": iso_seconds(datetime.now()),
                "warnings": self.warnings, **extra}
        self.store.write_json(self.m.file("status.json"), data)

    def _warn(self, message: str) -> None:
        self.warnings.append(message)
        self.r.warning(message)

    def _skip(self, stage: str, output: Path, force: bool) -> bool:
        if self.store.exists(output) and not force:
            self.r.stage_end(stage, "skipped", f"{output.name} exists")
            return True
        self.r.stage_start(stage)
        return False

    # ------------------------------------------------------------ stages

    def stage_prepare(self, force: bool) -> None:
        marker = self.m.work / "prepare.json"
        needs_audio = bool(self.forced & {"diarize", "transcribe"}) or not (
            self.store.exists(self.m.work / "diarization.json") and self.store.exists(self.m.file("transcript.json"))
        )
        if not force and not needs_audio:
            self.r.stage_end("prepare", "skipped", "transcript exists")
            return
        sources = self.m.track_sources()
        names = sorted(sources)
        if self.store.exists(marker) and not force and all(self.store.exists(self.m.work / f"{n}.16k.wav") for n in names):
            self.r.stage_end("prepare", "skipped", "audio ready")
            return
        self.r.stage_start("prepare", "Decoding audio")
        decoded = {}
        for i, name in enumerate(names):
            path, offset = sources[name]
            decoded[name] = (self.audio.decode(path), offset)
            self.r.progress((i + 1) / (len(names) + 2), f"Decoded {path.name}")
        length = max(int(round(off * SR)) + len(x) for x, off in decoded.values())
        placed = {name: place(x, off, length) for name, (x, off) in decoded.items()}
        for name, x in placed.items():
            self.audio.write_wav(self.m.work / f"{name}.16k.wav", x)
        # Listening copies: aligned per-track m4a + mixed m4a (from the original-rate sources).
        if len(sources) > 1:
            for name, (path, offset) in sources.items():
                dest = self.m.file(f"{name}.m4a")
                if path != dest and (force or not self.store.exists(dest)):
                    self.audio.encode_m4a([(path, offset)], dest)
            if force or not self.store.exists(self.m.file("mixed.m4a")):
                self.audio.encode_m4a(list(sources.values()), self.m.file("mixed.m4a"))
        else:
            (path, offset), = sources.values()
            if path != self.m.file("mixed.m4a") and (force or not self.store.exists(self.m.file("mixed.m4a"))):
                self.audio.encode_m4a([(path, offset)], self.m.file("mixed.m4a"))
        self.store.write_json(marker, {"tracks": names, "duration_sec": round(length / SR, 2)})
        self.r.audio_sec = length / SR
        self.r.stage_end("prepare", message=f"{len(names)} track(s), {length / SR / 60:.1f} min")

    def _audio(self) -> dict[str, np.ndarray]:
        names = (self.store.read_json(self.m.work / "prepare.json") or {}).get("tracks", [])
        return {n: self.audio.read_wav(self.m.work / f"{n}.16k.wav") for n in names}

    def stage_diarize(self, force: bool) -> None:
        out = self.m.work / "diarization.json"
        if self._skip("diarize", out, force):
            return
        tracks = self._audio()
        diarizer = self.models.diarizer()
        try:
            turns, methods, notes = diarize_tracks(tracks, diarizer, self.cfg, self.r)
        finally:
            self.models.done_with_diarizer()
        note = describe_diarization(methods, notes)
        if any("pyannote unavailable" in n for n in notes):
            self._warn("pyannote diarization unavailable (accept the model terms on Hugging Face, see README); used fallback")
        self.store.write_json(out, {"methods": methods, "notes": notes, "note": note, "turns": [t.to_dict() for t in turns]})
        self.r.stage_end("diarize", message=f"{len({t.speaker for t in turns})} speaker(s), {', '.join(methods)}")

    def stage_transcribe(self, force: bool) -> None:
        out = self.m.file("transcript.json")
        if self._skip("transcribe", out, force):
            return
        diar = self.store.read_json(self.m.work / "diarization.json") or {}
        turns = [Turn(**t) for t in diar.get("turns", [])]
        tracks = self._audio()
        blocks = split_long_blocks(build_blocks(turns), tracks, max_len=self.cfg.whisper_max_chunk_sec)
        self.r.progress(0.0, f"Loading {self.cfg.whisper_model.split('/')[-1]}")
        transcriber = self.models.transcriber()
        try:
            segments = self.deps.transcribe_blocks(blocks, tracks, transcriber, self.cfg.languages, lambda f, msg: self.r.progress(f, msg),
                                         vad=self.cfg.whisper_vad, split_gap=self.cfg.vad_split_gap)
        finally:
            self.models.done_with_transcriber()
        stats = language_stats(segments)
        language = next(iter(stats), (self.cfg.languages or ["en"])[0])
        meeting = self.m.meeting
        duration = (self.store.read_json(self.m.work / "prepare.json") or {}).get("duration_sec")
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
        self.store.write_json(out, transcript)
        if not segments:
            self._warn("No speech was transcribed")
        self.r.stage_end("transcribe", message=f"{len(segments)} segments, language {language}")

    def stage_summarize(self, force: bool) -> None:
        out = self.m.work / "summary.json"
        if self._skip("summarize", out, force):
            return
        transcript = self.store.read_json(self.m.file("transcript.json")) or {}
        lines = transcript_lines(transcript.get("segments", []))
        if not lines:
            self.r.stage_end("summarize", "skipped", "empty transcript")
            return
        language = summary_language(transcript.get("languages"), transcript.get("language", "en"), self.cfg.summary_language)
        template = self.m.meeting.get("template") or self.cfg.summary_template
        try:
            notes = self.deps.summarize(lines, language, self.cfg, lambda f, msg: self.r.progress(f, msg), template=template)
        except Cancelled:
            raise
        except Exception as exc:
            self._warn(f"Summary failed: {redact(str(exc))}")
            self.store.write_json(self.m.work / "summary.error.json", {"error": redact(str(exc))})
            self.r.stage_end("summarize", "failed", "notes rendered without summary; re-run to retry")
            return
        notes["model"] = self.cfg.ollama_model
        self.store.write_json(out, notes)
        self.store.unlink(self.m.work / "summary.error.json")
        self.r.stage_end("summarize", message=notes.get("title", ""))

    def stage_render(self, force: bool) -> None:
        self.r.stage_start("render")
        transcript = self.store.read_json(self.m.file("transcript.json")) or {}
        summary = self.store.read_json(self.m.work / "summary.json")
        error = (self.store.read_json(self.m.work / "summary.error.json") or {}).get("error")
        meeting = self.m.meeting
        if summary and summary.get("title") and meeting.get("title_source", "default") in DEFAULT_TITLES:
            transcript["title"] = summary["title"]
            self.store.write_json(self.m.file("transcript.json"), transcript)
        self.store.write_text(self.m.file("notes.md"), render_notes(meeting, transcript, summary, error))
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
                if disposable and raw != m4a and self.store.exists(raw) and self.store.exists(m4a) and self.store.size(m4a) > 0:
                    self.store.unlink(raw)
                    info["file"] = m4a.name
                    info["start_offset_sec"] = 0.0
            self.store.write_json(self.m.file("meeting.json"), meeting)
            for p in self.store.glob(self.m.work, "*.16k.wav"):
                self.store.unlink(p)
            self.store.unlink(self.m.work / "prepare.json")
        # Rename the folder after the meeting title.
        summary = self.store.read_json(self.m.work / "summary.json") or {}
        if meeting.get("title_source", "default") in DEFAULT_TITLES:
            title = summary.get("title")
            if title:
                meeting["title"], meeting["title_source"] = title, "llm"
                self.store.write_json(self.m.file("meeting.json"), meeting)
        else:
            title = meeting.get("title")  # set by the user
        if self.cfg.rename_folder and title:
            name = folder_name(self.m.path.name, meeting.get("started_at"), title)
            if not re.fullmatch(re.escape(name) + r"( \d+)?", self.m.path.name):
                new_path = self.store.unique_path(self.m.path.parent, name)
                self.store.rename(self.m.path, new_path)
                self.m = self.store.open(new_path)
                self.r.log_file = self.m.file("pipeline.log")
        self.r.stage_end("finalize", message=self.m.path.name)
