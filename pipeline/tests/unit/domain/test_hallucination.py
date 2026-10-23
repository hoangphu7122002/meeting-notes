import pytest

from meeting_notes.domain.hallucination import is_hallucination, is_loop, keep_segment, phrase_coverage

# W1 mic-skip bench, verbatim: a 0.37 s tail segment of a long VAD-bounded block (21 words).
OUTRO = "Cảm ơn các bạn đã theo dõi và ủng hộ cho kênh lalaschool Để không bỏ lỡ những video hấp dẫn"


@pytest.mark.parametrize("text, block_sec, seg_sec", [
    ("Hẹn gặp lại các bạn trong những video tiếp theo!", 3, None),
    ("Thanks for watching.", 1.5, None),
    ("   ", 5, None),
    ("...", 20, 2.0),
    (OUTRO, 20.0, 0.37),  # long block, long text: caught by impossible word rate and phrase coverage
    (OUTRO, 20.0, None),  # no timing: phrases still cover most of the text
    ("Subtitles by the Amara.org community", 25, 3.0),  # "amara.org" used to never match (dot stripped)
    ("Hãy subscribe cho kênh Ghiền Mì Gõ để không bỏ lỡ những video hấp dẫn", 26, 4.0),
    ("Thank you so much for watching, see you in the next video!", 22, 3.5),
    ("lalaschool", 15, 0.5),
    ("Cảm ơn các bạn đã theo dõi, cảm ơn các bạn đã theo dõi, ok", 15, 6.0),
    ("ừ " * 12, 15, 5.0),  # long loop of one word
])
def test_hallucinations_are_dropped(text, block_sec, seg_sec):
    assert is_hallucination(text, block_sec, seg_sec)


@pytest.mark.parametrize("text, block_sec, seg_sec", [
    ("Chúng ta sẽ phát hành vào thứ sáu.", 3, 2.0),
    ("Thank you.", 2, 0.8),  # bare thanks is real meeting speech
    ("Cảm ơn mọi người, hẹn gặp lại tuần sau nhé.", 5, 2.5),
    # A presenter's real closing line inside a long block, at a human speaking rate.
    ("Vậy là hết phần demo hôm nay, cảm ơn các bạn đã theo dõi, giờ mình chuyển sang phần hỏi đáp về "
     "kế hoạch phát hành quý tới nhé", 25, 9.0),
    ("Team marketing muốn tăng lượt đăng ký kênh YouTube lên gấp đôi trong quý này, mình cần thêm ngân "
     "sách quảng cáo", 20, 7.0),
    ("We should add a please subscribe banner to the landing page before the launch next Friday", 20, 5.5),
    ("không không, ý mình là bản thứ hai chứ không phải bản thứ nhất", 10, 4.0),
    ("ok ok ok let's move on", 10, 1.5),
])
def test_real_speech_is_kept(text, block_sec, seg_sec):
    assert not is_hallucination(text, block_sec, seg_sec)


def test_phrase_coverage_ignores_spaces_and_case():
    cov, longest = phrase_coverage("LaLa School")
    assert cov == 1.0 and longest == len("lalaschool")
    assert phrase_coverage("họp xong rồi") == (0.0, 0)


def test_loop_needs_many_words_and_few_distinct():
    assert is_loop("vâng " * 10)
    assert not is_loop("vâng vâng vâng")
    assert not is_loop("một hai ba bốn năm sáu bảy tám chín mười")


def test_keep_segment_confidence_rules():
    assert not keep_segment({"compression_ratio": 3.0})
    assert not keep_segment({"no_speech_prob": 0.9, "avg_logprob": -1.2})
    assert keep_segment({"no_speech_prob": 0.1, "avg_logprob": -0.3, "compression_ratio": 1.4})
    burst = " ".join(["chữ"] * 20)
    # 20 words in 0.4 s from an unsure window: not speech even without a known phrase.
    assert not keep_segment({"start": 27.6, "end": 28.0, "text": burst, "avg_logprob": -0.9, "no_speech_prob": 0.2})
    assert not keep_segment({"start": 27.6, "end": 28.0, "text": burst, "avg_logprob": -0.3, "no_speech_prob": 0.7})
    # Same burst from a confident window, or at a human rate: kept (timestamps can be squeezed at a window end).
    assert keep_segment({"start": 27.6, "end": 28.0, "text": burst, "avg_logprob": -0.3, "no_speech_prob": 0.1})
    assert keep_segment({"start": 20.0, "end": 24.0, "text": burst, "avg_logprob": -0.9, "no_speech_prob": 0.2})
