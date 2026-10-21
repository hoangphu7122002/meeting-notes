import numpy as np

from meeting_notes.domain.segments import (Segment, choose_language, collapse_repeats, is_hallucination, keep_segment,
                                           split_by_language, split_long_blocks)
from meeting_notes.domain.signal import SR
from meeting_notes.domain.speakers import Block


def test_choose_language_restricted_to_allowed():
    assert choose_language({"zh": 0.6, "vi": 0.3, "en": 0.1}, ["vi", "en"], None, short=False) == "vi"
    assert choose_language({"zh": 0.6, "vi": 0.3}, [], None, short=False) == "zh"


def test_short_block_uses_speaker_prior():
    assert choose_language({"en": 0.6, "vi": 0.4}, ["vi", "en"], {"vi": 30.0}, short=True) == "vi"
    assert choose_language({"en": 0.95, "vi": 0.05}, ["vi", "en"], {"vi": 30.0}, short=True) == "en"


def test_hallucination_filter():
    assert is_hallucination("Hẹn gặp lại các bạn trong những video tiếp theo!", 3)
    assert is_hallucination("Thanks for watching.", 1.5)
    assert is_hallucination("   ", 5)
    assert not is_hallucination("Chúng ta sẽ phát hành vào thứ sáu.", 3)
    assert not keep_segment({"compression_ratio": 3.0})
    assert not keep_segment({"no_speech_prob": 0.9, "avg_logprob": -1.2})
    assert keep_segment({"no_speech_prob": 0.1, "avg_logprob": -0.3, "compression_ratio": 1.4})


def test_split_long_blocks_cuts_at_quiet_point():
    audio = np.full(SR * 100, 0.3, dtype=np.float32)
    audio[int(35 * SR): int(36 * SR)] = 0.0  # quiet second inside [27, 45]
    blocks = split_long_blocks([Block(0, 100, "A", "mixed")], {"mixed": audio}, max_len=45)
    assert len(blocks) >= 3
    assert 35 <= blocks[0].end <= 36
    assert blocks[-1].end == 100 and all(b.duration <= 45 + 1e-6 for b in blocks)


def test_segment_dict():
    assert Segment(1.234, 2.0, "Me", "mic", "vi", "x").to_dict()["start"] == 1.23


def test_split_by_language_at_turn_boundaries():
    b = Block(0, 20, "A", "mixed", [(0, 5), (5.5, 9), (9.5, 15), (15.2, 15.6), (16, 20)])
    lang = {0: "vi", 5.5: "vi", 9.5: "en", 16: "en"}
    out = split_by_language([b], lambda blk, s, e: lang[s])
    assert [(x.start, x.end) for x in out] == [(0, 9.5), (9.5, 20)]
    assert out[1].parts[0] == (9.5, 15)
    same = split_by_language([b], lambda blk, s, e: "vi")
    assert same == [b]


def test_collapse_repeats():
    assert collapse_repeats("cảm ơn cảm ơn cảm ơn cảm ơn cảm ơn") == "cảm ơn"
    assert collapse_repeats("ok, ok, ok, ok. Let's go") == "ok. Let's go"
    assert collapse_repeats("we we will go") == "we we will go"  # short stutters are kept
    assert collapse_repeats("Chúng ta sẽ phát hành vào thứ sáu.") == "Chúng ta sẽ phát hành vào thứ sáu."
