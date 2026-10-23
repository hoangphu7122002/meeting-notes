"""Diarization-only bench (pipeline/bench/diar_bench.py): scoring, speaker counts, track alignment, report."""

import json
import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "bench"))

from diar_bench import load_tracks, report, score, speaker_counts, summarize  # noqa: E402

from meeting_notes.adapters.outbound.wav_files import write_wav  # noqa: E402
from meeting_notes.domain.signal import SR  # noqa: E402

REF = {"segments": [
    {"track": "mic", "speaker": "Me", "start": 0.0, "end": 10.0},
    {"track": "system", "speaker": "Remote 1", "start": 10.0, "end": 20.0},
    {"track": "system", "speaker": "Remote 2", "start": 20.0, "end": 30.0},
]}


def turn(track, speaker, start, end):
    return {"track": track, "speaker": speaker, "start": start, "end": end}


def test_perfect_relabelled_hypothesis_scores_zero():
    hyp = [turn("mic", "Me", 0, 10), turn("system", "Speaker 1", 10, 20), turn("system", "Speaker 2", 20, 30)]
    q = score(REF, hyp)
    assert q["der"]["der"] == 0.0 and q["der_system"] == 0.0 and q["der_mic"] == 0.0
    assert q["speakers"]["all"] == {"ref": 3, "hyp": 3, "error": 0}


def test_merged_remote_speakers_show_as_confusion_and_count_error():
    hyp = [turn("mic", "Me", 0, 10), turn("system", "Speaker 1", 10, 30)]
    q = score(REF, hyp)
    assert q["der"]["confusion"] == pytest.approx(1 / 3, abs=0.01)
    assert q["der_system"] == pytest.approx(0.5, abs=0.01) and q["der_mic"] == 0.0
    assert q["speakers"]["system"] == {"ref": 2, "hyp": 1, "error": -1}


def test_speaker_counts_per_track():
    hyp = [turn("mic", "Me", 0, 5), turn("mic", "Speaker 9", 5, 10), turn("system", "Speaker 1", 10, 30)]
    c = speaker_counts(REF["segments"], hyp)
    assert c["mic"]["error"] == 1 and c["system"]["error"] == -1 and c["all"]["error"] == 0


def row(label, load, diarize, cond="warn", err=0):
    q = {"der": {"der": 0.05}, "der_collar": {"der": 0.01}, "der_system": 0.06, "der_mic": 0.03,
         "speakers": {"all": {"error": err}}}
    return {"label": label, "fixture": "f", "load_sec": load, "diarize_sec": diarize, "audio_sec": 600.0,
            "peak_rss_gb": 1.0, "swap_delta_mb": 10.0, "condition": cond, "quality": q, "methods": ["system=x"]}


def test_summarize_takes_medians_and_keeps_conditions_and_count_errors():
    out = summarize([row("a", 1, 10), row("a", 3, 30, "normal", 1), row("b", 1, 5)])
    a = next(r for r in out if r["label"] == "a")
    assert a["runs"] == 2 and a["total_sec"] == 22.0 and a["diarize_sec"] == 20.0
    assert a["rtf"] == pytest.approx(20 / 600, abs=1e-3)
    assert a["conditions"] == ["normal", "warn"] and a["spk_err"] == [0, 1]


def test_report_reads_results_of_several_fixtures(tmp_path, capsys):
    for name in ("one", "two"):
        (tmp_path / name).mkdir()
        r = {**row("a", 1, 10), "fixture": name}
        (tmp_path / name / "diar_results.jsonl").write_text(json.dumps(r) + "\n")
    report([tmp_path / "one", tmp_path / "two", tmp_path / "missing"])
    lines = capsys.readouterr().out.splitlines()
    assert lines[0].startswith("| label | fixture") and len(lines) == 4


def test_tracks_are_aligned_by_start_offset(tmp_path):
    meeting = tmp_path / "meeting"
    meeting.mkdir()
    write_wav(meeting / "mic.wav", np.full(SR, 0.1, np.float32))
    write_wav(meeting / "system.wav", np.full(SR, 0.2, np.float32))
    (meeting / "meeting.json").write_text(json.dumps({"tracks": {
        "mic": {"file": "mic.wav", "start_offset_sec": 0.0}, "system": {"file": "system.wav", "start_offset_sec": 0.5}}}))
    tracks, sec = load_tracks(meeting)
    assert sec == pytest.approx(1.5) and len(tracks["mic"]) == len(tracks["system"]) == int(1.5 * SR)
    assert abs(tracks["system"][: SR // 2]).max() == 0.0 and tracks["system"][SR] == pytest.approx(0.2, abs=1e-3)
