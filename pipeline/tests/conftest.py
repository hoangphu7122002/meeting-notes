import json
import os

os.environ["PYANNOTE_METRICS_ENABLED"] = "false"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"

import numpy as np  # noqa: E402
import pytest  # noqa: E402
from helpers import tone  # noqa: E402

from meeting_notes.adapters.outbound.audio_files import AudioFiles  # noqa: E402
from meeting_notes.adapters.outbound.meeting_folder import MeetingStore  # noqa: E402
from meeting_notes.adapters.outbound.wav_files import write_wav  # noqa: E402
from meeting_notes.application.processor_deps import ProcessorDeps  # noqa: E402
from meeting_notes.domain.segments import Segment  # noqa: E402
from meeting_notes.domain.signal import SR, energy_vad  # noqa: E402
from meeting_notes.domain.speakers import TrackDiarization  # noqa: E402
from meeting_notes.domain.voice_check import VoiceCheck  # noqa: E402


@pytest.fixture
def meeting(tmp_path):
    folder = tmp_path / "2026-10-19 1430 Meeting"
    folder.mkdir()
    silence = np.zeros(SR * 2, dtype=np.float32)
    write_wav(folder / "mic.wav", np.concatenate([silence, tone(2), silence]))
    write_wav(folder / "system.wav", np.concatenate([tone(2, freq=330), silence, silence]))
    (folder / "meeting.json").write_text(json.dumps({
        "version": 1, "title": "Meeting", "title_source": "default", "started_at": "2026-10-19T14:30:00+07:00",
        "tracks": {"mic": {"file": "mic.wav", "start_offset_sec": 0.0}, "system": {"file": "system.wav", "start_offset_sec": 0.5}},
    }))
    return folder


@pytest.fixture
def stubs(monkeypatch):
    """Fake diarizer/transcriber classes behind the real Models; the dict counts transcribe/summarize calls."""
    calls = {"transcribe": 0, "summarize": 0}

    class FakeDiarizer:
        def __init__(self, cfg, log=None):
            pass

        def diarize(self, audio, progress=None):
            regions = energy_vad(audio)
            return TrackDiarization([(s, e, "0") for s, e in regions], "vad", ["pyannote unavailable: gated"])

        def voice_check(self, audio, exclude=None):  # unsure: full diarization, as before
            return VoiceCheck([], None, "fake")

        def release(self):
            pass

    class FakeTranscriber:
        def __init__(self, cfg):
            pass

        def release(self):
            pass

    import meeting_notes.adapters.outbound.mlx_transcriber as T
    import meeting_notes.adapters.outbound.pyannote_diarizer as D

    monkeypatch.setattr(D, "Diarizer", FakeDiarizer)
    monkeypatch.setattr(T, "Transcriber", FakeTranscriber)
    return calls


@pytest.fixture
def deps(stubs):
    """Processor dependencies: real folder store, audio files and models; fake transcription and summary."""
    from meeting_notes.adapters.outbound.model_cache import Models

    def fake_transcribe_blocks(blocks, tracks, transcriber, allowed, progress=None, **kw):
        stubs["transcribe"] += 1
        return [Segment(b.start, b.end, b.speaker, b.track, "vi", f"câu của {b.speaker}") for b in blocks]

    def fake_summarize(lines, language, cfg, progress=None, **kw):
        stubs["summarize"] += 1
        return {"title": "Kế hoạch ra mắt", "summary": ["a"], "decisions": ["b"], "action_items": [], "open_questions": []}

    return ProcessorDeps(store=MeetingStore(), audio=AudioFiles(),
                         make_models=lambda cfg, keep, log: Models(cfg, keep=keep, log=log),
                         summarize=fake_summarize, preload=lambda cfg: None,
                         transcribe_blocks=fake_transcribe_blocks)
