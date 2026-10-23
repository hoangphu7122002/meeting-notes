"""Live caption (design B) latency bench: stream a synthetic wav into the MeetingNotesCaptions helper in real time.

  uv run python bench/caption_bench.py <corpus_dir> --helper ../app/.build/release/MeetingNotesCaptions \
      --models <whisperkit dir> [--model openai_whisper-small] [--speed 1.0] [--track system] [--out result.json]

`<corpus_dir>` is an `asr_bench.py make` corpus (corpus.wav + corpus.json with known text); never a real recording.
The helper gets exactly the app's wire protocol (`CaptionWire.swift`): 100 ms `audio` lines paced at `speed` x real
time. Reported: time to first caption per utterance (speech onset -> first caption text overlapping it), caption lag
(arrival - end of the audio the caption covers), final latency (utterance end -> confirmed text), WER/CER of the
confirmed captions against the known text, helper RSS and physical footprint (peak / median, sampled every second)
and model load time.
"""

from __future__ import annotations

import argparse
import base64
import json
import re
import subprocess
import sys
import threading
import time
from pathlib import Path

import numpy as np

SR = 16000
STEP = 0.1  # seconds of audio per `audio` line, like the app's tap
PAD = 0.1  # asr_bench blocks start 0.1 s before the speech


def percentile(values: list[float], q: float) -> float | None:
    return float(np.percentile(values, q)) if values else None


def utterances(blocks: list[dict]) -> list[tuple[float, float, str]]:
    """(speech start, speech end, text) of the corpus speech blocks."""
    out = []
    for b in blocks:
        if b.get("category") == "noise":
            continue
        end = b["end"] - (3.0 if b.get("loose") else PAD)
        out.append((b["start"] + PAD, end, b["text"]))
    return out


def latency_report(events: list[dict], utts: list[tuple[float, float, str]]) -> dict:
    """`events`: caption events with `t` = arrival in audio seconds since the stream started."""
    shown = [e for e in events if e.get("text")]
    ttfc, final_lat, missed = [], [], 0
    for start, end, _ in utts:
        first = next((e["t"] for e in shown if e["start"] < end and e["end"] > start - 0.5 and e["t"] >= start), None)
        if first is None:
            missed += 1
            continue
        ttfc.append(first - start)
        done = next((e["t"] for e in shown if e["final"] and e["end"] >= end - 0.6 and e["start"] < end), None)
        if done is not None:
            final_lat.append(done - end)
    lag = [e["t"] - e["end"] for e in shown]
    stat = lambda xs: {"p50": percentile(xs, 50), "p95": percentile(xs, 95), "n": len(xs)}  # noqa: E731
    return {"ttfc_sec": stat(ttfc), "lag_sec": stat(lag), "final_sec": stat(final_lat), "missed_utterances": missed,
            "utterances": len(utts)}


def final_text(events: list[dict]) -> str:
    finals = {}
    for e in events:
        if e.get("final") and e.get("text"):
            finals[(e["track"], e["seq"])] = e
    return " ".join(e["text"] for e in sorted(finals.values(), key=lambda e: e["start"]))


def quality(truth: str, hyp: str) -> dict:
    from meeting_notes.domain.metrics import wer

    errors, n = wer(truth, hyp)
    cerr, cn = wer(" ".join(truth.replace(" ", "")), " ".join(hyp.replace(" ", "")))
    return {"wer": errors / max(n, 1), "cer": cerr / max(cn, 1), "ref_words": n}


def audio_line(track: str, start: float, chunk: np.ndarray) -> bytes:
    pcm = (np.clip(chunk, -1, 1) * 32767).astype("<i2").tobytes()
    return (json.dumps({"cmd": "audio", "track": track, "start": round(start, 3),
                        "pcm": base64.b64encode(pcm).decode()}) + "\n").encode()


def rss_mb(pid: int) -> float | None:
    out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return int(out) / 1024 if out else None


def footprint_mb(pid: int) -> float | None:
    """Physical footprint (`footprint`): unlike RSS it counts IOSurface/IOKit memory of Core ML models."""
    out = subprocess.run(["footprint", "-p", str(pid)], capture_output=True, text=True).stdout
    m = re.search(r"Footprint: ([\d.]+) (KB|MB|GB)", out)
    if not m:
        return None
    return float(m.group(1)) * {"KB": 1 / 1024, "MB": 1.0, "GB": 1024.0}[m.group(2)]


def run(corpus: Path, helper: str, models: str, model: str, speed: float, track: str) -> dict:
    from meeting_notes.adapters.outbound.wav_files import read_wav

    audio = read_wav(corpus / "corpus.wav")
    spec = json.loads((corpus / "corpus.json").read_text())
    proc = subprocess.Popen([helper, "--models", models, "--model", model], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    t_spawn = time.monotonic()
    events: list[dict] = []
    ready = threading.Event()
    info: dict = {}
    t0 = [0.0]

    def reader() -> None:
        for raw in proc.stdout:
            try:
                ev = json.loads(raw)
            except ValueError:
                continue
            if ev.get("event") == "ready":
                info.update(ev, ready_wall=time.monotonic() - t_spawn)
                ready.set()
            elif ev.get("event") == "caption":
                ev["t"] = (time.monotonic() - t0[0]) * speed
                events.append(ev)
            elif ev.get("event") == "error":
                info.setdefault("errors", []).append(ev.get("message"))
                ready.set()
    threading.Thread(target=reader, daemon=True).start()
    if not ready.wait(600) or "model" not in info:
        proc.kill()
        raise SystemExit(f"helper not ready: {info}")
    rss: list[float] = []
    foot: list[float] = []
    step = int(STEP * SR)
    t0[0] = time.monotonic()
    last_rss = 0.0
    for i in range(0, len(audio), step):
        due = t0[0] + (i / SR) / speed
        time.sleep(max(0.0, due - time.monotonic()))
        proc.stdin.write(audio_line(track, i / SR, audio[i:i + step]))
        proc.stdin.flush()
        if time.monotonic() - last_rss >= 1:
            last_rss = time.monotonic()
            if (m := rss_mb(proc.pid)) is not None:
                rss.append(m)
            if (f := footprint_mb(proc.pid)) is not None:
                foot.append(f)
    time.sleep(3)
    proc.stdin.write(b'{"cmd":"quit"}\n')
    proc.stdin.close()
    proc.wait(30)
    utts = utterances(spec["blocks"])
    truth = " ".join(u[2] for u in utts)
    return {"model": model, "speed": speed, "load_sec": info.get("load_sec"), "ready_sec": info.get("ready_wall"),
            **latency_report(events, utts), **quality(truth, final_text(events)),
            "rss_mb": {"peak": max(rss) if rss else None, "median": percentile(rss, 50)},
            "footprint_mb": {"peak": max(foot) if foot else None, "median": percentile(foot, 50)},
            "events": len(events), "errors": info.get("errors", []), "_events": events}


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("corpus", type=Path)
    ap.add_argument("--helper", required=True)
    ap.add_argument("--models", required=True)
    ap.add_argument("--model", default="openai_whisper-small")
    ap.add_argument("--speed", type=float, default=1.0)
    ap.add_argument("--track", default="system")
    ap.add_argument("--out", type=Path)
    ap.add_argument("--events", type=Path, help="also write every caption event (JSON lines)")
    a = ap.parse_args()
    row = run(a.corpus, a.helper, a.models, a.model, a.speed, a.track)
    events = row.pop("_events")
    if a.events:
        a.events.write_text("\n".join(json.dumps(e, ensure_ascii=False) for e in events) + "\n")
    text = json.dumps(row, ensure_ascii=False, indent=1)
    if a.out:
        a.out.write_text(text)
    print(text)
    sys.stdout.flush()


if __name__ == "__main__":
    main()
