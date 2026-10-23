"""Live caption bench (design B): latency and text metrics over helper events, and the app's audio wire format."""

import base64
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "bench"))

from caption_bench import audio_line, final_text, latency_report, quality, utterances  # noqa: E402


def ev(t, start, end, text, final, seq=0, track="system"):
    return {"t": t, "start": start, "end": end, "text": text, "final": final, "seq": seq, "track": track}


def test_utterances_strip_block_padding():
    blocks = [{"start": 1.0, "end": 4.1, "text": "a", "category": "vi"},
              {"start": 6.0, "end": 12.0, "text": "", "category": "noise"},
              {"start": 13.0, "end": 19.0, "text": "b", "category": "en", "loose": True}]
    got = utterances(blocks)
    assert [u[2] for u in got] == ["a", "b"]
    assert np.allclose([u[:2] for u in got], [(1.1, 4.0), (13.1, 16.0)])


def test_latency_report():
    utts = [(1.0, 4.0, "a"), (10.0, 12.0, "b"), (20.0, 21.0, "c")]
    events = [ev(2.5, 1.0, 2.0, "xin", False), ev(4.6, 1.0, 4.0, "xin chào", True),
              ev(11.2, 10.0, 11.0, "", False), ev(11.8, 10.0, 11.5, "hello", False), ev(13.0, 10.0, 12.0, "hello", True, 1)]
    report = latency_report(events, utts)
    assert report["missed_utterances"] == 1
    assert report["ttfc_sec"]["n"] == 2
    assert abs(report["ttfc_sec"]["p50"] - 1.65) < 1e-9  # (1.5 + 1.8) / 2
    assert report["final_sec"]["n"] == 2
    assert abs(report["final_sec"]["p50"] - 0.8) < 1e-9  # (0.6 + 1.0) / 2


def test_final_text_orders_and_dedupes_finals():
    events = [ev(3, 5, 6, "hai", True, 1), ev(2, 1, 2, "một", True, 0), ev(4, 1, 2, "một", True, 0), ev(5, 7, 8, "ba", False, 2)]
    assert final_text(events) == "một hai"
    q = quality("một hai ba", "một hai")
    assert abs(q["wer"] - 1 / 3) < 1e-9 and q["ref_words"] == 3


def test_audio_line_matches_the_swift_wire_format():
    line = json.loads(audio_line("mic", 1.23456, np.array([0.0, 0.5, -1.0, 2.0], np.float32)))
    assert line["cmd"] == "audio" and line["track"] == "mic" and line["start"] == 1.235
    samples = np.frombuffer(base64.b64decode(line["pcm"]), "<i2")
    assert samples.tolist() == [0, 16383, -32767, 32767]
