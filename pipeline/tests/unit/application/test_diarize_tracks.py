"""Mic single-voice fast path: skips full diarization only when the check is sure."""

import numpy as np
import pytest

from meeting_notes.adapters.outbound.progress_reporter import Reporter
from meeting_notes.application.diarize_tracks import SINGLE_VOICE, diarize_tracks
from meeting_notes.config import Config
from meeting_notes.domain.signal import SR
from meeting_notes.domain.speakers import TrackDiarization
from meeting_notes.domain.voice_check import VoiceCheck

MIC_TURNS = [(1.0, 4.0, "a"), (6.0, 9.0, "b"), (10.0, 30.0, "a"), (31.0, 60.0, "b")]  # two real voices
SYS_TURNS = [(4.0, 6.0, "x"), (60.0, 62.0, "y")]


class FakeDiarizer:
    def __init__(self, verdict):
        self.verdict = verdict
        self.diarized: list[str] = []
        self.excluded = None

    def diarize(self, audio, progress=None):
        track = "mic" if audio[0] > 0 else "system"
        self.diarized.append(track)
        return TrackDiarization(MIC_TURNS if track == "mic" else SYS_TURNS, "pyannote:fake", [])

    def voice_check(self, audio, exclude=None):
        self.excluded = exclude
        return VoiceCheck([(1.0, 9.0, "0"), (10.0, 60.0, "0")], self.verdict, "fake reason")

    def release(self):
        pass


def tracks(mic_only=False):
    mic = np.full(SR * 64, 0.01, np.float32)
    return {"mic": mic} if mic_only else {"mic": mic, "system": np.full(SR * 64, -0.01, np.float32)}


def run(verdict, mic_only=False, **cfg):
    d = FakeDiarizer(verdict)
    turns, methods, notes = diarize_tracks(tracks(mic_only), d, Config(**cfg), Reporter())
    return d, turns, methods, notes


def test_single_voice_skips_full_mic_diarization():
    d, turns, methods, notes = run(True)
    assert d.diarized == ["system"]
    assert methods == ["system=pyannote:fake", f"mic={SINGLE_VOICE}"]
    assert {t.speaker for t in turns if t.track == "mic"} == {"Me"}
    assert any("full diarization skipped" in n for n in notes)
    assert (3.95, 6.35) in d.excluded  # remote speech (dilated) is left out of the check


@pytest.mark.parametrize("verdict", [None, False])
def test_unsure_or_several_voices_give_the_same_output_as_without_the_check(verdict):
    d, *with_check = run(verdict)
    _, *without = run(verdict, mic_voice_check=False)
    assert d.diarized == ["system", "mic"]
    assert with_check == without
    mic_speakers = {t.speaker for t in with_check[0] if t.track == "mic"}
    assert len(mic_speakers) == 2  # in-person meeting: both local voices keep their own labels


def test_disabled_check_never_runs():
    d, *_ = run(True, mic_voice_check=False)
    assert d.diarized == ["system", "mic"] and d.excluded is None


def test_mic_speakers_me_skips_check_and_full_diarization():
    d, turns, methods, _ = run(None, mic_speakers="me")
    assert d.diarized == ["system"] and d.excluded is None
    assert methods[1] == f"mic={SINGLE_VOICE}"
    assert {t.speaker for t in turns if t.track == "mic"} <= {"Me"}


def test_mic_only_recording_uses_the_check_too():
    d, turns, methods, _ = run(True, mic_only=True)
    assert d.diarized == [] and d.excluded == []
    assert methods == [f"mic={SINGLE_VOICE}"] and {t.speaker for t in turns} == {"Me"}
