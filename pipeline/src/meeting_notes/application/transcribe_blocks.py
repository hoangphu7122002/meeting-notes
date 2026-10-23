"""Transcribe speaker blocks with a Transcriber port: language choice per block, VAD trimming, filtering."""

from __future__ import annotations

from collections import defaultdict
from collections.abc import Callable

import numpy as np

from ..config import Config
from ..domain.glossary import glossary_entries
from ..domain.hallucination import is_hallucination, keep_segment
from ..domain.segments import Segment, choose_language, collapse_repeats, split_by_language
from ..domain.signal import SR, speech_spans, speech_threshold_db
from ..domain.speakers import Block
from .ports import Transcriber

PAD_SEC = 0.25
MIN_BLOCK_SEC = 0.4
SHORT_BLOCK_SEC = 2.5

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


def transcribe_blocks(
    blocks: list[Block],
    audio_by_track: dict[str, np.ndarray],
    transcriber: Transcriber,
    allowed: list[str],
    progress: Callable[[float, str], None] | None = None,
    vad: bool = False,
    split_gap: float = 2.0,
    prior: dict[str, dict[str, float]] | None = None,
) -> list[Segment]:
    """Transcribe blocks longest-first so short blocks can borrow their speaker's language.

    With `vad`, each block is trimmed to its voiced spans (split at pauses >= `split_gap` s) and blocks
    without speech are skipped, so whisper never decodes long silence. `prior` seeds the per-speaker
    language seconds (live segments reused at Stop).
    """
    thresholds = {name: speech_threshold_db(x) for name, x in audio_by_track.items()} if vad else {}

    def detect(b: Block, s: float, e: float) -> str:
        track = audio_by_track[b.track]
        return choose_language(transcriber.detect_language(np.ascontiguousarray(track[int(s * SR): int(e * SR)])), allowed, None, False)

    blocks = split_by_language(blocks, detect)
    order = sorted(range(len(blocks)), key=lambda i: -blocks[i].duration)
    seconds_by_speaker_lang: dict[str, dict[str, float]] = defaultdict(lambda: defaultdict(float))
    for speaker, langs in (prior or {}).items():
        seconds_by_speaker_lang[speaker].update(langs)
    segments: list[Segment] = []
    total_sec = sum(b.duration for b in blocks) or 1.0
    done_sec = 0.0
    for n, i in enumerate(order, 1):
        b = blocks[i]
        done_sec += b.duration
        decoded, _ = decode_block(b, audio_by_track[b.track], thresholds.get(b.track, 0.0), transcriber, allowed,
                                  seconds_by_speaker_lang, vad, split_gap)
        segments += decoded or []
        if progress and decoded is not None:
            progress(done_sec / total_sec, f"Transcribing block {n}/{len(blocks)}")
    return sorted(segments, key=lambda s: (s.start, s.end))


def decode_block(b: Block, track: np.ndarray, threshold: float, transcriber: Transcriber, allowed: list[str],
                 seconds_by_speaker_lang: dict[str, dict[str, float]], vad: bool, split_gap: float,
                 base_sec: float = 0.0) -> tuple[list[Segment] | None, str | None]:
    """Decode one block (VAD spans, language choice with the speaker prior, glossary prompt, filters).

    `track[0]` is at recorded time `base_sec` (live chunks pass only their padded audio). Updates the prior
    in place; returns the kept segments (None when the block is too short to look at) and the language
    (None when nothing was decoded)."""
    if b.duration < MIN_BLOCK_SEC:
        return None, None
    s0 = max(0, int((b.start - PAD_SEC - base_sec) * SR))
    s1 = min(len(track), int((b.end + PAD_SEC - base_sec) * SR))
    chunk = np.ascontiguousarray(track[s0:s1], dtype=np.float32)
    if chunk.size < int(MIN_BLOCK_SEC * SR):
        return None, None
    spans = speech_spans(chunk, threshold, split_gap) if vad else [(0, len(chunk))]
    spans = [(a, z) for a, z in spans if z - a >= int(MIN_BLOCK_SEC * SR)]
    if not spans:
        return [], None
    prior = seconds_by_speaker_lang.get(b.speaker)

    def choose(probs: dict[str, float]) -> str:
        return choose_language(probs, allowed, dict(prior) if prior else None, b.duration < SHORT_BLOCK_SEC)

    if len(spans) == 1:
        # One voiced span: detection shares the decoder's encoder pass (identical text for the chosen language).
        language, first = transcriber.transcribe_auto(np.ascontiguousarray(chunk[spans[0][0]:spans[0][1]]), choose)
        decoded = [first]
    else:
        # Several spans: detect on all voiced audio together (more evidence than any one span), then decode each.
        voiced = np.concatenate([chunk[a:z] for a, z in spans])
        language = choose(transcriber.detect_language(np.ascontiguousarray(voiced)))
        decoded = [transcriber.transcribe(np.ascontiguousarray(chunk[a:z]), language) for a, z in spans]
    segments: list[Segment] = []
    for (a, _), span_segments in zip(spans, decoded):
        offset = base_sec + (s0 + a) / SR
        for seg in span_segments:
            text = collapse_repeats(" ".join(seg.get("text", "").split()))
            seg_sec = float(seg["end"]) - float(seg["start"])
            if not keep_segment(seg) or is_hallucination(text, b.duration, seg_sec):
                continue
            start = max(b.start, offset + float(seg["start"]))
            end = min(b.end, offset + float(seg["end"]))
            if end <= start:
                end = min(b.end, start + 0.5)
            segments.append(Segment(start, max(end, start), b.speaker, b.track, language, text))
            seconds_by_speaker_lang.setdefault(b.speaker, defaultdict(float))[language] += end - start
    return segments, language
