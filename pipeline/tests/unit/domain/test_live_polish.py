import unicodedata

import pytest

from meeting_notes.domain.live_polish import (
    LivePolisher,
    PolishRules,
    apply_glossary,
    capitalize_sentences,
    drop_fillers,
    glossary_terms,
    join_chunks,
    polish_text,
)

RULES = PolishRules(glossary=tuple(glossary_terms(["Claude Code", "Tuấn: product lead", "iPhone", "MLX"])))


def nfd(text):
    return unicodedata.normalize("NFD", text)


def strip_marks(text):
    """Letters and their combining marks only, so tests can check no diacritic was added, dropped or moved."""
    decomposed = unicodedata.normalize("NFD", text).lower()
    return [c for c in decomposed if c.isalpha() or unicodedata.combining(c)]


def test_joins_a_sentence_split_across_chunks_and_closes_the_paragraph():
    assert polish_text(["chúng ta sẽ ra mắt.", "vào thứ hai tuần sau"], RULES, closed=True) == \
        "Chúng ta sẽ ra mắt vào thứ hai tuần sau."
    assert polish_text(["We should ship.", "Then we test"], RULES) == "We should ship. Then we test"
    assert polish_text(["see e.g.", "this one"], RULES) == "See e.g. this one"
    assert polish_text(["wait...", "okay"], RULES) == "Wait... okay"


def test_capitalizes_sentence_starts_including_vietnamese_capitals():
    assert capitalize_sentences("đúng rồi. ừ được. ầm ĩ quá! ơn giời") == "Đúng rồi. Ừ được. Ầm ĩ quá! Ơn giời"
    assert capitalize_sentences("iPhone mới. macOS cũ. github.com nhé. x86 thôi") == \
        "iPhone mới. macOS cũ. github.com nhé. x86 thôi"
    assert capitalize_sentences("version 3.5 is out") == "Version 3.5 is out"


def test_glossary_spelling_is_case_insensitive_whole_word_and_keeps_diacritics():
    terms = RULES.glossary
    assert apply_glossary("dùng claude code với mlx", terms) == "dùng Claude Code với MLX"
    assert apply_glossary("anh tuấn nói", terms) == "anh Tuấn nói"
    assert apply_glossary("anh tuan nói", terms) == "anh tuan nói"  # a different tone is a different word
    assert apply_glossary("mlxs và premlx", terms) == "mlxs và premlx"
    assert glossary_terms(["C++", "  ", "Tuấn: lead"]) == ["Tuấn", "C++"]
    assert apply_glossary("viết c++ đi", ("C++",)) == "viết C++ đi"


def test_drops_only_pure_interjections():
    assert drop_fillers("ờ, tôi nghĩ là ừm được") == "tôi nghĩ là được"
    assert drop_fillers("so um I uh think") == "so I think"
    assert drop_fillers("À, thế à?") == "thế à?"  # interjection dropped, sentence-final particle kept
    assert drop_fillers("vậy à") == "vậy à"
    assert drop_fillers("ừ, được") == "ừ, được"  # "ừ" = yes
    assert drop_fillers("thì kiểu nói chung là ổn") == "thì kiểu nói chung là ổn"
    assert drop_fillers("ok ờ.") == "ok."
    assert polish_text(["ừm"], RULES, closed=True) == ""


def test_collapses_decode_loops_but_keeps_vietnamese_reduplication():
    assert polish_text(["cảm ơn cảm ơn cảm ơn cảm ơn cảm ơn"], RULES) == "Cảm ơn"
    assert polish_text(["nhà xanh xanh đẹp đẹp"], RULES) == "Nhà xanh xanh đẹp đẹp"


def test_spacing_is_tidied():
    assert polish_text(["  xin chào ,  mọi người  !"], RULES) == "Xin chào, mọi người!"


@pytest.mark.parametrize("text", [
    "hoà bình và hòa bình", "bán bàn bạn bận", "khuya rồi, thuỷ ơi", "Đà Nẵng, Huế, Quy Nhơn", "người ưu tiên ở đây",
])
def test_never_alters_vietnamese_tone_marks_and_outputs_nfc(text):
    out = polish_text([nfd(text)], PolishRules(), closed=True)
    assert unicodedata.is_normalized("NFC", out)
    assert strip_marks(out) == strip_marks(text)  # same letters, same marks, same placement ("hoà" stays "hoà")


def test_code_switched_text_keeps_english_terms():
    out = polish_text(["mình deploy cái API.", "lên staging rồi chạy migration nhé"], RULES, closed=True)
    assert out == "Mình deploy cái API lên staging rồi chạy migration nhé."


def test_polisher_paragraphs_by_speaker_pause_and_length():
    p = LivePolisher(PolishRules(pause_sec=2.5, max_words=6))
    first = p.add("mic", "Me", 0, 0.0, 2.0, "xin chào.")
    assert [(x.para, x.text, x.closed) for x in first] == [(0, "Xin chào.", False)]
    assert [x.text for x in p.add("mic", "Me", 1, 2.5, 4.0, "mọi người")] == ["Xin chào mọi người"]
    # speaker change closes the mic paragraph (final period) and opens one for system
    out = p.add("system", "Others", 0, 4.5, 6.0, "hi there")
    assert [(x.track, x.para, x.text, x.closed) for x in out] == [("mic", 0, "Xin chào mọi người.", True),
                                                                 ("system", 0, "Hi there", False)]
    # a long pause on the same track starts a new paragraph
    out = p.add("system", "Others", 1, 10.0, 11.0, "next topic")
    assert [(x.para, x.text) for x in out] == [(0, "Hi there."), (1, "Next topic")]
    # reaching max_words closes the paragraph
    out = p.add("system", "Others", 2, 11.2, 12.0, "one two three four")
    assert [(x.para, x.text, x.closed, x.seqs) for x in out] == [(1, "Next topic one two three four.", True, [1, 2])]
    assert p.add("system", "Others", 2, 11.2, 12.0, "one two three four") == []  # re-sent chunk (resume) is ignored
    assert p.add("system", "Others", 3, 12.1, 13.0, "ừm") == []  # filler-only paragraph has nothing to show
    assert [x.text for x in p.close_all()] == []


def test_polisher_emits_only_changes_and_closes_at_stop():
    p = LivePolisher(PolishRules())
    p.add("mic", "Me", 0, 0.0, 1.0, "Done.")
    assert p.add("mic", "Me", 1, 1.2, 2.0, "ờ") == []  # text unchanged after the filler is hidden
    assert p.close_all() == []  # closing adds nothing new: no re-send
    assert p.open == {}


def test_join_chunks_skips_empty_text():
    assert join_chunks(["", "  a.", "b"]) == "a b"
