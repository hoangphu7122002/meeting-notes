"""Audio signal helpers on mono float32 arrays: placing/mixing tracks, loudness, voice activity, bleed."""

from __future__ import annotations

import numpy as np

from .intervals import Interval, merge_gaps, runs

SR = 16000  # processing sample rate
FRAME_SEC = 0.02


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


def frame_db(audio: np.ndarray, sr: int = SR, frame_sec: float = FRAME_SEC) -> np.ndarray:
    n = int(sr * frame_sec)
    frames = len(audio) // n
    if frames == 0:
        return np.zeros(0, dtype=np.float32)
    x = audio[: frames * n].reshape(frames, n).astype(np.float64)
    rms = np.sqrt(np.mean(x * x, axis=1))
    return (20 * np.log10(np.maximum(rms, 1e-9))).astype(np.float32)


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


def speech_threshold_db(track: np.ndarray) -> float:
    """Energy threshold for speech on one track: 10 dB above its noise floor, below its loud speech."""
    db = frame_db(track)
    audible = db[db > -90]
    if audible.size == 0:
        return 0.0
    floor = float(np.percentile(audible, 20))
    loud = float(np.percentile(audible, 97))
    threshold = max(floor + 10.0, -55.0)
    return min(threshold, loud - 15.0) if loud - 15.0 > floor + 3.0 else threshold


def voicing(chunk: np.ndarray, frame_sec: float = FRAME_SEC, batch: int = 4096) -> np.ndarray:
    """Per-frame periodicity in the pitch range (70-500 Hz): peak of the normalized autocorrelation over a
    40 ms window. Speech scores ~0.5-0.95; keyboard clicks, room tone and hiss stay low."""
    hop = int(SR * frame_sec)
    win = 2 * hop
    frames = len(chunk) // hop
    out = np.zeros(frames, dtype=np.float32)
    if frames == 0:
        return out
    padded = np.concatenate([chunk.astype(np.float32), np.zeros(win, np.float32)])
    lo, hi = SR // 500, SR // 70
    window = np.hanning(win).astype(np.float32)
    for b0 in range(0, frames, batch):
        idx = np.arange(b0, min(frames, b0 + batch))[:, None] * hop + np.arange(win)[None, :]
        x = padded[idx] * window
        x -= x.mean(axis=1, keepdims=True)
        spec = np.fft.rfft(x, n=2 * win, axis=1)
        ac = np.fft.irfft(np.abs(spec) ** 2, axis=1)[:, : hi + 1]
        energy = np.maximum(ac[:, 0], 1e-12)
        out[b0:b0 + len(idx)] = (ac[:, lo:hi + 1].max(axis=1) / energy).astype(np.float32)
    return out


def speech_spans(chunk: np.ndarray, threshold_db: float, split_gap: float, pad: float = 0.3,
                 min_speech: float = 0.25, min_voiced: float = 0.15) -> list[tuple[int, int]]:
    """Sample ranges of `chunk` worth transcribing: loud regions that contain voiced (pitched) frames,
    joined across pauses < `split_gap`, padded. Empty when less than `min_speech` seconds qualify."""
    db = frame_db(chunk)
    if db.size == 0:
        return []
    loud = db > threshold_db
    voiced = loud & (voicing(chunk)[: db.size] > 0.45)
    regions = []
    for s, e in merge_gaps(runs(loud, FRAME_SEC), 0.3):
        a, z = int(round(s / FRAME_SEC)), int(round(e / FRAME_SEC))
        if e - s >= 0.1 and voiced[a:z].sum() * FRAME_SEC >= max(0.06, min_voiced * (e - s)):
            regions.append((s, e))
    if sum(e - s for s, e in regions) < min_speech:
        return []
    dur = len(chunk) / SR
    spans = merge_gaps([(max(0.0, s - pad), min(dur, e + pad)) for s, e in merge_gaps(regions, split_gap)], 0.0)
    return [(int(s * SR), int(e * SR)) for s, e in spans]
