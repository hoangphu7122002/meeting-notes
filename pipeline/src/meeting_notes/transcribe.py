"""On-device transcription with mlx-whisper, one call per speaker block with per-block language detection."""

from __future__ import annotations

import re
import unicodedata
from collections import defaultdict
from collections.abc import Callable
from dataclasses import dataclass

import numpy as np

from .audio import SR, frame_db
from .config import Config
from .speakers import Block

PAD_SEC = 0.25
MIN_BLOCK_SEC = 0.4
SHORT_BLOCK_SEC = 2.5

# Phrases Whisper is known to hallucinate on silence/noise (YouTube outro boilerplate).
HALLUCINATIONS = [
    "hẹn gặp lại các bạn trong những video tiếp theo",
    "cảm ơn các bạn đã theo dõi",
    "hãy subscribe cho kênh",
    "đăng ký kênh",
    "ghiền mì gõ",
    "la la school",
    "thanks for watching",
    "thank you for watching",
    "please subscribe",
    "subtitles by",
    "amara.org",
]


@dataclass
class Segment:
    start: float
    end: float
    speaker: str
    track: str
    language: str
    text: str

    def to_dict(self) -> dict:
        return {
            "start": round(self.start, 2), "end": round(self.end, 2), "speaker": self.speaker,
            "track": self.track, "language": self.language, "text": self.text,
        }


def normalize(text: str) -> str:
    text = unicodedata.normalize("NFC", text.lower())
    return re.sub(r"[^\w\s]", "", text).strip()


def is_hallucination(text: str, block_sec: float) -> bool:
    norm = normalize(text)
    if not norm:
        return True
    for phrase in HALLUCINATIONS:
        if phrase in norm and (len(norm) <= len(phrase) + 20 or block_sec < 8):
            return True
    return False


def keep_segment(seg: dict) -> bool:
    if seg.get("compression_ratio", 0) > 2.6:
        return False
    if seg.get("no_speech_prob", 0) > 0.6 and seg.get("avg_logprob", 0) < -0.7:
        return False
    return True


def split_long_blocks(blocks: list[Block], audio_by_track: dict[str, np.ndarray], max_len: float = 45.0) -> list[Block]:
    """Split blocks longer than `max_len` at the quietest 0.3 s inside the last third of each piece."""
    out: list[Block] = []
    for b in blocks:
        start = b.start
        while b.end - start > max_len:
            lo, hi = start + max_len * 0.6, start + max_len
            db = frame_db(audio_by_track[b.track][int(lo * SR): int(hi * SR)])
            if db.size >= 15:
                smooth = np.convolve(db, np.ones(15) / 15, mode="valid")
                cut = lo + (int(np.argmin(smooth)) + 7) * 0.02
            else:
                cut = hi
            out.append(Block(start, cut, b.speaker, b.track, clip_parts(b.parts, start, cut)))
            start = cut
        out.append(Block(start, b.end, b.speaker, b.track, clip_parts(b.parts, start, b.end)))
    return out


def clip_parts(parts: list[tuple[float, float]], start: float, end: float) -> list[tuple[float, float]]:
    return [(max(s, start), min(e, end)) for s, e in parts if min(e, end) > max(s, start)]


def split_by_language(blocks: list[Block], detect: Callable[[Block, float, float], str], min_part: float = 1.5) -> list[Block]:
    """Split multi-turn blocks where the speaker switches language between turns.

    Whisper fixes one language per call (detected on the first 30 s), so a block that starts in
    Vietnamese and continues in English would otherwise be forced into Vietnamese.
    """
    out: list[Block] = []
    for b in blocks:
        parts = [p for p in b.parts if p[1] - p[0] >= min_part]
        if len(parts) < 2:
            out.append(b)
            continue
        langs = [detect(b, s, e) for s, e in parts]
        if len(set(langs)) == 1:
            out.append(b)
            continue
        # Cut points: start of each detected part whose language differs from the previous one.
        cuts = [parts[i][0] for i in range(1, len(parts)) if langs[i] != langs[i - 1]]
        bounds = [b.start, *cuts, b.end]
        for s, e in zip(bounds, bounds[1:]):
            out.append(Block(s, e, b.speaker, b.track, clip_parts(b.parts, s, e)))
    return out


def choose_language(probs: dict[str, float], allowed: list[str], prior: dict[str, float] | None, short: bool) -> str:
    """Pick the block language, restricted to `allowed`, leaning on the speaker's history for short blocks."""
    candidates = {k: v for k, v in probs.items() if not allowed or k in allowed} or probs
    best = max(candidates, key=candidates.get)
    if short and prior:
        favourite = max(prior, key=prior.get)
        if favourite in candidates and candidates[best] < 0.8:
            return favourite
    return best


class Transcriber:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        self._model = None

    def _load(self):
        if self._model is None:
            import mlx.core as mx
            from mlx_whisper.transcribe import ModelHolder

            self._model = ModelHolder.get_model(self.cfg.whisper_model, mx.float16)
        return self._model

    def detect_language(self, audio: np.ndarray) -> dict[str, float]:
        import mlx.core as mx
        from mlx_whisper.audio import N_FRAMES, N_SAMPLES, log_mel_spectrogram, pad_or_trim

        model = self._load()
        mel = log_mel_spectrogram(audio, n_mels=model.dims.n_mels, padding=N_SAMPLES)
        segment = pad_or_trim(mel, N_FRAMES, axis=-2).astype(mx.float16)
        _, probs = model.detect_language(segment)
        return dict(probs)

    def transcribe(self, audio: np.ndarray, language: str) -> list[dict]:
        import mlx_whisper

        result = mlx_whisper.transcribe(
            audio,
            path_or_hf_repo=self.cfg.whisper_model,
            language=language,
            condition_on_previous_text=False,
            initial_prompt=self.cfg.initial_prompt or None,
            verbose=None,
        )
        return result.get("segments", [])

    def release(self) -> None:
        try:
            import gc

            import mlx.core as mx
            from mlx_whisper.transcribe import ModelHolder

            ModelHolder.model = None
            ModelHolder.model_path = None
            self._model = None
            gc.collect()
            mx.clear_cache()
        except Exception:
            pass


def transcribe_blocks(
    blocks: list[Block],
    audio_by_track: dict[str, np.ndarray],
    transcriber: Transcriber,
    allowed: list[str],
    progress: Callable[[float, str], None] | None = None,
) -> list[Segment]:
    """Transcribe blocks longest-first so short blocks can borrow their speaker's language."""

    def detect(b: Block, s: float, e: float) -> str:
        track = audio_by_track[b.track]
        return choose_language(transcriber.detect_language(np.ascontiguousarray(track[int(s * SR): int(e * SR)])), allowed, None, False)

    blocks = split_by_language(blocks, detect)
    order = sorted(range(len(blocks)), key=lambda i: -blocks[i].duration)
    seconds_by_speaker_lang: dict[str, dict[str, float]] = defaultdict(lambda: defaultdict(float))
    segments: list[Segment] = []
    total_sec = sum(b.duration for b in blocks) or 1.0
    done_sec = 0.0
    for n, i in enumerate(order, 1):
        b = blocks[i]
        done_sec += b.duration
        if b.duration < MIN_BLOCK_SEC:
            continue
        track = audio_by_track[b.track]
        s0 = max(0, int((b.start - PAD_SEC) * SR))
        s1 = min(len(track), int((b.end + PAD_SEC) * SR))
        chunk = np.ascontiguousarray(track[s0:s1], dtype=np.float32)
        if chunk.size < int(MIN_BLOCK_SEC * SR):
            continue
        offset = s0 / SR
        probs = transcriber.detect_language(chunk)
        prior = seconds_by_speaker_lang.get(b.speaker)
        language = choose_language(probs, allowed, dict(prior) if prior else None, b.duration < SHORT_BLOCK_SEC)
        for seg in transcriber.transcribe(chunk, language):
            text = " ".join(seg.get("text", "").split())
            if not keep_segment(seg) or is_hallucination(text, b.duration):
                continue
            start = max(b.start, offset + float(seg["start"]))
            end = min(b.end, offset + float(seg["end"]))
            if end <= start:
                end = min(b.end, start + 0.5)
            segments.append(Segment(start, max(end, start), b.speaker, b.track, language, text))
            seconds_by_speaker_lang[b.speaker][language] += end - start
        if progress:
            progress(done_sec / total_sec, f"Transcribing block {n}/{len(blocks)}")
    return sorted(segments, key=lambda s: (s.start, s.end))


def language_stats(segments: list[Segment]) -> dict[str, float]:
    stats: dict[str, float] = defaultdict(float)
    for s in segments:
        stats[s.language] += max(0.0, s.end - s.start) + 0.01 * len(s.text)
    return dict(sorted(stats.items(), key=lambda kv: -kv[1]))
