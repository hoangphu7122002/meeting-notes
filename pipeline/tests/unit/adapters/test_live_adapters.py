import json
import struct

import numpy as np
from helpers import room, tone
from scipy.signal import resample_poly

from meeting_notes.adapters.outbound.live_replay_source import ReplaySource
from meeting_notes.adapters.outbound.live_wav_reader import LiveWavSource, WavTail
from meeting_notes.adapters.outbound.load_probe import SystemLoadProbe
from meeting_notes.adapters.outbound.partial_transcript_store import PartialTranscriptFile
from meeting_notes.domain.live_backlog import LoadSample
from meeting_notes.domain.signal import SR


def wav_header(rate, fllr=True, extensible=False):
    """What AVAudioFile leaves on disk while recording: stale sizes, optional FLLR padding before data."""
    if extensible:
        fmt = struct.pack("<HHIIHHHHIH14s", 0xFFFE, 1, rate, rate * 2, 2, 16, 22, 16, 4, 1, b"\x00" * 14)
    else:
        fmt = struct.pack("<HHIIHH", 1, 1, rate, rate * 2, 2, 16)
    out = b"RIFF" + struct.pack("<I", 0) + b"WAVE" + b"fmt " + struct.pack("<I", len(fmt)) + fmt
    if fllr:
        out += b"FLLR" + struct.pack("<I", 4042) + b"\x00" * 4042
    return out + b"data" + struct.pack("<I", 0)


def pcm(x):
    return (np.clip(x, -1, 1) * 32767).astype("<i2").tobytes()


def test_tail_reads_growing_file_with_fllr_and_stale_header_and_resamples_like_one_pass(tmp_path):
    rate = 48000
    x = np.concatenate([room(1.0, seed=3)[: SR], tone(2, freq=300)]).astype(np.float32)
    src = resample_poly(x, 3, 1).astype(np.float32)  # the 48 kHz "recording"
    path = tmp_path / "mic.wav"
    path.write_bytes(wav_header(rate)[:30])  # header still being written
    tail = WavTail(path)
    assert tail.read(10).size == 0
    path.write_bytes(wav_header(rate))
    raw = pcm(src)
    out = []
    for a in range(0, len(raw), 7777):  # odd sizes: half frames at EOF must wait
        with path.open("ab") as f:
            f.write(raw[a:a + 7777])
        out.append(tail.read(0.5))
        out.append(tail.read(0.5))
    out.append(tail.read(10, final=True))
    got = np.concatenate(out)
    ref = resample_poly(np.frombuffer(raw, "<i2").astype(np.float32) / 32768, 1, 3).astype(np.float32)
    assert len(got) == len(ref)
    assert np.max(np.abs(got - ref)) < 1e-4


def test_tail_handles_44k_extensible_and_16k(tmp_path):
    for rate, ext in [(44100, True), (16000, False)]:
        path = tmp_path / f"{rate}.wav"
        sig = tone(3, sr=rate, freq=200)
        path.write_bytes(wav_header(rate, fllr=False, extensible=ext) + pcm(sig))
        tail = WavTail(path)
        got = np.concatenate([tail.read(1.0) for _ in range(5)] + [tail.read(1.0, final=True)])
        assert abs(len(got) - 3 * SR) <= 2 and tail.rate == rate


def test_live_source_maps_file_position_to_recorded_time(tmp_path):
    folder = tmp_path / "m"
    folder.mkdir()
    source = LiveWavSource(folder)
    assert source.tracks() == []  # meeting.json is written ~3 s after the start
    (folder / "meeting.json").write_text(json.dumps({"tracks": {"mic": {"file": "mic.wav", "start_offset_sec": 0.0},
                                                                 "system": {"file": "system.wav", "start_offset_sec": 1.5}}}))
    (folder / "mic.wav").write_bytes(wav_header(SR) + pcm(tone(2)))
    (folder / "system.wav").write_bytes(wav_header(SR) + pcm(tone(1)))
    assert source.tracks() == ["mic", "system"]
    start, x = source.poll("system", 30)
    assert start == 1.5 and len(x) == SR and abs(source.position("system") - 2.5) < 1e-6
    with (folder / "system.wav").open("ab") as f:
        f.write(pcm(tone(1)))
    start, x = source.poll("system", 30)
    assert abs(start - 2.5) < 1e-9 and len(x) == SR and not source.finished()


def test_partial_store_appends_and_skips_truncated_line(tmp_path):
    work = tmp_path / "m" / ".work"
    (tmp_path / "m").mkdir()
    store = PartialTranscriptFile(work / "transcript.partial.jsonl")
    assert store.load() == []
    store.append({"track": "mic", "seq": 0, "start": 0, "end": 5, "segments": [{"text": "chào"}]})
    with store.path.open("a", encoding="utf-8") as f:
        f.write('{"track": "mic", "seq": 1, "sta')  # crash mid-write
    assert [c["seq"] for c in store.load()] == [0]
    store.append({"track": "mic", "seq": 2, "start": 9, "end": 12, "segments": []})
    assert [c["seq"] for c in store.load()] == [0, 2]


def test_partial_store_never_recreates_a_deleted_meeting_folder(tmp_path):
    store = PartialTranscriptFile(tmp_path / "gone" / ".work" / "transcript.partial.jsonl")
    try:
        store.append({"track": "mic", "seq": 0, "start": 0, "end": 1})
    except OSError:
        pass
    assert not (tmp_path / "gone").exists()


def test_replay_source_releases_audio_at_speed(tmp_path):
    folder = tmp_path / "m"
    folder.mkdir()
    (folder / "meeting.json").write_text(json.dumps({"tracks": {"mic": {"file": "mic.wav", "start_offset_sec": 0.5}}}))
    (folder / "mic.m4a").write_bytes(b"")  # finalized meeting: only the aligned m4a is left
    now = [0.0]
    source = ReplaySource(folder, 4.0, lambda p: np.zeros(10 * SR, np.float32), clock=lambda: now[0])
    assert source.offsets == {"mic": 0.0}  # m4a copies are already aligned
    assert len(source.poll("mic", 30)[1]) == 0
    now[0] = 1.0
    start, x = source.poll("mic", 30)
    assert start == 0.0 and len(x) == 4 * SR and not source.finished()
    now[0] = 10.0
    assert len(source.poll("mic", 30)[1]) == 6 * SR and source.finished()


def test_load_probe_reads_this_mac():
    s = SystemLoadProbe().sample()
    assert isinstance(s, LoadSample) and s.memory_pressure in (0, 1, 2, 4) and 0 <= s.thermal <= 4 and s.cpu_busy >= 0
