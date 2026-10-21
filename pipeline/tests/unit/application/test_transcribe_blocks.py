import numpy as np
from helpers import speechlike as _speechlike

from meeting_notes.application.transcribe_blocks import transcribe_blocks, whisper_prompt
from meeting_notes.config import Config
from meeting_notes.domain.glossary import glossary_entries
from meeting_notes.domain.segments import language_stats
from meeting_notes.domain.signal import SR
from meeting_notes.domain.speakers import Block


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


def test_whisper_prompt_from_glossary():
    assert whisper_prompt(Config(), "vi") is None
    cfg = Config(glossary=["Momos", "Tuấn: product lead", "momos", " Kubernetes "], initial_prompt="Họp sản phẩm.")
    assert glossary_entries(cfg.glossary) == [("Momos", ""), ("Tuấn", "product lead"), ("Kubernetes", "")]
    assert whisper_prompt(cfg, "vi") == "Họp sản phẩm. Momos, Tuấn, Kubernetes."
    assert whisper_prompt(Config(glossary=["Momos"]), "en") == "Momos."
    assert glossary_entries("A, B\nC") == [("A", ""), ("B", ""), ("C", "")]
    long = whisper_prompt(Config(glossary=[f"term{i:03d}" for i in range(200)]), "en")
    assert len(long) < 600


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
