"""Diarizer.voice_check with a fake embedder (no model download): VAD, windows, verdict."""

import numpy as np
from helpers import room, speechlike

from meeting_notes.adapters.outbound.pyannote_diarizer import Diarizer
from meeting_notes.config import Config


def talk(sec, sign):
    """Speech-like audio; the DC offset encodes the speaker for the fake embedder."""
    return speechlike(sec) + np.float32(0.05 * sign)


def meeting(pattern):
    return np.concatenate([np.concatenate([talk(sec, sign), room(0.8)]) for sec, sign in pattern])


def diarizer(calls):
    d = Diarizer(Config())

    def embed(chunk):
        calls.append(len(chunk))
        return np.array([1.0, 0.0]) if chunk.mean() > 0 else np.array([0.0, 1.0])

    d._embedder = embed
    return d


def test_one_voice_is_single_and_turns_cover_speech():
    calls = []
    check = diarizer(calls).voice_check(meeting([(9.0, 1)] * 10))
    assert check.single is True and len(calls) >= 8
    assert {c for _, _, c in check.turns} == {"0"} and sum(e - s for s, e, _ in check.turns) > 80


def test_two_voices_are_several():
    check = diarizer([]).voice_check(meeting([(9.0, 1), (9.0, -1)] * 5))
    assert check.single is False


def test_excluded_remote_speech_is_not_embedded():
    audio = meeting([(9.0, 1), (9.0, -1)] * 5)
    other = [(9.8 + 19.6 * i, 18.8 + 19.6 * i) for i in range(5)]  # where the second voice talks
    assert diarizer([]).voice_check(audio, exclude=other).single is True


def test_short_speech_decides_without_the_embedding_model():
    calls = []
    check = diarizer(calls).voice_check(np.concatenate([room(20), talk(10, 1), room(20)]))
    assert check.single is True and calls == []


def test_silence_is_unsure():
    assert diarizer([]).voice_check(np.zeros(16000 * 5, np.float32)).single is None
