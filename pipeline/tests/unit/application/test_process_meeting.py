import json

import numpy as np
import pytest
from helpers import tone

from meeting_notes.adapters.outbound.meeting_folder import MeetingStore
from meeting_notes.adapters.outbound.progress_reporter import Reporter
from meeting_notes.adapters.outbound.wav_files import write_wav
from meeting_notes.application.errors import OllamaError, PipelineError
from meeting_notes.application.import_audio import import_audio
from meeting_notes.application.process_meeting import Processor
from meeting_notes.config import Config
from meeting_notes.domain.meeting_naming import folder_name, sanitize_title
from meeting_notes.domain.signal import SR


def test_folder_naming():
    assert sanitize_title('Q4: plan / "launch"?') == "Q4 plan launch"
    assert folder_name("2026-10-19 1430 Meeting", None, "Sprint sync") == "2026-10-19 1430 Sprint sync"
    assert folder_name("odd", "2026-01-02T03:04:00+07:00", "X") == "2026-01-02 0304 X"


def test_full_run_aligns_labels_renames_and_resumes(meeting, stubs, deps, tmp_path, capsys):
    cfg = Config()
    final = Processor(meeting, cfg, Reporter(json_mode=True), deps).run()
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
    Processor(final, cfg, Reporter(), deps).run()
    assert stubs == {"transcribe": 1, "summarize": 1}
    # Re-run from transcribe re-decodes the (now m4a) audio and redoes later stages.
    Processor(final, cfg, Reporter(), deps).run("transcribe")
    assert stubs == {"transcribe": 2, "summarize": 2}
    again = json.loads((final / "transcript.json").read_text())
    assert [s["speaker"] for s in again["segments"]] == [s["speaker"] for s in transcript["segments"]]


def test_summary_failure_still_renders(meeting, deps):
    def boom(*a, **k):
        raise OllamaError("Ollama is not reachable")

    deps.summarize = boom
    final = Processor(meeting, Config(), Reporter(), deps).run()
    assert final == meeting.resolve()  # no LLM title -> not renamed
    assert "Chưa có tóm tắt" in (final / "notes.md").read_text()
    status = json.loads((final / "status.json").read_text())
    assert status["state"] == "done" and any("Summary failed" in w for w in status["warnings"])


def test_failure_writes_status(tmp_path, deps):
    folder = tmp_path / "empty"
    folder.mkdir()
    with pytest.raises(PipelineError):
        Processor(folder, Config(), Reporter(), deps).run()
    assert json.loads((folder / "status.json").read_text())["state"] == "failed"


def test_import_audio(tmp_path):
    src = tmp_path / "call.wav"
    write_wav(src, tone(1))
    folder = import_audio(src, tmp_path / "notes", "Weekly sync", store=MeetingStore())
    meeting = json.loads((folder / "meeting.json").read_text())
    assert folder.name.endswith("Weekly sync") and meeting["title_source"] == "user"
    assert (folder / "source.wav").exists() and src.exists()


def test_mic_only_meeting_is_me(tmp_path, stubs, deps):
    folder = tmp_path / "2026-10-19 1500 Meeting"
    folder.mkdir()
    write_wav(folder / "mic.wav", np.concatenate([np.zeros(SR), tone(2), np.zeros(SR)]))
    (folder / "meeting.json").write_text(json.dumps({"title": "Meeting", "title_source": "user",
                                                    "tracks": {"mic": {"file": "mic.wav", "start_offset_sec": 0.3}}}))
    final = Processor(folder, Config(), Reporter(), deps).run()
    assert final == folder.resolve()  # user title -> folder kept
    transcript = json.loads((final / "transcript.json").read_text())
    assert {s["speaker"] for s in transcript["segments"]} == {"Me"}
    assert abs(transcript["segments"][0]["start"] - 1.2) < 0.2


def test_pauses_are_rendered_and_timestamps_follow_recorded_time(meeting, stubs, deps):
    meta = json.loads((meeting / "meeting.json").read_text())
    # The app drops audio while paused, so files hold recorded time only; pauses are metadata.
    meta["pauses"] = [{"at_sec": 1.5, "duration_sec": 125.0, "started_at": "2026-10-19T14:30:01+07:00"}]
    (meeting / "meeting.json").write_text(json.dumps(meta))
    final = Processor(meeting, Config(), Reporter(), deps).run()
    transcript = json.loads((final / "transcript.json").read_text())
    assert transcript["pauses"][0]["at_sec"] == 1.5
    assert transcript["duration_sec"] < 10  # paused wall time is not part of the timeline
    notes = (final / "notes.md").read_text()
    marker = notes.index("tạm dừng ghi âm (2 min)")
    assert notes.index("] Others:**") < marker < notes.index("] Me:**")


def test_user_title_renames_folder_and_is_kept(meeting, stubs, deps):
    meta = json.loads((meeting / "meeting.json").read_text())
    meta.update(title="Weekly sync", title_source="user")
    (meeting / "meeting.json").write_text(json.dumps(meta))
    final = Processor(meeting, Config(), Reporter(), deps).run()
    assert final.name == "2026-10-19 1430 Weekly sync"
    assert (final / "notes.md").read_text().startswith("# Weekly sync")


def test_partial_notes_event_before_summary(meeting, stubs, deps, capsys):
    Processor(meeting, Config(), Reporter(json_mode=True), deps).run()
    events = [json.loads(line) for line in capsys.readouterr().out.splitlines()]
    kinds = [(e["event"], e.get("stage"), e.get("status")) for e in events]
    partial = kinds.index(("partial", None, None))
    assert kinds.index(("stage", "transcribe", "done")) < partial < kinds.index(("stage", "summarize", "start"))
    done = events[-1]
    assert set(done["timings"]) >= {"diarize", "transcribe", "summarize"}
    assert all("eta_sec" in e for e in events if e["event"] == "progress")


def test_cancel_marks_status(meeting, stubs, deps):
    import threading

    from meeting_notes.application.errors import Cancelled

    cancel = threading.Event()
    cancel.set()
    with pytest.raises(Cancelled):
        Processor(meeting, Config(), Reporter(cancel=cancel), deps).run()
    assert json.loads((meeting / "status.json").read_text())["state"] == "cancelled"


def test_summary_model_unloaded_at_job_start_unless_preloading(meeting, stubs, deps):
    calls = []
    deps.free_llm = lambda cfg: calls.append(cfg.ollama_model) or True
    final = Processor(meeting, Config(ollama_preload=True), Reporter(json_mode=True), deps).run()
    assert calls == []  # preload wants the model resident
    final = Processor(final, Config(), Reporter(json_mode=True), deps).run("render")
    assert calls == ["qwen3:4b"]
    assert "unloaded qwen3:4b from Ollama (memory pressure)" in (final / "pipeline.log").read_text()
