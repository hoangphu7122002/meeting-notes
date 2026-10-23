"""Speaker diarization with FluidAudio (opt-in, `diarization_engine = "fluidaudio"`).

FluidAudio's offline pipeline is a Core ML port of pyannote community-1 (segmentation + WeSpeaker embedding + PLDA
+ VBx) that runs on the Neural Engine. It is a Swift SDK, so a small helper CLI (`app/Sources/MeetingNotesDiarize`,
built with `swift build -c release --product MeetingNotesDiarize` in app/) diarizes one WAV per call and prints JSON;
this adapter writes the track to a temporary WAV and shells out to it. No torch for the full pass, no Hugging Face
token: the CLI downloads the ungated, commit-pinned weights on first use into `<repo>/models/fluidaudio/`.
The mic single-voice check and every failure path (binary missing, download or inference error) use the pyannote
Diarizer, so this engine never makes a job fail. Licenses: docs/research/diarization-alternatives.md section 7.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
from collections.abc import Callable
from pathlib import Path

import numpy as np

from ...config import REPO_ROOT, Config
from ...domain.intervals import Interval
from ...domain.signal import SR, energy_vad
from ...domain.speakers import RawTurns, TrackDiarization
from ...domain.voice_check import VoiceCheck

BINARY = "MeetingNotesDiarize"
MODELS_DIR = REPO_ROOT / "models" / "fluidaudio"
BUILD_HINT = f"build it with `swift build -c release --product {BINARY}` in app/"
TOKEN_ENV = ("HF_TOKEN", "HUGGING_FACE_HUB_TOKEN", "HUGGINGFACEHUB_API_TOKEN")  # weights are ungated: never pass one

Runner = Callable[[list[str], float], str]  # (argv, timeout seconds) -> stdout; raises on failure


def find_binary(cfg: Config) -> Path:
    """`fluidaudio_cli` if set, else the release then debug build of the helper in app/.build, else PATH."""
    if str(cfg.fluidaudio_cli).strip():
        path = Path(cfg.fluidaudio_cli).expanduser()
        if path.is_file():
            return path
        raise RuntimeError(f"fluidaudio_cli not found: {path}")
    for kind in ("release", "debug"):
        path = REPO_ROOT / "app" / ".build" / kind / BINARY
        if path.is_file():
            return path
    found = shutil.which(BINARY)
    if found:
        return Path(found)
    raise RuntimeError(f"{BINARY} is not built ({BUILD_HINT})")


def run_cli(argv: list[str], timeout: float) -> str:
    env = {k: v for k, v in os.environ.items() if k not in TOKEN_ENV}
    proc = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, env=env)
    if proc.returncode:
        tail = " ".join((proc.stderr or "").split())[-200:]
        raise RuntimeError(f"{Path(argv[0]).name} exited {proc.returncode}: {tail}")
    return proc.stdout


class FluidAudioDiarizer:
    def __init__(self, cfg: Config, log: Callable[[str], None] = print, fallback=None, runner: Runner | None = None):
        self.cfg = cfg
        self.log = log
        self._binary: Path | None = None
        self._error: str | None = None
        self._fallback = fallback  # pyannote Diarizer, created on demand
        self._run = runner or run_cli

    name = "fluidaudio:community-1-coreml"

    def fallback(self):
        if self._fallback is None:
            from .pyannote_diarizer import Diarizer

            self._fallback = Diarizer(self.cfg, log=self.log)
        self._fallback.cfg = self.cfg
        return self._fallback

    def engine(self) -> Path | None:
        """The helper binary with its models prepared (download + Core ML compile on first use), or None."""
        if self._binary is None and self._error is None:
            try:
                binary = find_binary(self.cfg)
                self._run([str(binary), "--prepare", "--models", str(MODELS_DIR)], 900.0)
                self._binary = binary
            except Exception as exc:
                self._error = _short_error(exc)
        return self._binary

    def diarize(self, audio: np.ndarray, progress: Callable[[float], None] | None = None) -> TrackDiarization:
        if not energy_vad(audio):
            return TrackDiarization([], "vad", ["no speech detected"])
        binary = self.engine()
        if binary is not None:
            try:
                turns = self._diarize(binary, audio)
                if progress:
                    progress(1.0)
                return TrackDiarization(turns, self.name)
            except Exception as exc:
                note = f"fluidaudio failed: {_short_error(exc)}"
        else:
            note = f"fluidaudio unavailable: {self._error}"
        self.log(f"diarization: {note}; using pyannote")
        out = self.fallback().diarize(audio, progress)
        return TrackDiarization(out.turns, out.method, [note, *out.notes])

    def _diarize(self, binary: Path, audio: np.ndarray) -> RawTurns:
        from .wav_files import write_wav

        with tempfile.TemporaryDirectory(prefix="mn-fluidaudio-") as tmp:
            wav = Path(tmp) / "track.wav"
            write_wav(wav, np.asarray(audio, dtype=np.float32), SR)
            timeout = 120.0 + len(audio) / SR  # >= 1x realtime is a hang, not a slow run
            stdout = self._run([str(binary), str(wav), "--models", str(MODELS_DIR)], timeout)
        return parse_turns(stdout)

    def voice_check(self, audio: np.ndarray, exclude: list[Interval] | None = None) -> VoiceCheck:
        return self.fallback().voice_check(audio, exclude)  # thresholds are tuned on the pyannote embedder

    def release(self) -> None:
        self._binary = None
        if self._fallback is not None:
            self._fallback.release()
            self._fallback = None

    def trim(self) -> None:
        if self._fallback is not None:
            self._fallback.trim()


def parse_turns(stdout: str) -> RawTurns:
    """The CLI's last JSON line -> raw turns (start, end, speaker id), sorted by start, empty turns dropped."""
    lines = [line for line in stdout.splitlines() if line.strip()]
    if not lines:
        raise RuntimeError("no output")
    segments = json.loads(lines[-1])["segments"]
    turns = [(float(s["start"]), float(s["end"]), str(s["speaker"])) for s in segments]
    return sorted((t for t in turns if t[1] > t[0]), key=lambda t: (t[0], t[1]))


def _short_error(exc: Exception) -> str:
    return " ".join(f"{type(exc).__name__}: {exc}".split())[:240]
