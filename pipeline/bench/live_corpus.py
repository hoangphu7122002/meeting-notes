"""Corpora and the offline reference for the live-transcription feasibility benches (T3, T4).

A corpus = per-track 16 kHz audio + diarization turns (+ glossary). Real meeting folders are read-only: audio is
decoded in memory, nothing is written next to the recordings. The offline reference is the current
`stage_transcribe` path (diarization turns -> blocks -> `transcribe_blocks`), re-run with the configured model.
"""

from __future__ import annotations

import json
import os
import time
from dataclasses import asdict, dataclass
from pathlib import Path

import numpy as np

os.environ.setdefault("HF_HUB_OFFLINE", "1")  # weights are cached locally; the bench never needs the network
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")

from meeting_notes.domain.segments import split_long_blocks  # noqa: E402
from meeting_notes.domain.signal import SR, place  # noqa: E402
from meeting_notes.domain.speakers import Turn, build_blocks  # noqa: E402


@dataclass
class Corpus:
    name: str
    kind: str  # "real" | "synthetic"
    tracks: dict[str, np.ndarray]
    turns: list[Turn]
    glossary: list[str]
    truth: str | None = None  # known text (synthetic TTS only); real meetings have no human reference

    @property
    def audio_sec(self) -> float:
        return max((len(x) for x in self.tracks.values()), default=0) / SR

    @property
    def turn_sec(self) -> float:
        return sum(t.duration for t in self.turns)


def excerpt(tracks: dict[str, np.ndarray], turns: list[Turn], offset: float, minutes: float) -> tuple[dict, list[Turn]]:
    a, b = int(offset * SR), int((offset + minutes * 60) * SR)
    cut = {n: np.ascontiguousarray(x[a:b]) for n, x in tracks.items()}
    out = []
    for t in turns:
        s, e = max(t.start, offset) - offset, min(t.end, offset + minutes * 60) - offset
        if e - s >= 0.05:
            out.append(Turn(s, e, t.speaker, t.track))
    return cut, out


def load_meeting(folder: Path, alias: str, minutes: float = 10.0, offset: float = 0.0) -> Corpus:
    """Decode a meeting folder (m4a or wav tracks, placed by start offset) and read `.work/diarization.json`."""
    from meeting_notes.adapters.outbound.ffmpeg_audio import decode

    meta = json.loads((folder / "meeting.json").read_text())
    decoded = {name: (decode(folder / info["file"]), float(info.get("start_offset_sec") or 0.0))
               for name, info in meta["tracks"].items()}
    length = max(int(round(off * SR)) + len(x) for x, off in decoded.values())
    tracks = {name: place(x, off, length) for name, (x, off) in decoded.items()}
    diar = json.loads((folder / ".work" / "diarization.json").read_text())
    turns = [Turn(**t) for t in diar["turns"]]
    tracks, turns = excerpt(tracks, turns, offset, minutes)
    return Corpus(alias, "real", tracks, turns, [])  # the user's configured glossary is empty


def load_synthetic(out: Path, fast: bool = False) -> Corpus:
    """The asr_bench `say` corpus as one 'system' track with three speakers; truth blocks stand in for diarization.

    `fast` = quick turn-taking: 0.3 s between utterances (below the 0.7 s chunk pause) and no trailing silence,
    so live chunks span several speakers (the ambiguous-segment case of T4)."""
    import asr_bench
    from meeting_notes.adapters.outbound.wav_files import read_wav

    if not (out / "corpus.wav").exists():
        if fast:
            asr_bench.GAP, asr_bench.LOOSE_EVERY = 0.3, 10**9
        asr_bench.make(out)
    spec = json.loads((out / "corpus.json").read_text())
    turns = []
    for b in spec["blocks"]:
        if b["category"] == "noise":
            continue
        end = b["end"] - (3.0 if b.get("loose") else 0.1)
        turns.append(Turn(b["start"] + 0.1, end, b["speaker"], "system"))
    truth = " ".join(b["text"] for b in spec["blocks"] if b["category"] != "noise")
    return Corpus("synfast" if fast else "syn", "synthetic", {"system": read_wav(out / "corpus.wav")}, turns, list(spec["glossary"]), truth)


def make_config(glossary: list[str]):
    from meeting_notes.config import Config

    cfg = Config()
    cfg.glossary = list(glossary)
    return cfg


class CountingTranscriber:
    """Transcriber proxy that counts model calls, so silent chunks (no whisper call) can be told from speech."""

    def __init__(self, inner):
        self.inner, self.cfg, self.calls, self.model_sec = inner, inner.cfg, 0, 0.0

    def detect_language(self, audio):
        return self._timed(self.inner.detect_language, audio)

    def transcribe(self, audio, language):
        return self._timed(self.inner.transcribe, audio, language)

    def _timed(self, fn, *args):
        t0 = time.monotonic()
        try:
            return fn(*args)
        finally:
            self.calls += 1
            self.model_sec += time.monotonic() - t0

    def release(self):
        self.inner.release()


def load_transcriber(cfg) -> CountingTranscriber:
    from meeting_notes.adapters.outbound.mlx_transcriber import Transcriber

    tr = Transcriber(cfg)
    tr._load()
    tr.detect_language(np.zeros(SR, np.float32))  # warm up: weights + first-shape compile are not decode time
    return CountingTranscriber(tr)


def offline_reference(corpus: Corpus, tr, cfg) -> dict:
    """What `stage_transcribe` produces for this corpus (same blocks, VAD, language choice, prompt, filters)."""
    from meeting_notes.application.transcribe_blocks import transcribe_blocks

    blocks = split_long_blocks(build_blocks(corpus.turns), corpus.tracks, max_len=cfg.whisper_max_chunk_sec)
    t0 = time.monotonic()
    segs = transcribe_blocks(blocks, corpus.tracks, tr, cfg.languages, vad=cfg.whisper_vad, split_gap=cfg.vad_split_gap)
    return {"segments": [asdict(s) for s in segs], "wall_sec": time.monotonic() - t0,
            "block_sec": sum(b.duration for b in blocks), "n_blocks": len(blocks)}


def pressure_level() -> int:
    """kern.memorystatus_vm_pressure_level: 1 normal, 2 warn, 4 critical (0 when unknown)."""
    import subprocess

    out = subprocess.run(["sysctl", "-n", "kern.memorystatus_vm_pressure_level"], capture_output=True, text=True)
    return int(out.stdout.strip() or 0)


def wait_for_normal_pressure(max_wait_min: float, allow_warn: bool) -> int:
    """Block until memory pressure is normal; at the deadline continue only with `allow_warn` (never at critical)."""
    deadline = time.monotonic() + max_wait_min * 60
    while (level := pressure_level()) not in (0, 1):
        if time.monotonic() >= deadline:
            if level >= 4 or not allow_warn:
                raise SystemExit(f"memory pressure level {level} (1 = normal): not running a heavy job")
            return level
        time.sleep(15)
    return level


def add_corpus_args(ap) -> None:
    ap.add_argument("scratch", type=Path, help="output dir (never a meeting folder)")
    ap.add_argument("--meeting", action="append", default=[], metavar="DIR[=ALIAS]",
                    help="meeting folder (read-only); repeatable; alias names it in reports")
    ap.add_argument("--synthetic", action="store_true", help="add the asr_bench `say` corpus (supplementary)")
    ap.add_argument("--synthetic-fast", action="store_true", help="add the same corpus with 0.3 s turn-taking gaps")
    ap.add_argument("--minutes", type=float, default=10.0, help="excerpt length per meeting")
    ap.add_argument("--offset", type=float, default=0.0, help="excerpt start, seconds")
    ap.add_argument("--max-wait-min", type=float, default=10.0, help="wait this long for normal memory pressure")
    ap.add_argument("--allow-warn", action="store_true", help="run at pressure 'warn' after the wait (never critical)")


def corpora(args) -> list[Corpus]:
    out = []
    for i, spec in enumerate(args.meeting, 1):
        path, _, alias = spec.partition("=")
        out.append(load_meeting(Path(path).expanduser(), alias or f"m{i}", args.minutes, args.offset))
    if args.synthetic:
        out.append(load_synthetic(args.scratch / "syn"))
    if args.synthetic_fast:
        out.append(load_synthetic(args.scratch / "synfast", fast=True))
    return out


def cached(path: Path, compute, force: bool = False):
    """JSON cache in the scratch dir so reruns and T4 reuse decoded chunks and the offline reference."""
    if path.exists() and not force:
        return json.loads(path.read_text())
    path.parent.mkdir(parents=True, exist_ok=True)
    value = compute()
    path.write_text(json.dumps(value, ensure_ascii=False))
    return value
