"""Stop-time reuse end to end on a fixture: `process` with live partials gives the transcript of the offline path."""

import json
import shutil

import pytest
from live_fakes import Events, PitchTranscriber, Probe, Stop, voice_track

from meeting_notes.adapters.outbound.audio_files import AudioFiles
from meeting_notes.adapters.outbound.live_wav_reader import LiveWavSource
from meeting_notes.adapters.outbound.meeting_folder import MeetingStore
from meeting_notes.adapters.outbound.model_cache import Models
from meeting_notes.adapters.outbound.partial_transcript_store import PartialTranscriptFile
from meeting_notes.adapters.outbound.progress_reporter import Reporter
from meeting_notes.adapters.outbound.wav_files import write_wav
from meeting_notes.application.live_transcribe import PARTIAL_FILE, LiveTranscription
from meeting_notes.application.process_meeting import Processor
from meeting_notes.application.processor_deps import ProcessorDeps
from meeting_notes.config import Config
from meeting_notes.domain.signal import energy_vad
from meeting_notes.domain.speakers import TrackDiarization
from meeting_notes.domain.voice_check import VoiceCheck


@pytest.fixture
def calls(monkeypatch):
    """Real Models with a VAD diarizer and the pitch transcriber; counts whisper calls of the offline pass."""
    counter = {"transcribe": 0}

    class Diarizer:
        def __init__(self, cfg, log=None):
            pass

        def diarize(self, audio, progress=None):
            return TrackDiarization([(s, e, "0") for s, e in energy_vad(audio)], "vad", [])

        def voice_check(self, audio, exclude=None):  # unsure: full diarization, as before
            return VoiceCheck([], None, "fake")

        def release(self):
            pass

    class Transcriber(PitchTranscriber):
        def __init__(self, cfg):
            super().__init__()

        def transcribe(self, audio, language):
            counter["transcribe"] += 1
            return super().transcribe(audio, language)

    import meeting_notes.adapters.outbound.mlx_transcriber as T
    import meeting_notes.adapters.outbound.pyannote_diarizer as D

    monkeypatch.setattr(D, "Diarizer", Diarizer)
    monkeypatch.setattr(T, "Transcriber", Transcriber)
    return counter


def deps(partials=PartialTranscriptFile):
    summary = {"title": "x", "summary": [], "decisions": [], "action_items": [], "open_questions": []}
    return ProcessorDeps(store=MeetingStore(), audio=AudioFiles(), make_models=lambda cfg, keep, log: Models(cfg, keep, log),
                         summarize=lambda *a, **k: dict(summary), preload=lambda cfg: None, partials=partials)


def make_meeting(path):
    path.mkdir()
    write_wav(path / "mic.wav", voice_track(40, [(1, 5), (13, 17), (26, 30)], 140))
    write_wav(path / "system.wav", voice_track(40, [(6, 10), (19, 23), (32, 36.5)], 230, seed=2))
    (path / "meeting.json").write_text(json.dumps({
        "version": 1, "title": "Meeting", "title_source": "user", "started_at": "2026-10-21T10:00:00+07:00",
        "tracks": {"mic": {"file": "mic.wav", "start_offset_sec": 0.0}, "system": {"file": "system.wav", "start_offset_sec": 0.0}}}))
    return path


def config():
    cfg = Config()
    cfg.rename_folder = False
    cfg.keep_wav = True
    return cfg


def lines(transcript):
    return [(s["speaker"], s["track"], s["text"]) for s in transcript["segments"]]


def test_process_with_partials_gives_the_offline_transcript(tmp_path, calls):
    live_dir = make_meeting(tmp_path / "live")
    offline_dir = tmp_path / "offline"
    shutil.copytree(live_dir, offline_dir)
    cfg = config()
    store = PartialTranscriptFile(live_dir / ".work" / PARTIAL_FILE)
    full = {t: (live_dir / f"{t}.wav").read_bytes() for t in ("mic", "system")}
    for t, data in full.items():  # Stop arrives at 31 s: the last utterances were never chunked live
        (live_dir / f"{t}.wav").write_bytes(data[: 44 + 31 * 16000 * 2])
    LiveTranscription(LiveWavSource(live_dir), store, Models(cfg), Probe(), Events(), cfg).run(Stop(after_waits=3))
    for t, data in full.items():
        (live_dir / f"{t}.wav").write_bytes(data)
    decoded = [c for c in store.load() if c["status"] == "decoded"]
    assert len(decoded) >= 3 and max(c["end"] for c in store.load()) < 31

    calls["transcribe"] = 0
    Processor(offline_dir, cfg, Reporter(), deps()).run()
    offline_calls, calls["transcribe"] = calls["transcribe"], 0
    Processor(live_dir, cfg, Reporter(), deps()).run()
    offline = json.loads((offline_dir / "transcript.json").read_text())
    reused = json.loads((live_dir / "transcript.json").read_text())

    assert lines(reused) == lines(offline) and len(lines(offline)) == 6
    assert [s["language"] for s in reused["segments"]] == [s["language"] for s in offline["segments"]]
    assert all(abs(a["start"] - b["start"]) < 1.0 for a, b in zip(reused["segments"], offline["segments"]))
    assert "live" not in offline and reused["live"]["reused_sec"] > 0 and reused["live"]["decoded_sec"] > 0
    assert 0 < calls["transcribe"] < offline_calls  # only the uncovered turns (the tail) were decoded after Stop
    assert reused["speakers"] == offline["speakers"] == ["Me", "Others"]


def test_force_and_stale_signature_ignore_partials(tmp_path, calls):
    folder = make_meeting(tmp_path / "m")
    cfg = config()
    store = PartialTranscriptFile(folder / ".work" / PARTIAL_FILE)
    LiveTranscription(LiveWavSource(folder), store, Models(cfg), Probe(), Events(), cfg).run(Stop(after_waits=3))
    Processor(folder, cfg, Reporter(), deps()).run("transcribe")  # --from transcribe: full offline pass
    assert "live" not in json.loads((folder / "transcript.json").read_text())
    cfg.glossary = ["Momos"]  # prompt changed after the live chunks were decoded
    Processor(folder, cfg, Reporter(), deps()).run("render")
    (folder / "transcript.json").unlink()
    Processor(folder, cfg, Reporter(), deps()).run()
    assert "live" not in json.loads((folder / "transcript.json").read_text())


def test_without_partials_output_is_byte_identical_and_finalize_removes_the_file(tmp_path, calls):
    a = make_meeting(tmp_path / "a")
    b = tmp_path / "b"
    shutil.copytree(a, b)
    Processor(a, config(), Reporter(), deps()).run()
    Processor(b, config(), Reporter(), deps(partials=None)).run()
    assert (a / "transcript.json").read_bytes() == (b / "transcript.json").read_bytes()
    assert (a / "notes.md").read_bytes() == (b / "notes.md").read_bytes()
    c = make_meeting(tmp_path / "c")
    cfg = Config()
    cfg.rename_folder = False
    PartialTranscriptFile(c / ".work" / PARTIAL_FILE).append({"track": "mic", "seq": 0, "start": 0, "end": 1})
    Processor(c, cfg, Reporter(), deps()).run()
    assert not (c / ".work" / PARTIAL_FILE).exists()  # finalize cleans up with the scratch audio
