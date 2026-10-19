from meeting_notes.speakers import Turn, build_blocks, rename_clusters, resolve_single_track, resolve_two_tracks, speaker_order


def test_rename_clusters_in_order_of_appearance():
    assert rename_clusters([(5, 6, "B"), (0, 1, "A"), (7, 8, "A")]) == {"A": "Speaker 1", "B": "Speaker 2"}


def test_two_tracks_me_and_remote_speakers():
    system = [(0, 5, "x"), (12, 15, "y")]
    mic = [(6, 11, "m")]
    turns = resolve_two_tracks(mic, system, bleed=False)
    assert [(t.speaker, t.track) for t in turns] == [("Speaker 1", "system"), ("Me", "mic"), ("Speaker 2", "system")]


def test_bleed_removes_mic_echo_of_remote_speech():
    system = [(0, 5, "x")]
    mic = [(0.1, 5.2, "m"), (6, 9, "m")]
    turns = resolve_two_tracks(mic, system, bleed=True)
    mic_turns = [t for t in turns if t.track == "mic"]
    assert len(mic_turns) == 1 and mic_turns[0].start >= 5.3


def test_without_bleed_overlapping_mic_speech_is_kept():
    turns = resolve_two_tracks([(1, 4, "m")], [(0, 5, "x")], bleed=False)
    assert any(t.speaker == "Me" for t in turns)


def test_in_person_meeting_gets_several_mic_speakers():
    mic = [(0, 30, "a"), (31, 60, "b"), (61, 70, "a")]
    turns = resolve_two_tracks(mic, [], bleed=False, mic_speakers="auto")
    assert {t.speaker for t in turns} == {"Speaker 1", "Speaker 2"}
    turns = resolve_two_tracks(mic, [], bleed=False, mic_speakers="me")
    assert {t.speaker for t in turns} == {"Me"}


def test_small_mic_cluster_is_absorbed_into_me():
    mic = [(0, 60, "a"), (61, 63, "b")]
    turns = resolve_two_tracks(mic, [], bleed=False)
    assert {t.speaker for t in turns} == {"Me"}


def test_others_label_when_remote_not_clustered():
    turns = resolve_two_tracks([(6, 8, "m")], [(0, 5, "0")], bleed=False, others_label="Others")
    assert [t.speaker for t in turns] == ["Others", "Me"]


def test_build_blocks_merges_and_splits():
    turns = [
        Turn(0, 3, "A", "system"), Turn(3.5, 6, "A", "system"),  # merged (gap 0.5)
        Turn(6.2, 9, "B", "mic"),                                 # interrupts A
        Turn(9.2, 12, "A", "system"),                             # new block for A
        Turn(15, 16, "A", "system"),                              # gap 3 s -> new block
    ]
    blocks = build_blocks(turns)
    assert [(b.speaker, b.start, b.end) for b in blocks] == [("A", 0, 6), ("B", 6.2, 9), ("A", 9.2, 12), ("A", 15, 16)]


def test_build_blocks_respects_max_len():
    turns = [Turn(i * 10, i * 10 + 9.5, "A", "mixed") for i in range(6)]
    blocks = build_blocks(turns, max_len=40)
    assert all(b.duration <= 40 for b in blocks) and len(blocks) == 2


def test_short_interjection_does_not_split_block():
    turns = [Turn(0, 5, "A", "system"), Turn(5.1, 5.5, "Me", "mic"), Turn(5.6, 9, "A", "system")]
    blocks = build_blocks(turns)
    assert ("A", 0, 9) in [(b.speaker, b.start, b.end) for b in blocks]


def test_single_track_and_order():
    turns = resolve_single_track([(0, 1, "s1"), (2, 3, "s0")], "mixed")
    assert [t.speaker for t in turns] == ["Speaker 1", "Speaker 2"]
    assert speaker_order([Turn(0, 1, "Speaker 1", "system"), Turn(2, 3, "Me", "mic")]) == ["Me", "Speaker 1"]
