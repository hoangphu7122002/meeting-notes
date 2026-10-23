"""Pipeline bench harness (pipeline/bench): metrics, counter parsing, fixtures, safety guard."""

import json
import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "bench"))

from bench_metrics import (der, median_report, parse_swap_used_mb, parse_vm_stat, pressure_summary,  # noqa: E402
                           track_wer, vm_delta_mb)
from meeting_fixture import layout, make_fixture, script  # noqa: E402
from pipeline_bench import ensure_outside_user_notes, parse_sets, toml_text  # noqa: E402

from meeting_notes.domain.signal import SR  # noqa: E402

REF = [(0.0, 10.0, "Me"), (10.0, 20.0, "Remote 1"), (20.0, 30.0, "Me")]


def test_der_is_zero_for_a_relabelled_perfect_hypothesis():
    hyp = [(s, e, {"Me": "A", "Remote 1": "B"}[k]) for s, e, k in REF]
    assert der(REF, hyp)["der"] == 0.0


def test_der_counts_miss_false_alarm_and_confusion():
    hyp = [(0.0, 10.0, "A"), (10.0, 20.0, "A"), (30.0, 35.0, "B")]  # 2nd turn confused, 3rd missed, 5 s FA
    r = der(REF, hyp)
    assert r["confusion"] == pytest.approx(1 / 3, abs=0.01)
    assert r["miss"] == pytest.approx(1 / 3, abs=0.01)
    assert r["fa"] == pytest.approx(5 / 30, abs=0.01)
    assert r["der"] == pytest.approx(1 / 3 + 1 / 3 + 5 / 30, abs=0.01)


def test_der_collar_forgives_boundary_shifts():
    hyp = [(0.0, 10.2, "A"), (10.2, 20.0, "B"), (20.0, 30.0, "A")]
    assert der(REF, hyp)["der"] > 0 and der(REF, hyp, collar=0.25)["der"] == 0.0


def test_der_handles_overlapping_speech():
    ref = [(0.0, 10.0, "Me"), (5.0, 10.0, "Remote 1")]
    assert der(ref, [(0.0, 10.0, "A"), (5.0, 10.0, "B")])["der"] == 0.0
    assert der(ref, [(0.0, 10.0, "A")])["miss"] == pytest.approx(5 / 15, abs=0.01)


def test_track_wer():
    ref = [{"track": "mic", "start": 0, "text": "xin chào mọi người"}, {"track": "system", "start": 1, "text": "hello there"}]
    hyp = [{"track": "mic", "start": 0, "text": "Xin chào mọi người."}, {"track": "system", "start": 1, "text": "hello"}]
    assert track_wer(ref, hyp) == {"mic": 0.0, "system": 0.5, "all": round(1 / 6, 4)}


def test_counter_parsing():
    assert parse_swap_used_mb("total = 18432.00M  used = 17302.75M  free = 1129.25M  (encrypted)") == 17302.75
    assert parse_swap_used_mb("used = 1.50G") == 1536.0 and parse_swap_used_mb("") is None
    before = parse_vm_stat("Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPageins:   100.\nPageouts:  10.\n")
    after = {**before, "pageins": 164, "pageouts": 10}
    assert before == {"page_size": 16384, "pageins": 100, "pageouts": 10}
    assert vm_delta_mb(before, after) == {"pageins": 1.0, "pageouts": 0.0}


def test_pressure_summary_labels_the_worst_level():
    s = pressure_summary([1, 1, 2, 1, 0])
    assert s == {"start": "normal", "worst": "warn", "best": "normal", "samples": {"normal": 3, "warn": 1, "critical": 0}}
    assert pressure_summary([])["worst"] == "unknown"


def row(label, wall, cond="normal"):
    q = {"wer": {"all": 0.1}, "der": {"der": 0.05}, "der_collar": {"der": 0.02}}
    return {"label": label, "fixture": "f", "wall_sec": wall, "stages": {"diarize": wall / 2, "transcribe": wall / 3},
            "peak_rss_gb": 1.0, "swap_delta_mb": 5.0, "condition": cond, "quality": q, "mic_path": "skip"}


def test_median_report_groups_repeats():
    out = median_report([row("a", 10), row("a", 30), row("a", 20, "warn"), row("b", 5)])
    a = next(r for r in out if r["label"] == "a")
    assert a["runs"] == 3 and a["wall_sec"] == 20 and a["conditions"] == ["normal", "warn"]


def test_script_is_seeded_and_mixes_tracks():
    lines = script(200, remote=3, local=2, seed=4)
    assert lines == script(200, remote=3, local=2, seed=4)
    speakers = {(l.track, l.speaker) for l in lines}
    assert {("mic", "Me"), ("mic", "Local 2"), ("system", "Remote 3")} <= speakers
    assert all(l.language == "vi" for l in lines if l.speaker == "Me")


def test_layout_fills_minutes_without_same_track_overlap():
    lines = script(400, seed=1)
    placed = layout(lines, [3.0] * len(lines), minutes=10, seed=1)
    assert 590 <= placed[-1].start <= 610
    for track in ("mic", "system"):
        own = [p for p in placed if p.track == track]
        assert all(b.start >= a.end for a, b in zip(own, own[1:]))
    assert any(b.start < a.end for a, b in zip(placed, placed[1:]))  # some cross-track overlap


def test_make_fixture_writes_meeting_and_reference(tmp_path):
    def fake_tts(voice, text, tmp):
        return (0.3 * np.sin(np.arange(int(2.5 * SR)) * (0.05 + 0.01 * len(voice)))).astype(np.float32)

    folder = make_fixture(tmp_path, minutes=1, tts=fake_tts)
    meeting = json.loads((folder / "meeting.json").read_text())
    ref = json.loads((tmp_path / "reference.json").read_text())
    assert (folder / "mic.wav").exists() and (folder / "system.wav").exists()
    assert meeting["tracks"]["system"]["start_offset_sec"] > 0
    assert ref["segments"] and {s["track"] for s in ref["segments"]} == {"mic", "system"}
    assert (tmp_path / "reference.rttm").read_text().count("SPEAKER") == len(ref["segments"])


def test_refuses_user_recordings(tmp_path):
    ensure_outside_user_notes(tmp_path)
    with pytest.raises(SystemExit):
        ensure_outside_user_notes(Path("~/MeetingNotes/2026-10-01 0900 Weekly").expanduser())


def test_settings_overrides_are_toml_typed():
    sets = parse_sets(["mic_voice_check=false", "cpu_threads=4", "me_name=Phu"])
    assert sets == {"mic_voice_check": False, "cpu_threads": 4, "me_name": "Phu"}
    assert toml_text(sets) == 'mic_voice_check = false\ncpu_threads = 4\nme_name = "Phu"\n'



def test_queued_jobs_share_one_model_cache_built_from_keep_models_warm(monkeypatch):
    import pipeline_bench

    import meeting_notes.adapters.outbound.system_resources as res
    import meeting_notes.entrypoints.wiring as wiring
    from meeting_notes.config import Config

    seen, released = [], []

    class FakeModels:
        def release(self):
            released.append(True)

    class FakeProcessor:
        def __init__(self, folder, models):
            self.folder, self.models = folder, models

        def run(self, from_stage):
            seen.append((self.folder.name, self.models))

    monkeypatch.setattr(Config, "load", classmethod(lambda cls, path=None: Config(keep_models_warm=False)))
    monkeypatch.setattr(res, "apply_priority", lambda mode: True)
    monkeypatch.setattr(res, "limit_threads", lambda n: None)
    keeps = []
    monkeypatch.setattr(wiring, "make_models", lambda cfg, keep=False, log=print: keeps.append(keep) or FakeModels())
    monkeypatch.setattr(wiring, "make_reporter", lambda **kw: None)
    monkeypatch.setattr(wiring, "make_processor", lambda folder, cfg, rep, models: FakeProcessor(folder, models))
    walls = []
    assert pipeline_bench.queued_jobs(["/x/meeting", "/x/meeting-2"], walls) == 0
    assert [name for name, _ in seen] == ["meeting", "meeting-2"] and seen[0][1] is seen[1][1]
    assert keeps == [False] and len(walls) == 2 and released == [True]
