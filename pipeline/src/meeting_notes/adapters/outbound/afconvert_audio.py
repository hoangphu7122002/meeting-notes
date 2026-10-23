"""macOS `afconvert` (Core Audio, part of every macOS): decode and m4a encode when ffmpeg is not installed, e.g.
in the packaged app on a Mac without Homebrew. Covers the app's own recordings and common imports (wav, m4a, mp3,
aac, aiff, caf, mp4 audio); webm/mkv/ogg imports still need ffmpeg. Mixing streams in blocks through temporary
WAV files, so a long meeting never sits in memory at 48 kHz."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

import numpy as np

from ...domain.signal import SR

AFCONVERT = "/usr/bin/afconvert"
RATE = 48000
BLOCK = RATE * 30


def available() -> bool:
    return Path(AFCONVERT).exists()


def _run(args: list[str], what: str) -> None:
    out = subprocess.run([AFCONVERT, *args], capture_output=True, check=False)
    if out.returncode != 0:
        raise RuntimeError(f"afconvert could not {what}: {(out.stderr or out.stdout).decode(errors='replace')[-400:]}")


def decode(path: Path, sr: int = SR) -> np.ndarray:
    """Decode an audio file to mono float32 at `sr`."""
    import soundfile as sf

    with tempfile.TemporaryDirectory(prefix="mn-afconvert-") as tmp:
        wav = Path(tmp) / "decoded.wav"
        _run(["-f", "WAVE", "-d", f"LEF32@{sr}", "--mix", str(path), str(wav)], f"decode {path.name}")
        audio, _ = sf.read(wav, dtype="float32", always_2d=False)
    return np.asarray(audio, dtype=np.float32).reshape(-1)


def encode_m4a(inputs: list[tuple[Path, float]], dest: Path, bitrate: str = "64k") -> None:
    """Encode (path, start_offset_sec) inputs into one mono AAC file, mixing (with a hard limit) if several."""
    import soundfile as sf

    bps = int(float(bitrate.rstrip("kK")) * 1000) if bitrate[-1:] in "kK" else int(bitrate)
    with tempfile.TemporaryDirectory(prefix="mn-afconvert-") as tmp:
        tracks = []
        try:
            for i, (path, offset) in enumerate(inputs):
                wav = Path(tmp) / f"in{i}.wav"
                _run(["-f", "WAVE", "-d", f"LEF32@{RATE}", "--mix", str(path), str(wav)], f"decode {path.name}")
                tracks.append((sf.SoundFile(wav), int(round(max(0.0, offset) * RATE))))
            mixed = Path(tmp) / "mix.wav"
            total = max(delay + f.frames for f, delay in tracks)
            with sf.SoundFile(mixed, "w", RATE, 1, subtype="PCM_16") as out:
                for start in range(0, total, BLOCK):
                    out.write(_mix_block(tracks, start, min(BLOCK, total - start)))
        finally:
            for f, _ in tracks:
                f.close()
        partial = dest.with_suffix(".tmp.m4a")
        try:
            _run(["-f", "m4af", "-d", "aac", "-b", str(bps), str(mixed), str(partial)], f"encode {dest.name}")
        except Exception:
            partial.unlink(missing_ok=True)
            raise
        partial.replace(dest)


def _mix_block(tracks, start: int, n: int) -> np.ndarray:
    block = np.zeros(n, dtype=np.float32)
    for f, delay in tracks:
        lo, hi = max(start, delay), min(start + n, delay + f.frames)
        if hi > lo:
            f.seek(lo - delay)
            block[lo - start:hi - start] += np.asarray(f.read(hi - lo, dtype="float32", always_2d=False)).reshape(-1)
    return np.clip(block, -0.97, 0.97) if len(tracks) > 1 else block
