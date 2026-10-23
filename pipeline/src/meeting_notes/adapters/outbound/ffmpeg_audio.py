"""ffmpeg: decode any audio/video file to a float array, encode aligned/mixed m4a listening copies."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import numpy as np

from ...domain.signal import SR


def ffmpeg_bin() -> str:
    for candidate in (shutil.which("ffmpeg"), "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"):
        if candidate and Path(candidate).exists():
            return candidate
    raise RuntimeError("ffmpeg not found (brew install ffmpeg)")


def decode(path: Path, sr: int = SR) -> np.ndarray:
    """Decode any audio file to mono float32 at `sr`."""
    cmd = [ffmpeg_bin(), "-nostdin", "-v", "error", "-i", str(path), "-vn", "-ac", "1", "-ar", str(sr), "-f", "f32le", "-"]
    out = subprocess.run(cmd, capture_output=True, check=False)
    if out.returncode != 0:
        raise RuntimeError(f"ffmpeg could not decode {path.name}: {out.stderr.decode(errors='replace')[-400:]}")
    return np.frombuffer(out.stdout, dtype=np.float32).copy()


def encode_m4a(inputs: list[tuple[Path, float]], dest: Path, bitrate: str = "64k") -> None:
    """Encode one or more (path, start_offset_sec) inputs into a mono AAC file, mixing if several."""
    cmd = [ffmpeg_bin(), "-nostdin", "-v", "error", "-y"]
    for path, _ in inputs:
        cmd += ["-i", str(path)]
    chains, labels = [], []
    for i, (_, offset) in enumerate(inputs):
        delay_ms = int(round(max(0.0, offset) * 1000))
        chains.append(f"[{i}:a]aresample=48000,aformat=channel_layouts=mono,adelay={delay_ms}:all=1[a{i}]")
        labels.append(f"[a{i}]")
    if len(inputs) > 1:
        graph = ";".join(chains) + f";{''.join(labels)}amix=inputs={len(inputs)}:duration=longest:normalize=0,alimiter=limit=0.97[out]"
    else:
        graph = chains[0].replace("[a0]", "[out]")
    cmd += ["-filter_complex", graph, "-map", "[out]", "-c:a", "aac", "-b:a", bitrate, "-movflags", "+faststart", str(dest)]
    tmp = dest.with_suffix(".tmp.m4a")
    cmd[-1] = str(tmp)
    out = subprocess.run(cmd, capture_output=True, check=False)
    if out.returncode != 0:
        tmp.unlink(missing_ok=True)
        raise RuntimeError(f"ffmpeg encode failed for {dest.name}: {out.stderr.decode(errors='replace')[-400:]}")
    tmp.replace(dest)


def find_ffmpeg() -> str:
    """Path of ffmpeg for `doctor`: PATH, then Homebrew, else the afconvert fallback note (never raises)."""
    try:
        return ffmpeg_bin()
    except RuntimeError:
        return "not installed: using macOS afconvert (webm/mkv imports need ffmpeg)"
