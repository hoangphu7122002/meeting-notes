"""Audio I/O (ffmpeg) and a simple energy-based voice activity detector."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import numpy as np
import soundfile as sf

SR = 16000  # processing sample rate
FRAME_SEC = 0.02

Interval = tuple[float, float]


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


def write_wav(path: Path, audio: np.ndarray, sr: int = SR) -> None:
    sf.write(str(path), audio, sr, subtype="PCM_16")


def read_wav(path: Path) -> np.ndarray:
    audio, _ = sf.read(str(path), dtype="float32")
    return audio


def place(audio: np.ndarray, offset_sec: float, length: int, sr: int = SR) -> np.ndarray:
    """Shift a track by its start offset and pad/trim to `length` samples."""
    out = np.zeros(length, dtype=np.float32)
    start = int(round(max(0.0, offset_sec) * sr))
    if start < length:
        n = min(len(audio), length - start)
        out[start:start + n] = audio[:n]
    return out


def mix(tracks: list[np.ndarray]) -> np.ndarray:
    mixed = np.sum(tracks, axis=0, dtype=np.float32)
    peak = float(np.max(np.abs(mixed))) if mixed.size else 0.0
    if peak > 0.99:
        mixed *= 0.99 / peak
    return mixed


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


# ---------------------------------------------------------------- VAD

def frame_db(audio: np.ndarray, sr: int = SR, frame_sec: float = FRAME_SEC) -> np.ndarray:
    n = int(sr * frame_sec)
    frames = len(audio) // n
    if frames == 0:
        return np.zeros(0, dtype=np.float32)
    x = audio[: frames * n].reshape(frames, n).astype(np.float64)
    rms = np.sqrt(np.mean(x * x, axis=1))
    return (20 * np.log10(np.maximum(rms, 1e-9))).astype(np.float32)


def runs(mask: np.ndarray, frame_sec: float) -> list[Interval]:
    """Contiguous True runs of a boolean frame mask as (start, end) seconds."""
    if mask.size == 0:
        return []
    padded = np.concatenate([[False], mask, [False]])
    diff = np.diff(padded.astype(np.int8))
    starts = np.flatnonzero(diff == 1)
    ends = np.flatnonzero(diff == -1)
    return [(s * frame_sec, e * frame_sec) for s, e in zip(starts, ends)]


def energy_vad(
    audio: np.ndarray,
    sr: int = SR,
    margin_db: float = 12.0,
    min_db: float = -50.0,
    min_gap: float = 0.35,
    min_len: float = 0.2,
    pad: float = 0.1,
) -> list[Interval]:
    """Speech-ish regions: frames louder than an adaptive noise floor, smoothed."""
    db = frame_db(audio, sr)
    if db.size == 0:
        return []
    audible = db[db > -90]
    if audible.size == 0:
        return []
    floor = float(np.percentile(audible, 20))
    loud = float(np.percentile(audible, 95))
    threshold = max(floor + margin_db, min_db)
    threshold = min(threshold, loud - 12.0) if loud - 12.0 > min_db else threshold
    regions = runs(db > threshold, FRAME_SEC)
    regions = merge_gaps(regions, min_gap)
    regions = [(s, e) for s, e in regions if e - s >= min_len]
    duration = len(audio) / sr
    return merge_gaps([(max(0.0, s - pad), min(duration, e + pad)) for s, e in regions], 0.0)


# ---------------------------------------------------------------- interval helpers

def merge_gaps(intervals: list[Interval], max_gap: float) -> list[Interval]:
    out: list[list[float]] = []
    for s, e in sorted(intervals):
        if out and s - out[-1][1] <= max_gap:
            out[-1][1] = max(out[-1][1], e)
        else:
            out.append([s, e])
    return [(s, e) for s, e in out]


def subtract(intervals: list[Interval], remove: list[Interval]) -> list[Interval]:
    """Set difference of two interval lists."""
    remove = merge_gaps(remove, 0.0)
    out: list[Interval] = []
    for s, e in sorted(intervals):
        cur = s
        for rs, re_ in remove:
            if re_ <= cur or rs >= e:
                continue
            if rs > cur:
                out.append((cur, rs))
            cur = max(cur, re_)
            if cur >= e:
                break
        if cur < e:
            out.append((cur, e))
    return out


def total(intervals: list[Interval]) -> float:
    return sum(e - s for s, e in intervals)


def overlap(a: Interval, b: Interval) -> float:
    return max(0.0, min(a[1], b[1]) - max(a[0], b[0]))


def dilate(intervals: list[Interval], before: float, after: float) -> list[Interval]:
    return merge_gaps([(max(0.0, s - before), e + after) for s, e in intervals], 0.0)


def bleed_ratio(mic: np.ndarray, system: np.ndarray, system_speech: list[Interval], sr: int = SR) -> float:
    """Correlation of mic and system loudness during system speech.

    High values mean the mic hears the speakers (no headphones), so mic activity during
    remote speech is likely echo rather than the user talking.
    """
    a, b = frame_db(mic, sr), frame_db(system, sr)
    n = min(a.size, b.size)
    if n == 0 or not system_speech:
        return 0.0
    mask = np.zeros(n, dtype=bool)
    for s, e in system_speech:
        mask[int(s / FRAME_SEC): int(e / FRAME_SEC)] = True
    if mask.sum() < 50:
        return 0.0
    x, y = a[:n][mask], b[:n][mask]
    if np.std(x) < 1e-3 or np.std(y) < 1e-3:
        return 0.0
    return float(np.corrcoef(x, y)[0, 1])
