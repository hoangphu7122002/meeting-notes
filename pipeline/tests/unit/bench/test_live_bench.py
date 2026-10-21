"""Chunk policy and partial-merge prototypes used by the live feasibility benches (pipeline/bench)."""

import sys
from pathlib import Path

import numpy as np
from helpers import tone

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "bench"))

from live_chunks import ChunkPolicy, cut_track  # noqa: E402
from live_eval import gate, language_agreement  # noqa: E402
from live_merge import clip_turns, merge_partials  # noqa: E402

from meeting_notes.domain.signal import SR  # noqa: E402
from meeting_notes.domain.speakers import Turn  # noqa: E402


def silence(sec):
    """Room tone, not digital zero: frame_db ignores frames below -90 dB when estimating the noise floor."""
    return (0.002 * np.random.default_rng(1).standard_normal(int(sec * SR))).astype(np.float32)


def continuous_speech(sec):
    """Amplitude-modulated tone: dips every 0.33 s, never a 0.7 s pause."""
    t = np.arange(int(sec * SR)) / SR
    return (tone(sec) * (0.01 + np.abs(np.sin(2 * np.pi * 1.5 * t)) ** 3)).astype(np.float32)


def test_cuts_in_first_pause_after_min_and_leaves_tail():
    audio = np.concatenate([silence(2.5), tone(5), silence(1.0), tone(6), silence(1.0), tone(2)])
    chunks = cut_track(audio, "mic")
    assert [c.forced for c in chunks] == [False, False, False]
    assert 7.5 < chunks[0].end < 8.5 and chunks[0].start == 0.0  # midway into the first pause after min_sec
    assert chunks[1].start == chunks[0].end and 14.5 < chunks[1].end < 15.5
    assert chunks[-1].tail and abs(chunks[-1].end - 17.5) < 0.05


def test_short_utterances_merge_until_min_chunk_length():
    audio = np.concatenate([silence(1.0), tone(1.5), silence(1.0), tone(1.5), silence(1.0), tone(1.5), silence(1.0), tone(1)])
    first = cut_track(audio, "mic")[0]
    assert first.end >= 4.0 and not first.forced  # no cut at the first two pauses (< min_sec)


def test_forced_cut_without_pause_at_max_sec():
    audio = continuous_speech(40)
    first = cut_track(audio, "mic", ChunkPolicy(max_sec=28.0))[0]
    assert first.forced and 16.8 <= first.end <= 28.0


def partial(track, start, end, segs, tail=False):
    return {"track": track, "start": start, "end": end, "tail": tail, "segments": segs}


def seg(track, start, end, text="x"):
    return {"track": track, "start": start, "end": end, "text": text, "language": "vi"}


def test_merge_assigns_max_overlap_speaker_and_flags_ambiguous():
    turns = [Turn(0, 3, "Speaker 1", "system"), Turn(3, 4.5, "Speaker 2", "system"), Turn(6, 10, "Speaker 2", "system")]
    parts = [partial("system", 0, 5, [seg("system", 0.2, 3.4), seg("system", 3.0, 4.6)]),
             partial("system", 5, 10, [seg("system", 6.0, 9.5)])]
    res = merge_partials(turns, parts)
    assert [s["speaker"] for s in res.segments] == ["Speaker 1", "Speaker 2", "Speaker 2"]
    assert res.segments[0]["speaker"] == "Speaker 1" and res.minority_sec > 0
    assert not res.ambiguous and res.uncovered["system"] == []
    amb = merge_partials(turns, [partial("system", 0, 5, [seg("system", 1.5, 4.5)])])
    assert len(amb.ambiguous) == 1 and (1.5, 4.5) in [tuple(x) for x in amb.uncovered["system"]]


def test_merge_drops_bleed_and_uncovers_tail():
    turns = [Turn(0, 2, "Me", "mic"), Turn(8, 12, "Me", "mic")]
    parts = [partial("mic", 0, 6, [seg("mic", 0.1, 1.9), seg("mic", 3.0, 5.0)]), partial("mic", 6, 14, [], tail=True)]
    res = merge_partials(turns, parts)
    assert len(res.segments) == 1 and len(res.dropped) == 1  # segment outside resolved mic turns = bleed
    assert res.uncovered["mic"] == [(8, 12)]
    assert [(t.start, t.end) for t in clip_turns(turns, res.uncovered)] == [(8, 12)]


def test_gate_and_language_agreement():
    turns = [Turn(0, 2, "Me", "mic")]
    segs = [seg("mic", 0, 2), seg("mic", 5, 6)]
    assert gate(segs, turns) == [segs[0]]
    ref = [{**seg("mic", 0, 2), "language": "en"}]
    assert language_agreement(ref, [segs[0]])["pct"] == 0.0


def test_strict_merge_redecodes_forced_and_multi_speaker_chunks():
    turns = [Turn(0, 3, "Speaker 1", "system"), Turn(3.2, 8, "Speaker 2", "system"), Turn(10, 14, "Speaker 1", "system")]
    multi = {**partial("system", 0, 9, [seg("system", 0.2, 4.0)]), "forced": False}
    forced = {**partial("system", 9, 15, [seg("system", 10.0, 14.0)]), "forced": True}
    loose = merge_partials(turns, [multi, forced])
    assert len(loose.segments) == 2 and loose.uncovered["system"] == []
    strict = merge_partials(turns, [multi, forced], strict=True)
    assert strict.segments == [] and strict.uncovered["system"] == [(0, 3), (3.2, 8), (10, 14)]  # whole chunks
