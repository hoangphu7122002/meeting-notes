import numpy as np
from helpers import room
from live_fakes import Events, FakeModels, ListStore, Probe, Stop, StreamSource, voice_track

from meeting_notes.application.live_transcribe import LiveTranscription, live_signature
from meeting_notes.config import Config
from meeting_notes.domain.live_backlog import LoadSample

NORMAL = LoadSample(1, 0.1, 0, False)


def meeting(total=40.0):
    mic = voice_track(total, [(1, 5), (13, 17), (26, 30)], 140)
    system = voice_track(total, [(6, 10), (19, 23), (32, 36)], 230, seed=2)
    return {"mic": mic, "system": system}


def run(tracks, probe=None, store=None, cfg=None, step=1.0, stop=None):
    events, models, store = Events(), FakeModels(), store or ListStore()
    live = LiveTranscription(StreamSource(tracks, step), store, models, probe or Probe(NORMAL), events, cfg or Config())
    stats = live.run(stop or Stop())
    return live, stats, store, events, models


def test_decodes_chunks_at_pauses_and_announces_them():
    live, stats, store, events, models = run(meeting())
    decoded = [c for c in store.lines if c["status"] == "decoded"]
    assert {c["track"] for c in decoded} == {"mic", "system"} and stats["decoded"] == len(decoded) >= 4
    assert all(c["signature"] == live_signature(Config()) and not c["forced"] for c in decoded)
    assert all(s["text"] == "voice 140" for c in decoded if c["track"] == "mic" for s in c["segments"])
    assert {(e["speaker"], e["text"]) for e in events.segments} == {("Me", "voice 140"), ("Others", "voice 230")}
    assert [e["seq"] for e in events.segments if e["track"] == "mic"] == sorted({e["seq"] for e in events.segments if e["track"] == "mic"})
    assert any(c["status"] == "silent" for c in store.lines)  # pauses between turns are not sent to whisper
    assert models.tr.calls == len(decoded) and models.released == 0  # whisper stays warm for the Stop-time job
    assert events.status[-1]["state"] == "stopped"


def test_stop_finishes_current_chunk_and_leaves_the_rest_to_the_stop_pass():
    _, _, store, _, _ = run(meeting(), stop=Stop(after_waits=12))
    assert store.lines and max(c["end"] for c in store.lines) < 20


def test_defers_under_memory_pressure_and_skips_on_battery():
    _, stats, store, events, models = run(meeting(), probe=Probe(LoadSample(2, 0.1, 0, False)))  # replay ends anyway
    assert models.tr.calls == 0 and store.lines == [] and {"deferred"} <= {s["state"] for s in events.status}
    assert events.status[-2]["reason"] == "memory"
    _, stats, store, events, models = run(meeting(), probe=Probe(LoadSample(1, 0.1, 0, True)))
    assert models.tr.calls == 0 and {c["status"] for c in store.lines} == {"battery"} and stats["skipped_sec"] > 20
    assert any(s["state"] == "throttled" and s["reason"] == "battery" for s in events.status)


def test_backlog_beyond_limit_is_skipped_oldest_first():
    cfg = Config()
    cfg.live_max_backlog_sec = 10.0
    probe = Probe(*([LoadSample(2, 0.1, 0, False)] * 20 + [NORMAL]))  # 20 polls of pressure, then normal
    _, stats, store, _, _ = run(meeting(60), probe=probe, cfg=cfg)
    skipped = [c for c in store.lines if c["status"] == "backlog"]
    assert skipped and stats["skipped_sec"] > 0
    assert max(c["end"] for c in skipped) <= min(c["start"] for c in store.lines if c["status"] == "decoded") + 1e-6


def test_resume_after_crash_continues_after_last_line_and_reannounces():
    tracks = meeting()
    _, _, first, _, _ = run(tracks, stop=Stop(after_waits=14))
    done = {t: max(c["end"] for c in first.lines if c["track"] == t) for t in ("mic", "system") if any(c["track"] == t for c in first.lines)}
    _, _, store, events, _ = run(tracks, store=ListStore(first.lines))
    new = store.lines[len(first.lines):]
    assert new and all(c["start"] >= done.get(c["track"], 0) - 1e-6 for c in new)
    seqs = [(c["track"], c["seq"]) for c in store.lines]
    assert len(seqs) == len(set(seqs))  # seq keeps counting per track
    old = [(c["track"], c["seq"]) for c in first.lines if c["status"] == "decoded"]
    assert old and set(old) <= {(e["track"], e["seq"]) for e in events.segments}


def test_mic_chunk_that_only_echoes_the_speakers_is_not_decoded():
    system = voice_track(30, [(1, 5), (9, 13), (17, 21)], 230, seed=2)
    mic = (0.4 * system + room(30, seed=5)).astype(np.float32)
    _, stats, store, events, _ = run({"mic": mic, "system": system})
    assert stats["bleed"] >= 1 and not any(c["track"] == "mic" and c["status"] == "decoded" for c in store.lines)
    assert all(e["track"] == "system" for e in events.segments)
