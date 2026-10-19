import json

import numpy as np
import pytest

from meeting_notes import audio as A
from meeting_notes import pipeline as P
from meeting_notes.config import Config
from meeting_notes.events import Reporter
from meeting_notes.diarize import TrackDiarization
from meeting_notes.transcribe import Segment


def test_folder_naming():
    assert P.sanitize_title('Q4: plan / "launch"?') == "Q4 plan launch"
    assert P.folder_name("2026-10-19 1430 Meeting", None, "Sprint sync") == "2026-10-19 1430 Sprint sync"
    assert P.folder_name("odd", "2026-01-02T03:04:00+07:00", "X") == "2026-01-02 0304 X"


def tone(sec, amp=0.3, freq=220.0):
    t = np.arange(int(sec * A.SR)) / A.SR
    return (amp * np.sin(2 * np.pi * freq * t)).astype(np.float32)


@pytest.fixture
def meeting(tmp_path):
    folder = tmp_path / "2026-10-19 1430 Meeting"
    folder.mkdir()
    silence = np.zeros(A.SR * 2, dtype=np.float32)
    A.write_wav(folder / "mic.wav", np.concatenate([silence, tone(2), silence]))
    A.write_wav(folder / "system.wav", np.concatenate([tone(2, freq=330), silence, silence]))
    (folder / "meeting.json").write_text(json.dumps({
        "version": 1, "title": "Meeting", "title_source": "default", "started_at": "2026-10-19T14:30:00+07:00",
        "tracks": {"mic": {"file": "mic.wav", "start_offset_sec": 0.0}, "system": {"file": "system.wav", "start_offset_sec": 0.5}},
    }))
    return folder


@pytest.fixture
def stubs(monkeypatch):
    calls = {"transcribe": 0, "summarize": 0}

    class FakeDiarizer:
        def __init__(self, cfg, log=None):
            pass

        def diarize(self, audio, progress=None):
            regions = A.energy_vad(audio)
            return TrackDiarization([(s, e, "0") for s, e in regions], "vad", ["pyannote unavailable: gated"])

        def release(self):
            pass

    class FakeTranscriber:
        def __init__(self, cfg):
            pass

        def release(self):
            pass

    def fake_transcribe_blocks(blocks, tracks, transcriber, allowed, progress=None):
        calls["transcribe"] += 1
        return [Segment(b.start, b.end, b.speaker, b.track, "vi", f"câu của {b.speaker}") for b in blocks]

    def fake_summarize(lines, language, cfg, progress=None):
        calls["summarize"] += 1
        return {"title": "Kế hoạch ra mắt", "summary": ["a"], "decisions": ["b"], "action_items": [], "open_questions": []}

    import meeting_notes.diarize as D
    import meeting_notes.summarize as S
    import meeting_notes.transcribe as T

    monkeypatch.setattr(D, "Diarizer", FakeDiarizer)
    monkeypatch.setattr(T, "Transcriber", FakeTranscriber)
    monkeypatch.setattr(T, "transcribe_blocks", fake_transcribe_blocks)
    monkeypatch.setattr(S, "summarize", fake_summarize)
    return calls


def test_full_run_aligns_labels_renames_and_resumes(meeting, stubs, tmp_path, capsys):
    cfg = Config()
    final = P.Processor(meeting, cfg, Reporter(json_mode=True)).run()
    assert final.name == "2026-10-19 1430 Kế hoạch ra mắt"
    assert not meeting.exists()
    transcript = json.loads((final / "transcript.json").read_text())
    speakers = [(s["speaker"], round(s["start"])) for s in transcript["segments"]]
    assert speakers[0][0] == "Others" and speakers[0][1] == 0  # system starts at 0.5 s offset
    assert ("Me", 2) in speakers
    assert transcript["speakers"] == ["Me", "Others"]
    notes = (final / "notes.md").read_text()
    assert notes.startswith("# Kế hoạch ra mắt") and "] Me:** câu của Me" in notes
    # Raw WAVs replaced by aligned m4a copies.
    assert not (final / "mic.wav").exists() and (final / "mic.m4a").exists() and (final / "mixed.m4a").exists()
    status = json.loads((final / "status.json").read_text())
    assert status["state"] == "done" and any("pyannote" in w for w in status["warnings"])
    events = [json.loads(line) for line in capsys.readouterr().out.splitlines()]
    assert events[-1]["event"] == "done" and events[-1]["folder"] == str(final)
    assert all(0 <= e.get("overall", 0) <= 1 for e in events)

    # Resume: nothing to redo.
    P.Processor(final, cfg, Reporter()).run()
    assert stubs == {"transcribe": 1, "summarize": 1}
    # Re-run from transcribe re-decodes the (now m4a) audio and redoes later stages.
    P.Processor(final, cfg, Reporter()).run("transcribe")
    assert stubs == {"transcribe": 2, "summarize": 2}
    again = json.loads((final / "transcript.json").read_text())
    assert [s["speaker"] for s in again["segments"]] == [s["speaker"] for s in transcript["segments"]]


def test_summary_failure_still_renders(meeting, stubs, monkeypatch):
    import meeting_notes.summarize as S

    def boom(*a, **k):
        raise S.OllamaError("Ollama is not reachable")

    monkeypatch.setattr(S, "summarize", boom)
    final = P.Processor(meeting, Config(), Reporter()).run()
    assert final == meeting.resolve()  # no LLM title -> not renamed
    assert "Chưa có tóm tắt" in (final / "notes.md").read_text()
    status = json.loads((final / "status.json").read_text())
    assert status["state"] == "done" and any("Summary failed" in w for w in status["warnings"])


def test_failure_writes_status(tmp_path):
    folder = tmp_path / "empty"
    folder.mkdir()
    with pytest.raises(P.PipelineError):
        P.Processor(folder, Config(), Reporter()).run()
    assert json.loads((folder / "status.json").read_text())["state"] == "failed"


def test_import_audio(tmp_path):
    src = tmp_path / "call.wav"
    A.write_wav(src, tone(1))
    folder = P.import_audio(src, tmp_path / "notes", "Weekly sync")
    meeting = json.loads((folder / "meeting.json").read_text())
    assert folder.name.endswith("Weekly sync") and meeting["title_source"] == "user"
    assert (folder / "source.wav").exists() and src.exists()


def test_mic_only_meeting_is_me(tmp_path, stubs):
    folder = tmp_path / "2026-10-19 1500 Meeting"
    folder.mkdir()
    A.write_wav(folder / "mic.wav", np.concatenate([np.zeros(A.SR), tone(2), np.zeros(A.SR)]))
    (folder / "meeting.json").write_text(json.dumps({"title": "Meeting", "title_source": "user",
                                                    "tracks": {"mic": {"file": "mic.wav", "start_offset_sec": 0.3}}}))
    final = P.Processor(folder, Config(), Reporter()).run()
    assert final == folder.resolve()  # user title -> folder kept
    transcript = json.loads((final / "transcript.json").read_text())
    assert {s["speaker"] for s in transcript["segments"]} == {"Me"}
    assert abs(transcript["segments"][0]["start"] - 1.2) < 0.2
