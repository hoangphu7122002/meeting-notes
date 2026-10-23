"""Speaker diarization with FluidAudio (default, `diarization_engine = "fluidaudio"`).

FluidAudio's offline pipeline is a Core ML port of pyannote community-1 (segmentation + WeSpeaker embedding + PLDA
+ VBx) that runs on the Neural Engine. It is a Swift SDK, so a small helper CLI (`app/Sources/MeetingNotesDiarize`,
bundled in MeetingNotes.app by scripts/build-app.sh) diarizes one WAV per call and prints JSON; this adapter writes
the track to a temporary WAV and shells out to it. No torch for the full pass, no Hugging Face token: the CLI
downloads the ungated, commit-pinned weights on first use into `<repo>/models/fluidaudio/` (progress on stderr).
The mic single-voice check and every failure path (binary missing, download or inference error) use the pyannote
Diarizer (gated pipeline if HF_TOKEN has access, else ungated clustering), so this engine never makes a job fail.
Licenses: docs/research/diarization-alternatives.md section 8.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import threading
from collections import deque
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
BUILD_HINT = f"install the app with scripts/build-app.sh, or `swift build -c release --product {BINARY}` in app/"
APP_ENV = "MEETING_NOTES_DIARIZE_CLI"  # set by the app for its worker: the helper bundled next to its executable
APP_BUNDLES = ("~/Applications/MeetingNotes.app", "/Applications/MeetingNotes.app")
TOKEN_ENV = ("HF_TOKEN", "HUGGING_FACE_HUB_TOKEN", "HUGGINGFACEHUB_API_TOKEN")  # weights are ungated: never pass one
PREPARE_TIMEOUT = 900.0

Runner = Callable[..., str]  # (argv, timeout seconds, on_line=None) -> stdout; raises on failure


def candidates(env: dict[str, str] | None = None) -> list[Path]:
    """Auto-discovery order: the app's bundled helper (env from the app, then installed bundles), then the repo's
    release and debug builds."""
    env = os.environ if env is None else env
    found = [Path(env[APP_ENV]).expanduser()] if env.get(APP_ENV, "").strip() else []
    found += [Path(app).expanduser() / "Contents" / "MacOS" / BINARY for app in APP_BUNDLES]
    found += [REPO_ROOT / "app" / ".build" / kind / BINARY for kind in ("release", "debug")]
    return found


def find_binary(cfg: Config, env: dict[str, str] | None = None) -> Path:
    """`fluidaudio_cli` if set (explicit override), else the first existing candidate, else PATH."""
    if str(cfg.fluidaudio_cli).strip():
        path = Path(cfg.fluidaudio_cli).expanduser()
        if path.is_file():
            return path
        raise RuntimeError(f"fluidaudio_cli not found: {path}")
    for path in candidates(env):
        if path.is_file() and os.access(path, os.X_OK):
            return path
    found = shutil.which(BINARY)
    if found:
        return Path(found)
    raise RuntimeError(f"{BINARY} not found ({BUILD_HINT})")


def models_cached(models_dir: Path | None = None) -> bool:
    return any((models_dir or MODELS_DIR).glob("**/*.mlmodelc"))


def status(cfg: Config) -> str:
    """One line for `doctor`: where the helper is and whether its models are cached."""
    try:
        where = f"helper {find_binary(cfg)}"
    except Exception as exc:
        where = f"helper missing: {_short_error(exc)}; falls back to pyannote"
    models = "models cached" if models_cached() else "models download on first use (~21 MB, no login)"
    return f"{where}; {models}"


def run_cli(argv: list[str], timeout: float, on_line: Callable[[str], None] | None = None) -> str:
    """Run the helper; stderr lines go to `on_line` as they arrive (download progress), stdout is returned."""
    env = {k: v for k, v in os.environ.items() if k not in TOKEN_ENV}
    tail: deque[str] = deque(maxlen=8)
    with tempfile.TemporaryFile("w+") as out:  # a file, so large JSON can never block on a full pipe
        proc = subprocess.Popen(argv, stdout=out, stderr=subprocess.PIPE, text=True, env=env)

        def pump() -> None:
            for line in proc.stderr:
                line = line.rstrip()
                tail.append(line)
                if on_line:
                    on_line(line)

        reader = threading.Thread(target=pump, daemon=True)
        reader.start()
        try:
            code = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
            raise
        finally:
            reader.join(timeout=5)
        out.seek(0)
        stdout = out.read()
    if code:
        text = " ".join(" ".join(line for line in tail if not line.startswith("progress ")).split())[-200:]
        raise RuntimeError(f"{Path(argv[0]).name} exited {code}: {text}")
    return stdout


class ProgressLog:
    """Turns the helper's `progress <fraction> <phase>` stderr lines into a few log lines: real downloads every
    25 %, then one line for the Core ML compile. A cached run (nothing to download) logs nothing."""

    def __init__(self, log: Callable[[str], None]):
        self.log, self.step, self.downloaded, self.compiling = log, -1, False, False

    def __call__(self, line: str) -> None:
        parts = line.split()
        if len(parts) < 3 or parts[0] != "progress":
            return
        try:
            fraction = float(parts[1])
        except ValueError:
            return
        if parts[2] == "downloading" and len(parts) > 3 and not parts[3].startswith("0/"):
            step = int(fraction * 4)
            if step > self.step:
                self.step, self.downloaded = step, True
                self.log(f"diarization: downloading FluidAudio models (~21 MB, files {parts[3]}, {fraction * 100:.0f}%)")
        elif parts[2] == "compiling" and self.downloaded and not self.compiling:
            self.compiling = True
            self.log("diarization: compiling FluidAudio models for this Mac (first use, ~30 s)")


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

    def prepare(self) -> Path:
        """Find the helper and make sure its models are downloaded and compiled; raises on failure."""
        binary = find_binary(self.cfg)
        self._run([str(binary), "--prepare", "--models", str(MODELS_DIR)], PREPARE_TIMEOUT, ProgressLog(self.log))
        return binary

    def engine(self) -> Path | None:
        """The helper binary with its models prepared (download + Core ML compile on first use), or None."""
        if self._binary is None and self._error is None:
            try:
                self._binary = self.prepare()
            except Exception as exc:
                self._error = _short_error(exc)
                self.log(f"diarization: fluidaudio unavailable ({self._error})")
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
        self._binary = self._error = None  # the next job looks for the helper again (it may be installed by then)
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
