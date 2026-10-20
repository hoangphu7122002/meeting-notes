import numpy as np

from meeting_notes.audio import SR
from meeting_notes.speakers import Block
from meeting_notes.transcribe import Segment, choose_language, is_hallucination, keep_segment, language_stats, split_long_blocks, transcribe_blocks


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


class FakeTranscriber:
    def __init__(self):
        self.calls = []

    def detect_language(self, audio):
        return {"vi": 0.7, "en": 0.3} if audio.mean() > 0 else {"en": 0.55, "vi": 0.45}

    def transcribe(self, audio, language):
        self.calls.append(language)
        return [{"start": 0.25, "end": len(audio) / SR - 0.25, "text": f" hello {language} ", "no_speech_prob": 0.01, "avg_logprob": -0.2, "compression_ratio": 1.2}]


def test_transcribe_blocks_offsets_and_language_prior():
    audio = np.concatenate([np.full(SR * 10, 0.2), np.full(SR * 2, -0.2)]).astype(np.float32)
    blocks = [Block(0, 10, "Me", "mic"), Block(10, 11.5, "Me", "mic"), Block(11.6, 11.8, "Me", "mic")]
    fake = FakeTranscriber()
    segs = transcribe_blocks(blocks, {"mic": audio}, fake, ["vi", "en"])
    assert len(segs) == 2  # the 0.2 s block is skipped
    assert segs[0].start == 0.25 and segs[0].text == "hello vi"
    assert segs[1].language == "vi"  # short block follows the speaker's dominant language
    assert language_stats(segs) and next(iter(language_stats(segs))) == "vi"


def test_segment_dict():
    assert Segment(1.234, 2.0, "Me", "mic", "vi", "x").to_dict()["start"] == 1.23


def test_split_by_language_at_turn_boundaries():
    from meeting_notes.transcribe import split_by_language

    b = Block(0, 20, "A", "mixed", [(0, 5), (5.5, 9), (9.5, 15), (15.2, 15.6), (16, 20)])
    lang = {0: "vi", 5.5: "vi", 9.5: "en", 16: "en"}
    out = split_by_language([b], lambda blk, s, e: lang[s])
    assert [(x.start, x.end) for x in out] == [(0, 9.5), (9.5, 20)]
    assert out[1].parts[0] == (9.5, 15)
    same = split_by_language([b], lambda blk, s, e: "vi")
    assert same == [b]


def test_collapse_repeats():
    from meeting_notes.transcribe import collapse_repeats

    assert collapse_repeats("cảm ơn cảm ơn cảm ơn cảm ơn cảm ơn") == "cảm ơn"
    assert collapse_repeats("ok, ok, ok, ok. Let's go") == "ok. Let's go"
    assert collapse_repeats("we we will go") == "we we will go"  # short stutters are kept
    assert collapse_repeats("Chúng ta sẽ phát hành vào thứ sáu.") == "Chúng ta sẽ phát hành vào thứ sáu."


def test_whisper_prompt_from_glossary():
    from meeting_notes.config import Config, glossary_entries
    from meeting_notes.transcribe import whisper_prompt

    assert whisper_prompt(Config(), "vi") is None
    cfg = Config(glossary=["Momos", "Tuấn: product lead", "momos", " Kubernetes "], initial_prompt="Họp sản phẩm.")
    assert glossary_entries(cfg.glossary) == [("Momos", ""), ("Tuấn", "product lead"), ("Kubernetes", "")]
    assert whisper_prompt(cfg, "vi") == "Họp sản phẩm. Momos, Tuấn, Kubernetes."
    assert whisper_prompt(Config(glossary=["Momos"]), "en") == "Momos."
    assert glossary_entries("A, B\nC") == [("A", ""), ("B", ""), ("C", "")]
    long = whisper_prompt(Config(glossary=[f"term{i:03d}" for i in range(200)]), "en")
    assert len(long) < 600


def _speechlike(sec, f0=140.0):
    t = np.arange(int(sec * SR)) / SR
    return (0.2 * np.sign(np.sin(2 * np.pi * f0 * t)) * (0.6 + 0.4 * np.sin(2 * np.pi * 3 * t))).astype(np.float32)


def test_speech_spans_skip_noise_and_split_long_pauses():
    from meeting_notes.transcribe import speech_spans, speech_threshold_db

    rng = np.random.default_rng(0)
    room = rng.normal(0, 0.002, SR * 20).astype(np.float32)
    clicks = room.copy()
    for k in range(0, len(clicks) - 200, int(0.18 * SR)):
        clicks[k:k + 192] += rng.normal(0, 0.05, 192).astype(np.float32)
    speech = room.copy()
    speech[SR:SR * 3] += _speechlike(2)
    speech[SR * 9:SR * 11] += _speechlike(2, 180)
    th = speech_threshold_db(np.concatenate([speech, room]))
    assert speech_spans(room, th, 2.0) == []
    assert speech_spans(clicks, th, 2.0) == []  # keyboard: loud but not voiced
    spans = speech_spans(speech, th, 2.0)
    assert len(spans) == 2  # 6 s pause splits the block, silence around is trimmed
    assert abs(spans[0][0] / SR - 0.7) < 0.15 and abs(spans[1][1] / SR - 11.3) < 0.15
    assert len(speech_spans(speech, th, 10.0)) == 1


def test_transcribe_blocks_vad_skips_silent_blocks_and_offsets_spans():
    rng = np.random.default_rng(1)
    audio = rng.normal(0, 0.002, SR * 30).astype(np.float32)
    audio[SR * 2:SR * 4] += _speechlike(2)
    audio[SR * 8:SR * 10] += _speechlike(2)
    blocks = [Block(1, 11, "Me", "mic"), Block(15, 28, "Me", "mic")]  # second block is silence only
    fake = FakeTranscriber()
    segs = transcribe_blocks(blocks, {"mic": audio}, fake, ["vi", "en"], vad=True, split_gap=2.0)
    assert len(fake.calls) == 2 and len(segs) == 2  # two spans of block 1, nothing for the silent block
    assert abs(segs[0].start - 1.95) < 0.2 and abs(segs[1].start - 7.95) < 0.2


def test_transcriber_caps_mlx_cache(monkeypatch):
    import sys
    import types

    from meeting_notes.config import Config
    from meeting_notes.transcribe import Transcriber

    calls = []
    mx = types.SimpleNamespace(float16="f16", set_cache_limit=calls.append)
    holder = types.SimpleNamespace(get_model=lambda name, dtype: "model")
    mlx = types.ModuleType("mlx")
    mlx.core = mx
    monkeypatch.setitem(sys.modules, "mlx", mlx)
    monkeypatch.setitem(sys.modules, "mlx.core", mx)
    monkeypatch.setitem(sys.modules, "mlx_whisper.transcribe", types.SimpleNamespace(ModelHolder=holder))
    monkeypatch.setitem(sys.modules, "mlx_whisper", types.ModuleType("mlx_whisper"))

    assert Transcriber(Config())._load() == "model"
    assert calls == [256 * 2**20]
    calls.clear()
    Transcriber(Config(mlx_cache_limit_mb=-1))._load()
    assert calls == []
