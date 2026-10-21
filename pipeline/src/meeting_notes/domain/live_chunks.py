"""Live transcription, design A: cut each growing track into chunks at natural pauses (pure).

A `TrackChunker` is fed the new 16 kHz samples of one track after every poll and returns the chunks that
are complete. It keeps the frame loudness of the whole track (for the running speech threshold) and only
the last `history_sec` of samples plus the open chunk, so memory stays flat over a long meeting.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from .intervals import dilate, overlap, runs
from .signal import FRAME_SEC, SR, bleed_ratio, energy_vad, frame_db, threshold_from_db, voiced_seconds, voicing

FRAME = int(SR * FRAME_SEC)
BLEED_CORR = 0.35  # same threshold as the offline two-track resolution (application/diarize_tracks.py)
BLEED_SHARE = 0.8  # share of the mic chunk's voiced time inside remote speech above which it is echo


@dataclass(frozen=True)
class ChunkPolicy:
    min_sec: float = 4.0
    max_sec: float = 28.0
    pause_sec: float = 0.7
    pad_sec: float = 0.25  # decode pad around a chunk (transcribe_blocks.PAD_SEC)
    warmup_sec: float = 8.0  # no cut before the track has this much audio: the threshold needs a history
    min_voiced_sec: float = 1.0  # chunks with less voiced speech are not decoded live (left to the Stop pass)
    history_sec: float = 90.0  # recent samples kept per track (mic bleed check against the system track)
    refresh_sec: float = 30.0  # threshold refresh: every feed until this much audio, then this often


@dataclass
class LiveChunk:
    track: str
    seq: int
    start: float  # recorded seconds
    end: float
    forced: bool  # cut at max_sec without a pause
    audio: np.ndarray = field(repr=False, compare=False, default_factory=lambda: np.zeros(0, np.float32))
    audio_start: float = 0.0  # recorded time of audio[0] (start - pad, clipped)
    threshold_db: float = 0.0  # running speech threshold when the chunk was cut

    @property
    def duration(self) -> float:
        return self.end - self.start


def next_cut(db: np.ndarray, threshold_db: float, start_f: int, avail_f: int, policy: ChunkPolicy) -> tuple[int, bool] | None:
    """(cut frame, forced) for the chunk starting at `start_f`, using frames < `avail_f` only, else None.

    Cut in the first pause >= pause_sec once the chunk is >= min_sec (midway into the pause, not before
    min_sec). At max_sec without a pause: cut at the quietest 0.3 s window of the last 40 %."""
    def per(sec: float) -> int:
        return int(round(sec / FRAME_SEC))

    min_f, max_f, pause_f = per(policy.min_sec), per(policy.max_sec), per(policy.pause_sec)
    window = db[start_f:avail_f][:max_f]
    for a, b in runs(window <= threshold_db, 1.0):
        a, b = int(a), int(b)
        cut = max(a + pause_f // 2, min_f)
        if b - a >= pause_f and b - cut >= pause_f // 2:
            return start_f + cut, False
    if len(window) >= max_f:
        lo = int(max_f * 0.6)
        smooth = np.convolve(db[start_f + lo:start_f + max_f], np.ones(15) / 15, mode="valid")
        return start_f + lo + int(np.argmin(smooth)) + 7, True
    return None


class TrackChunker:
    """Chunk state of one track. Samples arrive contiguous; `start_at` resumes after already-decoded chunks."""

    def __init__(self, track: str, policy: ChunkPolicy = ChunkPolicy(), start_at: float = 0.0, seq: int = 0):
        self.track, self.policy, self.start_at, self.seq = track, policy, start_at, seq
        self.origin: float | None = None  # recorded time of the first sample
        self.total = 0  # samples received
        self.buf = np.zeros(0, np.float32)
        self.buf_from = 0  # sample index of buf[0]
        self.db = np.zeros(0, np.float32)
        self.start_f = 0
        self.threshold = 0.0
        self._refreshed_f = -1

    @property
    def available_end(self) -> float:
        return (self.origin or 0.0) + self.total / SR

    @property
    def open_start(self) -> float:
        """Recorded start of the chunk not yet cut."""
        return (self.origin or 0.0) + self.start_f * FRAME_SEC

    def feed(self, start_sec: float, samples: np.ndarray) -> list[LiveChunk]:
        if samples.size == 0:
            return []
        if self.origin is None:
            self.origin = start_sec
            self.start_f = max(0, int(round((self.start_at - start_sec) / FRAME_SEC)))
        self.buf = np.concatenate([self.buf, samples.astype(np.float32, copy=False)])
        self.total += samples.size
        done = len(self.db) * FRAME
        frames = frame_db(self.buf[done - self.buf_from:])
        self.db = np.concatenate([self.db, frames])
        f = len(self.db)
        if f * FRAME_SEC <= self.policy.refresh_sec or f - self._refreshed_f >= self.policy.refresh_sec / FRAME_SEC:
            self.threshold, self._refreshed_f = threshold_from_db(self.db), f
        out = []
        if self.total / SR >= self.policy.warmup_sec:
            while (cut := next_cut(self.db, self.threshold, self.start_f, f, self.policy)) is not None:
                out.append(self._chunk(self.start_f, *cut))
                self.start_f = cut[0]
        self._trim()
        return out

    def recent(self, start: float, end: float) -> np.ndarray | None:
        """Samples of [start, end] if still buffered (and complete), else None."""
        if self.origin is None:
            return None
        a, z = int(round((start - self.origin) * SR)), int(round((end - self.origin) * SR))
        if a < self.buf_from or z > self.total or z <= a:
            return None
        return self.buf[a - self.buf_from:z - self.buf_from]

    def _chunk(self, start_f: int, end_f: int, forced: bool) -> LiveChunk:
        pad = int(self.policy.pad_sec * SR)
        s0 = max(self.buf_from, start_f * FRAME - pad)
        s1 = min(self.total, end_f * FRAME + pad)
        origin = self.origin or 0.0
        chunk = LiveChunk(self.track, self.seq, origin + start_f * FRAME_SEC, origin + end_f * FRAME_SEC, forced,
                          self.buf[s0 - self.buf_from:s1 - self.buf_from].copy(), origin + s0 / SR, self.threshold)
        self.seq += 1
        return chunk

    def _trim(self) -> None:
        keep = min(self.start_f * FRAME - int(self.policy.pad_sec * SR), self.total - int(self.policy.history_sec * SR),
                   len(self.db) * FRAME)
        keep = max(keep, self.buf_from)
        if keep > self.buf_from:
            self.buf = self.buf[keep - self.buf_from:]
            self.buf_from = keep


def worth_decoding(chunk: LiveChunk, policy: ChunkPolicy) -> bool:
    """Gate before a whisper call: enough voiced (pitched, loud) speech in the chunk itself."""
    a = int(round((chunk.start - chunk.audio_start) * SR))
    z = a + int(round(chunk.duration * SR))
    return voiced_seconds(chunk.audio[max(0, a):z], chunk.threshold_db) >= policy.min_voiced_sec


def mic_is_bleed(mic: np.ndarray, system: np.ndarray, mic_threshold_db: float) -> bool:
    """A mic chunk that mostly repeats the system track (speakers, no headphones): skip it live.

    `mic` and `system` cover the same recorded span. Bleed = loudness correlation during remote speech above
    the offline threshold and >= BLEED_SHARE of the mic's voiced time inside (dilated) remote speech."""
    n = min(mic.size, system.size)
    if n < SR:
        return False
    mic, system = mic[:n], system[:n]
    remote = energy_vad(system)
    if not remote or bleed_ratio(mic, system, remote) <= BLEED_CORR:
        return False
    db = frame_db(mic)
    voiced = (db > mic_threshold_db) & (voicing(mic)[: db.size] > 0.45)
    spans = runs(voiced, FRAME_SEC)
    total = sum(e - s for s, e in spans)
    if total <= 0:
        return False
    guard = dilate(remote, 0.05, 0.35)
    inside = sum(overlap(s, g) for s in spans for g in guard)
    return inside / total >= BLEED_SHARE
