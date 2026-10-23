"""Ports: what the use cases need from the outside world. Adapters in adapters/outbound implement them."""

from __future__ import annotations

from collections.abc import Callable
from pathlib import Path
from typing import TYPE_CHECKING, Protocol

if TYPE_CHECKING:  # annotations only: importing the ports must not load numpy
    import numpy as np

    from ..domain.live_backlog import LoadSample
    from ..domain.speakers import TrackDiarization
    from ..domain.voice_check import VoiceCheck


class Diarizer(Protocol):
    cfg: object

    def diarize(self, audio: np.ndarray, progress: Callable[[float], None] | None = None) -> TrackDiarization: ...

    def voice_check(self, audio: np.ndarray, exclude: list[tuple[float, float]] | None = None) -> VoiceCheck:
        """VAD turns + whether the track holds a single voice (True), several (False) or unsure (None)."""

    def release(self) -> None: ...


class Transcriber(Protocol):
    cfg: object

    def detect_language(self, audio: np.ndarray) -> dict[str, float]: ...

    def transcribe(self, audio: np.ndarray, language: str) -> list[dict]: ...

    def transcribe_auto(self, audio: np.ndarray, choose: Callable[[dict[str, float]], str]) -> tuple[str, list[dict]]:
        """Detect the language (probabilities -> `choose`) and transcribe with it, sharing one encoder pass."""
        ...

    def release(self) -> None: ...


class LlmClient(Protocol):
    def ensure_model(self, progress: Callable[[float, str], None] | None = None) -> None: ...

    def chat(self, system: str, user: str, tick: Callable[[int], None] | None = None, fmt: dict | None = None,
             raw: bool = False) -> dict: ...

    def list_models(self) -> set[str]: ...


class ModelProvider(Protocol):
    """Lazily loaded diarizer/transcriber shared across jobs; `done_with_*` frees them unless kept warm."""

    def diarizer(self) -> Diarizer: ...

    def transcriber(self) -> Transcriber: ...

    def done_with_diarizer(self) -> None: ...

    def done_with_transcriber(self) -> None: ...


class ManagedModels(ModelProvider, Protocol):
    """A ModelProvider a long-lived worker also warms, reconfigures and releases."""

    keep: bool | str
    last_used: float

    @property
    def loaded(self) -> bool: ...

    def release_if_pressure(self) -> bool: ...

    def update_config(self, cfg) -> None: ...

    def warmup(self) -> dict[str, float]: ...

    def release(self) -> None: ...


class ProgressReporter(Protocol):
    """Stage and progress events for the app/CLI. `progress` and `stage_start` are cancellation points."""

    log_file: Path | None
    audio_sec: float | None
    timings: dict[str, float]

    def stage_start(self, stage: str, message: str = "") -> None: ...

    def stage_end(self, stage: str, status: str = "done", message: str = "") -> None: ...

    def progress(self, fraction: float, message: str = "") -> None: ...

    def warning(self, message: str) -> None: ...

    def error(self, message: str) -> None: ...

    def cancelled(self, folder: Path) -> None: ...

    def partial(self, folder: Path, notes: Path) -> None: ...

    def done(self, folder: Path, notes: Path, title: str) -> None: ...

    def log(self, message: str) -> None: ...

    def live_segment(self, track: str, speaker: str, seq: int, start: float, end: float, language: str,
                     text: str) -> None:
        """One decoded live chunk (its segments joined)."""

    def live_status(self, state: str, backlog_sec: float, skipped_sec: float, rtf: float | None,
                    reason: str | None = None) -> None:
        """running | deferred | throttled | stopped."""

    def live_polish(self, track: str, speaker: str, para: int, seqs: list[int], tier: str, text: str) -> None:
        """Display-only polished text of one live paragraph (replaces earlier text of the same (track, para))."""


class LiveAudioSource(Protocol):
    """The growing tracks of a meeting being recorded (or a replay of a finished one) as 16 kHz audio."""

    def tracks(self) -> list[str]:
        """Tracks known so far (meeting.json may appear a few seconds after the recording starts)."""

    def poll(self, track: str, max_sec: float) -> tuple[float, np.ndarray]:
        """(recorded time of the first new sample, new samples), at most `max_sec` of audio; contiguous."""

    def position(self, track: str) -> float:
        """Recorded time up to which audio exists (polled or not)."""

    def finished(self) -> bool:
        """No more audio will arrive (end of a replay); a live recording never finishes by itself."""


class PartialTranscriptStore(Protocol):
    """Append-only live partials (`.work/transcript.partial.jsonl`): one JSON object per chunk."""

    def load(self) -> list[dict]:
        """Every complete line; a truncated or invalid line is ignored."""

    def append(self, chunk: dict) -> None:
        """Append and fsync one line; raises OSError when the meeting folder is gone."""


class LoadProbe(Protocol):
    def sample(self) -> LoadSample: ...


class StopSignal(Protocol):
    """threading.Event-like: set by `live_stop` (or Ctrl-C in the CLI)."""

    def is_set(self) -> bool: ...

    def wait(self, timeout: float | None = None) -> bool: ...


class AudioIO(Protocol):
    """Decode/encode audio files (ffmpeg) and read/write the 16 kHz working WAVs."""

    def decode(self, path: Path) -> np.ndarray: ...

    def encode_m4a(self, inputs: list[tuple[Path, float]], dest: Path) -> None: ...

    def read_wav(self, path: Path) -> np.ndarray: ...

    def write_wav(self, path: Path, audio: np.ndarray) -> None: ...


class MeetingFolder(Protocol):
    """One meeting folder on disk (meeting.json, .work/, outputs)."""

    path: Path
    work: Path

    def file(self, name: str) -> Path: ...

    @property
    def meeting(self) -> dict: ...

    def track_sources(self) -> dict[str, tuple[Path, float]]: ...


class MeetingStore(Protocol):
    """Opens meeting folders and owns the small file helpers around them."""

    def open(self, path: Path) -> MeetingFolder: ...

    def read_json(self, path: Path) -> dict | None: ...

    def write_json(self, path: Path, data: dict) -> None: ...

    def pid_alive(self, pid: int) -> bool: ...

    def unique_path(self, parent: Path, name: str) -> Path: ...

    def copy_file(self, src: Path, dest: Path) -> None: ...

    def exists(self, path: Path) -> bool: ...

    def mkdir(self, path: Path) -> None:
        """Create the folder with its parents; fine if it already exists."""

    def write_text(self, path: Path, text: str) -> None: ...

    def unlink(self, path: Path) -> None:
        """Delete a file; fine if it is already gone."""

    def rename(self, src: Path, dest: Path) -> None: ...

    def size(self, path: Path) -> int: ...

    def mtime(self, path: Path) -> float: ...

    def glob(self, folder: Path, pattern: str) -> list[Path]: ...


class MeetingProcessor(Protocol):
    """A configured Processor: runs the stages of one meeting folder."""

    def run(self, from_stage: str | None = None) -> Path: ...


class WorkerServer(Protocol):
    """The JSON-lines worker loop; returns the process exit code."""

    def serve(self) -> int: ...


class Summarizer(Protocol):
    """Turns transcript lines into structured notes with the local LLM."""

    def __call__(self, lines: list[str], language: str, cfg, progress: Callable[[float, str], None] | None = None,
                 template: str | None = None) -> dict: ...
