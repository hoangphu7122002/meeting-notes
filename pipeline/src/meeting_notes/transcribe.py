"""On-device transcription with mlx-whisper, one call per speaker block with per-block language detection."""

from __future__ import annotations

import re
import unicodedata
from collections import defaultdict
from collections.abc import Callable
from dataclasses import dataclass

import numpy as np

from .audio import FRAME_SEC, SR, frame_db, merge_gaps, runs
from .config import Config, glossary_entries
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


_REPEAT = re.compile(r"(?i)\b((?:\S+\s+){0,5}?\S+?)(?:[\s,.;!?]+\1\b){3,}")


def collapse_repeats(text: str) -> str:
    """Collapse a phrase repeated 4+ times in a row (a whisper decoding loop) to a single copy."""
    prev = None
    while prev != text:
        prev, text = text, _REPEAT.sub(r"\1", text)
    return text


# Optional phrase before the term list. Measured on the synthetic benchmark (docs/pipeline-quality.md):
# a bare term list beat "Cuộc họp. Từ khóa:" / "Meeting. Terms:" (WER 0.065 vs 0.071, term recall 0.83 vs 0.79).
PROMPT_LEAD: dict[str, str] = {}
MAX_PROMPT_CHARS = 500  # whisper keeps at most ~223 prompt tokens


def whisper_prompt(cfg: Config, language: str) -> str | None:
    """initial_prompt + glossary terms as a comma list (optionally after a per-language lead phrase).
    None when nothing is configured."""
    parts = []
    if cfg.initial_prompt.strip():
        parts.append(cfg.initial_prompt.strip())
    terms = [t for t, _ in glossary_entries(cfg.glossary)]
    if terms:
        listed, size = [], 0
        for t in terms:
            if size + len(t) + 2 > MAX_PROMPT_CHARS:
                break
            listed.append(t)
            size += len(t) + 2
        lead = PROMPT_LEAD.get(language, PROMPT_LEAD.get("en", ""))
        parts.append(f"{lead} {', '.join(listed)}.".strip())
    return " ".join(parts) or None


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

        temperature = (0.0, 0.2, 0.4, 0.6, 0.8, 1.0) if self.cfg.whisper_temperature_fallback else 0.0
        result = mlx_whisper.transcribe(
            audio,
            path_or_hf_repo=self.cfg.whisper_model,
            language=language,
            temperature=temperature,
            condition_on_previous_text=self.cfg.whisper_condition_on_previous_text,
            initial_prompt=whisper_prompt(self.cfg, language),
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
    vad: bool = False,
    split_gap: float = 2.0,
) -> list[Segment]:
    """Transcribe blocks longest-first so short blocks can borrow their speaker's language.

    With `vad`, each block is trimmed to its voiced spans (split at pauses >= `split_gap` s) and blocks
    without speech are skipped, so whisper never decodes long silence.
    """
    thresholds = {name: speech_threshold_db(x) for name, x in audio_by_track.items()} if vad else {}

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
        spans = speech_spans(chunk, thresholds[b.track], split_gap) if vad else [(0, len(chunk))]
        spans = [(a, z) for a, z in spans if z - a >= int(MIN_BLOCK_SEC * SR)]
        if not spans:
            if progress:
                progress(done_sec / total_sec, f"Transcribing block {n}/{len(blocks)}")
            continue
        voiced = np.concatenate([chunk[a:z] for a, z in spans]) if len(spans) > 1 else chunk[spans[0][0]:spans[0][1]]
        probs = transcriber.detect_language(np.ascontiguousarray(voiced))
        prior = seconds_by_speaker_lang.get(b.speaker)
        language = choose_language(probs, allowed, dict(prior) if prior else None, b.duration < SHORT_BLOCK_SEC)
        for a, z in spans:
            offset = (s0 + a) / SR
            for seg in transcriber.transcribe(np.ascontiguousarray(chunk[a:z]), language):
                text = collapse_repeats(" ".join(seg.get("text", "").split()))
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
