"""Chunk policy of design A (docs/research/realtime.md 4.1) replayed over a finished track as a growing stream.

Decisions only look at audio that had arrived at the decision time (1 s polls), so the replay is equivalent to
tailing a WAV during a meeting. Prototype of `domain/live_chunks.py`; the product code does not exist yet.
"""

from __future__ import annotations

import time
from dataclasses import asdict, dataclass

import numpy as np

from meeting_notes.domain.intervals import runs
from meeting_notes.domain.segments import Segment
from meeting_notes.domain.signal import FRAME_SEC, SR, frame_db, speech_threshold_db
from meeting_notes.domain.speakers import Block


@dataclass(frozen=True)
class ChunkPolicy:
    min_sec: float = 4.0
    max_sec: float = 28.0
    pause_sec: float = 0.7
    pad_sec: float = 0.25  # whisper decode pad: transcribe_blocks PAD_SEC, same value
    poll_sec: float = 1.0
    warmup_sec: float = 8.0  # no cuts before the running speech threshold has this much audio behind it


@dataclass
class LiveChunk:
    track: str
    seq: int
    start: float
    end: float
    ready: float  # stream time at which the cut was decided
    forced: bool
    tail: bool = False  # left over at Stop: not decoded live


def next_cut(db: np.ndarray, threshold_db: float, start_f: int, avail_f: int, policy: ChunkPolicy) -> tuple[int, bool] | None:
    """(cut frame, forced) for the chunk starting at `start_f`, using frames < `avail_f` only, else None.

    Cut in the first pause >= pause_sec once the chunk is >= min_sec (midway into the pause, but not before
    min_sec). At max_sec without a pause: cut at the quietest 0.3 s window of the last 40 %."""
    per = lambda sec: int(round(sec / FRAME_SEC))  # noqa: E731
    min_f, max_f, pause_f = per(policy.min_sec), per(policy.max_sec), per(policy.pause_sec)
    window = db[start_f:avail_f]
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


def cut_track(audio: np.ndarray, track: str, policy: ChunkPolicy = ChunkPolicy()) -> list[LiveChunk]:
    """Replay `audio` as a stream: poll every `poll_sec`, cut chunks per policy; the remainder is a tail chunk."""
    db = frame_db(audio)
    total = len(audio) / SR
    chunks: list[LiveChunk] = []
    start_f, threshold = 0, 0.0
    t = max(policy.poll_sec, policy.warmup_sec)
    while t <= total + 1e-9:
        if t <= 30.0 or int(t) % 30 == 0:  # refresh every poll up to 30 s, then every 30 s
            threshold = speech_threshold_db(audio[: int(t * SR)])  # running estimate from audio seen so far
        avail_f = int(t / FRAME_SEC)
        cut = next_cut(db, threshold, start_f, avail_f, policy)
        if cut:
            chunks.append(LiveChunk(track, len(chunks), start_f * FRAME_SEC, cut[0] * FRAME_SEC, t, cut[1]))
            start_f = cut[0]
            continue  # re-check the same poll: the next chunk may already be complete
        t += policy.poll_sec
    if total - start_f * FRAME_SEC >= 0.4:
        chunks.append(LiveChunk(track, len(chunks), start_f * FRAME_SEC, total, total, False, tail=True))
    return chunks


def decode_chunk(chunk: LiveChunk, audio: np.ndarray, tr, cfg) -> dict:
    """Decode one chunk exactly like one `transcribe_blocks` block (VAD, vi/en choice, glossary prompt, filters).

    Only audio up to `chunk.ready` (plus the pad) is passed, so VAD thresholds are the running ones."""
    from meeting_notes.application.transcribe_blocks import transcribe_blocks

    seen = audio[: int(max(chunk.ready, chunk.end + ChunkPolicy.pad_sec) * SR)]
    block = Block(chunk.start, chunk.end, chunk.track, chunk.track, [(chunk.start, chunk.end)])
    calls0, model0, t0 = tr.calls, tr.model_sec, time.monotonic()
    segs: list[Segment] = transcribe_blocks([block], {chunk.track: seen}, tr, cfg.languages, vad=cfg.whisper_vad,
                                            split_gap=cfg.vad_split_gap)
    return {**asdict(chunk), "segments": [asdict(s) for s in segs], "wall_sec": time.monotonic() - t0,
            "model_sec": tr.model_sec - model0, "speech": tr.calls > calls0}


def replay_track(audio: np.ndarray, track: str, tr, cfg, policy: ChunkPolicy = ChunkPolicy()) -> list[dict]:
    return [decode_chunk(c, audio, tr, cfg) for c in cut_track(audio, track, policy)]
