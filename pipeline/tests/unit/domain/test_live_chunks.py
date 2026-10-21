import numpy as np
from helpers import continuous, room, tone
from live_fakes import voice_track

from meeting_notes.domain.live_chunks import ChunkPolicy, LiveChunk, TrackChunker, mic_is_bleed, worth_decoding
from meeting_notes.domain.signal import SR


def feed_all(chunker, audio, step=1.0, offset=0.0):
    out, n = [], int(step * SR)
    for a in range(0, len(audio), n):
        out += chunker.feed(offset + a / SR, audio[a:a + n])
    return out


def test_cuts_in_first_pause_after_min_and_keeps_the_rest_open():
    audio = np.concatenate([room(2.5), tone(5), room(1.0), tone(6), room(1.0), tone(2)])
    ch = TrackChunker("mic")
    chunks = feed_all(ch, audio)
    assert [c.forced for c in chunks] == [False, False]
    assert chunks[0].start == 0.0 and 7.5 < chunks[0].end < 8.5  # midway into the first pause after min_sec
    assert chunks[1].start == chunks[0].end and 14.5 < chunks[1].end < 15.5
    assert [c.seq for c in chunks] == [0, 1]
    assert abs(ch.open_start - chunks[1].end) < 1e-9 and abs(ch.available_end - 17.5) < 0.01  # tail stays for Stop


def test_incremental_feeding_matches_one_big_feed_after_warmup():
    audio = voice_track(40, [(1, 5), (7, 12), (14, 20), (23, 30), (33, 36)], 140)
    small = [(c.start, c.end) for c in feed_all(TrackChunker("mic"), audio, step=0.5)]
    big = [(c.start, c.end) for c in feed_all(TrackChunker("mic", ChunkPolicy(refresh_sec=0.0)), audio, step=1.0)]
    assert small and len(small) == len(big)
    assert all(abs(a[0] - b[0]) < 0.5 and abs(a[1] - b[1]) < 0.5 for a, b in zip(small, big))


def test_forced_cut_at_max_length_without_pause():
    chunks = feed_all(TrackChunker("system"), np.concatenate([room(1), continuous(40)]))
    assert chunks[0].forced and 17 <= chunks[0].duration <= 28.0


def test_no_cut_decision_during_warmup_then_the_pause_is_used():
    audio = np.concatenate([room(2.0), tone(3.0), room(1.0), tone(3)])  # pause at 5-6 s, before the 8 s warm-up
    ch = TrackChunker("mic")
    assert feed_all(ch, audio[: 7 * SR]) == []
    chunks = feed_all(ch, np.concatenate([audio[7 * SR:], room(3)]), offset=7.0)
    assert chunks and chunks[0].start == 0.0 and 5.0 < chunks[0].end < 6.0  # decided after 8 s, cut in the pause


def test_resume_starts_after_decoded_chunks_and_offsets_map_to_recorded_time():
    audio = voice_track(30, [(1, 5), (8, 12), (15, 19), (22, 26)], 140)
    ch = TrackChunker("mic", start_at=13.0, seq=7)
    chunks = feed_all(ch, audio, offset=2.0)
    assert chunks[0].start >= 13.0 and chunks[0].seq == 7
    c = chunks[0]
    assert abs(c.audio_start - (c.start - 0.25)) < 1e-6
    assert len(c.audio) == int(round((c.end + 0.25 - c.audio_start) * SR))


def test_memory_stays_bounded_and_recent_audio_is_kept():
    policy = ChunkPolicy(history_sec=20)
    ch = TrackChunker("system", policy)
    feed_all(ch, voice_track(300, [(s, s + 4) for s in range(2, 295, 7)], 230), step=2.0)
    assert len(ch.buf) <= (20 + 28 + 2) * SR
    assert len(ch.db) == 300 * 50
    assert ch.recent(290, 295) is not None and ch.recent(10, 12) is None


def test_voiced_gate_and_mic_bleed():
    policy = ChunkPolicy()
    quiet = LiveChunk("mic", 0, 0.0, 5.0, False, room(5.5), -0.25, -50.0)
    speech = LiveChunk("mic", 0, 0.0, 5.0, False, voice_track(5.5, [(1, 4)], 140), -0.25, -50.0)
    assert not worth_decoding(quiet, policy) and worth_decoding(speech, policy)
    remote = voice_track(10, [(1, 4), (5, 9)], 230, seed=2)
    echo = (0.4 * remote + room(10, seed=3)).astype(np.float32)
    own = voice_track(10, [(0.5, 3.5)], 140, seed=4)
    assert mic_is_bleed(echo, remote, -50.0)
    assert not mic_is_bleed(own, remote, -50.0)
