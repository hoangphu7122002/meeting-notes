"""Whisper hallucination filter: known outro/subtitle phrases, impossible word rates, decoding loops.

Whisper invents text on silence, noise and block tails, mostly YouTube outro boilerplate learned from subtitles
("Cảm ơn các bạn đã theo dõi", "Thanks for watching"). Real speech may contain the same words (a presenter
closing a talk), so a known phrase alone only drops a segment when the evidence says it was not spoken: the text
is little more than the phrase, the block is short, the phrases make up most of the text, or the words could not
fit in the segment's time. Rules lean toward keeping text; every drop needs two signals or a near-exact match.
"""

from __future__ import annotations

import re
import unicodedata

# Known hallucinated phrases (vi + en), written plainly; matching ignores case, punctuation and spaces.
HALLUCINATIONS = [
    "hẹn gặp lại các bạn trong những video tiếp theo",
    "hẹn gặp lại các bạn trong video tiếp theo",
    "cảm ơn các bạn đã theo dõi",
    "cám ơn các bạn đã theo dõi",
    "cảm ơn các bạn đã xem video",
    "hãy subscribe cho kênh",
    "đăng ký kênh",
    "đăng kí kênh",
    "để không bỏ lỡ những video hấp dẫn",
    "like share và subscribe",
    "ghiền mì gõ",
    "la la school",
    "phụ đề bởi",
    "thực hiện phụ đề",
    "thanks for watching",
    "thank you for watching",
    "thank you so much for watching",
    "please subscribe",
    "like and subscribe",
    "don't forget to subscribe",
    "see you in the next video",
    "subtitles by",
    "amara.org",
]

PHRASE_SLACK_CHARS = 16  # a phrase plus this many letters (spaces ignored) is "just the phrase"
SHORT_BLOCK_SEC = 8.0  # inside a short block a known phrase is almost never real speech
PHRASE_COVERAGE = 0.5  # known phrases make up at least this share of the text
MAX_WORDS_PER_SEC = 8.0  # fast Vietnamese is ~6-7 syllables/s; more words than this did not fit the segment
LOOP_MIN_WORDS = 10
LOOP_MAX_DISTINCT = 0.2  # <= 20 % distinct words in a long segment = a decoding loop collapse_repeats missed
NO_PHRASE_MAX_WORDS_PER_SEC = 15.0  # without a known phrase: only absurd rates on short, unsure segments
NO_PHRASE_MAX_SEC = 1.0
UNSURE_LOGPROB = -0.8
UNSURE_NO_SPEECH = 0.5


def normalize(text: str) -> str:
    text = unicodedata.normalize("NFC", text.lower())
    return re.sub(r"[^\w\s]", "", text).strip()


def _compact(text: str) -> str:
    return re.sub(r"\s+", "", normalize(text))


_PHRASES = sorted({_compact(p) for p in HALLUCINATIONS}, key=len, reverse=True)


def phrase_coverage(text: str) -> tuple[float, int]:
    """(share of the text's characters inside known phrases, longest matched phrase length), spaces ignored,
    so "lalaschool" matches "la la school"."""
    compact = _compact(text)
    if not compact:
        return 0.0, 0
    covered = [False] * len(compact)
    longest = 0
    for phrase in _PHRASES:
        start = compact.find(phrase)
        while start >= 0:
            covered[start:start + len(phrase)] = [True] * len(phrase)
            longest = max(longest, len(phrase))
            start = compact.find(phrase, start + len(phrase))
    return sum(covered) / len(compact), longest


def words_per_sec(text: str, seg_sec: float | None) -> float:
    words = len(normalize(text).split())
    if seg_sec is None or words == 0:
        return 0.0
    return words / max(seg_sec, 0.05)


def is_loop(text: str) -> bool:
    words = normalize(text).split()
    return len(words) >= LOOP_MIN_WORDS and len(set(words)) / len(words) <= LOOP_MAX_DISTINCT


def is_hallucination(text: str, block_sec: float, seg_sec: float | None = None) -> bool:
    """True when `text` (one whisper segment lasting `seg_sec` s inside a `block_sec` s block) is not speech."""
    norm = normalize(text)
    if not norm:
        return True
    if is_loop(text):
        return True
    coverage, longest = phrase_coverage(text)
    if not longest:
        return False
    compact_len = len(norm.replace(" ", ""))
    return (compact_len <= longest + PHRASE_SLACK_CHARS or block_sec < SHORT_BLOCK_SEC
            or coverage >= PHRASE_COVERAGE or words_per_sec(text, seg_sec) > MAX_WORDS_PER_SEC)


def keep_segment(seg: dict) -> bool:
    """Whisper's own confidence signals for one segment dict (start, end, text, avg_logprob, ...)."""
    if seg.get("compression_ratio", 0) > 2.6:
        return False
    unsure_logprob = seg.get("avg_logprob", 0) < UNSURE_LOGPROB
    if seg.get("no_speech_prob", 0) > 0.6 and seg.get("avg_logprob", 0) < -0.7:
        return False
    if "start" in seg and "end" in seg:
        seg_sec = float(seg["end"]) - float(seg["start"])
        unsure = unsure_logprob or seg.get("no_speech_prob", 0) > UNSURE_NO_SPEECH
        if (unsure and seg_sec < NO_PHRASE_MAX_SEC
                and words_per_sec(seg.get("text", ""), seg_sec) > NO_PHRASE_MAX_WORDS_PER_SEC):
            return False
    return True
