from meeting_notes.domain.partial_merge import (PARTIAL_VERSION, clip_turns, config_signature, merge_partials,
                                                 usable_partials)
from meeting_notes.domain.speakers import Turn


def chunk(track, start, end, segments, forced=False, seq=0, status="decoded", signature="s"):
    return {"v": PARTIAL_VERSION, "track": track, "seq": seq, "start": start, "end": end, "status": status,
            "forced": forced, "language": "vi", "signature": signature,
            "segments": [{"start": s, "end": e, "text": t} for s, e, t in segments]}


def test_reuses_clean_chunk_with_diarization_speaker_and_leaves_tail():
    turns = [Turn(1, 5, "Speaker 1", "system"), Turn(12, 16, "Speaker 1", "system")]
    res = merge_partials(turns, [chunk("system", 0, 8, [(1, 5, "xin chào")])])
    assert [(s.speaker, s.text, s.track) for s in res.segments] == [("Speaker 1", "xin chào", "system")]
    assert res.uncovered == {"system": [(12, 16)]}
    assert (res.reused_sec, res.decoded_sec, res.rejected) == (4, 4, 0)


def test_strict_rule_redecodes_forced_and_two_speaker_chunks():
    turns = [Turn(0, 6, "Speaker 1", "system"), Turn(6, 7.5, "Speaker 2", "system"), Turn(10, 14, "Speaker 1", "system")]
    two = chunk("system", 0, 8, [(0, 7.5, "both")])  # Speaker 2 has 1.5 s >= 1 s: whole chunk re-decoded
    forced = chunk("system", 8, 20, [(10, 14, "x")], forced=True, seq=1)
    res = merge_partials(turns, [two, forced])
    assert res.segments == [] and res.rejected == 2
    assert res.uncovered["system"] == [(0, 7.5), (10, 14)]
    assert clip_turns(turns, res.uncovered) == turns


def test_minority_speaker_segment_rejects_the_chunk_but_short_overlap_does_not():
    turns = [Turn(0, 3.2, "A", "system"), Turn(3.2, 4.0, "B", "system")]  # B 0.8 s < 1 s, but 0.8/4 = 20 %
    assert len(merge_partials(turns, [chunk("system", 0, 5, [(0, 4, "t")])]).segments) == 1
    turns = [Turn(0, 1.0, "A", "system"), Turn(1.0, 1.9, "B", "system")]  # B is 47 % of the segment
    res = merge_partials(turns, [chunk("system", 0, 5, [(0, 1.9, "t")])])
    assert res.segments == [] and res.uncovered["system"] == [(0, 1.9)]


def test_mic_bleed_segments_outside_turns_are_dropped_not_redecoded():
    turns = [Turn(1, 4, "Me", "mic")]
    res = merge_partials(turns, [chunk("mic", 0, 9, [(1, 4, "của tôi"), (5, 8, "tiếng loa")])])
    assert [s.text for s in res.segments] == ["của tôi"] and res.uncovered["mic"] == []


def test_only_decoded_lines_with_matching_signature_and_version_are_used():
    lines = [chunk("mic", 0, 5, [], status="silent"), chunk("mic", 5, 9, [], signature="old"), chunk("mic", 9, 14, []),
             {**chunk("mic", 14, 18, []), "v": 99}]
    assert [c["start"] for c in usable_partials(lines, "s")] == [9]
    turns = [Turn(1, 3, "Me", "mic"), Turn(6, 8, "Me", "mic"), Turn(10, 12, "Me", "mic")]
    res = merge_partials(turns, usable_partials(lines, "s"))
    assert res.uncovered["mic"] == [(1, 3), (6, 8)]  # silent and stale chunks are decoded offline


def test_signature_is_stable_and_order_independent():
    a = config_signature({"model": "m", "languages": ["vi", "en"], "vad": True})
    assert a == config_signature({"vad": True, "languages": ["vi", "en"], "model": "m"})
    assert a != config_signature({"model": "m", "languages": ["vi"], "vad": True}) and len(a) == 16
