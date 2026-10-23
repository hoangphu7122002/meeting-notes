"""Live transcription while recording (design A, docs/research/realtime.md 4.1 with the feasibility amendments).

Loop: poll the growing tracks -> cut chunks at pauses -> back-pressure `decide` -> gate (voiced speech, mic
bleed) -> decode one chunk with the same block decoder as the offline pass -> append it to the partial store
-> `live_segment`. One chunk is in flight at a time; on stop the current chunk finishes and the rest (queue,
uncut audio) is left to the Stop-time pass, which reuses only chunks that pass the strict rule.
"""

from __future__ import annotations

import time
from collections import defaultdict

from ..config import Config
from ..domain.live_backlog import PROCESS, SKIP, BacklogPolicy, Decision, decide, status_of
from ..domain.live_chunks import ChunkPolicy, LiveChunk, TrackChunker, mic_is_bleed, worth_decoding
from ..domain.live_polish import LivePolisher, PolishRules, glossary_terms
from ..domain.partial_merge import PARTIAL_VERSION, config_signature, usable_partials
from ..domain.signal import SR
from ..domain.speakers import Block
from .ports import LiveAudioSource, LoadProbe, ModelProvider, PartialTranscriptStore, ProgressReporter, StopSignal
from .transcribe_blocks import decode_block, whisper_prompt

PARTIAL_FILE = "transcript.partial.jsonl"
POLL_SEC = 1.0
CATCH_UP_SEC = 30.0  # most audio read per track and poll (resume after a crash reads the backlog in steps)
STATUS_EVERY_SEC = 10.0
OTHERS = "Others"


def live_signature(cfg: Config) -> str:
    """Settings that change what a chunk decodes to; partials with another signature are re-decoded at Stop."""
    return config_signature({
        "v": PARTIAL_VERSION, "model": cfg.whisper_model, "languages": list(cfg.languages),
        "prompt": {lang: whisper_prompt(cfg, lang) for lang in ("vi", "en")}, "vad": cfg.whisper_vad,
        "split_gap": cfg.vad_split_gap, "fallback": cfg.whisper_temperature_fallback,
        "previous_text": cfg.whisper_condition_on_previous_text,
    })


def make_polisher(cfg: Config) -> LivePolisher | None:
    """Tier 1 rules when `live_polish` is "rules" (or "llm": Tier 2 is not built yet, rules are its first pass)."""
    if str(cfg.live_polish or "off").strip().lower() not in ("rules", "llm"):
        return None
    return LivePolisher(PolishRules(glossary=tuple(glossary_terms(cfg.glossary)),
                                    pause_sec=float(cfg.live_polish_pause_sec),
                                    max_words=max(1, int(cfg.live_polish_max_words))))


def chunk_policy(cfg: Config) -> ChunkPolicy:
    max_sec = min(cfg.live_max_chunk_sec, cfg.whisper_max_chunk_sec)
    min_sec = min(cfg.live_min_chunk_sec, max_sec)
    return ChunkPolicy(min_sec=min_sec, max_sec=max_sec, pause_sec=cfg.live_pause_sec, warmup_sec=max(8.0, min_sec),
                       history_sec=cfg.live_max_backlog_sec + max_sec + 5.0)


class LiveTranscription:
    def __init__(self, source: LiveAudioSource, store: PartialTranscriptStore, models: ModelProvider, probe: LoadProbe,
                 reporter: ProgressReporter, cfg: Config, clock=time.monotonic):
        self.source, self.store, self.models, self.probe, self.r, self.cfg = source, store, models, probe, reporter, cfg
        self.clock = clock
        self.policy = chunk_policy(cfg)
        self.backlog_policy = BacklogPolicy(cfg.live_max_backlog_sec, cfg.live_on_battery)
        self.signature = live_signature(cfg)
        self.polisher = make_polisher(cfg)
        self.speakers = {"mic": cfg.me_name}
        self.chunkers: dict[str, TrackChunker] = {}
        self.pending: list[LiveChunk] = []
        self.prior: dict[str, dict[str, float]] = defaultdict(lambda: defaultdict(float))
        self.resume: dict[str, tuple[float, int]] = {}
        self.stats = {"decoded": 0, "silent": 0, "bleed": 0, "skipped_sec": 0.0, "decoded_sec": 0.0, "wall_sec": 0.0}
        self.rtf: float | None = None
        self._status_key: tuple | None = None
        self._status_at = 0.0

    # ------------------------------------------------------------ driver

    def run(self, stop: StopSignal) -> dict:
        self._resume()
        decision = Decision(PROCESS)
        while not stop.is_set():
            more = self._poll()
            decision = decide(self.backlog_sec(), self.probe.sample(), self.backlog_policy)
            if decision.action == SKIP:
                self._skip(decision.reason or "backlog")
            elif decision.action == PROCESS and self.pending:
                self._decode(self.pending.pop(0))
                self._report(decision)
                continue  # the next chunk may be ready; stop is checked first
            self._report(decision)
            if self.source.finished() and not more and (not self.pending or decision.action != PROCESS):
                break  # end of a replay: what is still queued is left to the Stop-time pass
            if not more:
                stop.wait(POLL_SEC)
        if self.polisher:
            self._send_polish(self.polisher.close_all())
        self._report(decision, state="stopped")
        return dict(self.stats, rtf=self.rtf)

    def backlog_sec(self) -> float:
        """Audio that exists but is not decoded yet: queued chunks + uncut audio (polled or still on disk)."""
        queued = sum(c.duration for c in self.pending)
        uncut = sum(max(0.0, self.source.position(t) - ch.open_start) for t, ch in self.chunkers.items()
                    if ch.origin is not None)
        return queued + uncut

    # ------------------------------------------------------------ steps

    def _resume(self) -> None:
        """Continue after a worker crash: each track restarts at the end of its last line; decoded chunks are
        re-announced so the app can rebuild its view."""
        lines = self.store.load()
        for c in lines:
            end, seq = self.resume.get(c["track"], (0.0, 0))
            self.resume[c["track"]] = (max(end, float(c["end"])), max(seq, int(c["seq"]) + 1))
        for c in usable_partials(lines, self.signature):
            self._announce(c)
            for s in c.get("segments", []):
                self.prior[self._speaker(c["track"])][c.get("language", "")] += s["end"] - s["start"]

    def _poll(self) -> bool:
        """Feed every track; True when a track returned a full catch-up read (more is waiting on disk)."""
        more = False
        for track in self.source.tracks():
            if track not in self.chunkers:
                start_at, seq = self.resume.get(track, (0.0, 0))
                self.chunkers[track] = TrackChunker(track, self.policy, start_at, seq)
            start, samples = self.source.poll(track, CATCH_UP_SEC)
            more |= samples.size >= int(CATCH_UP_SEC * SR) - 1
            self.pending += self.chunkers[track].feed(start, samples)
        self.pending.sort(key=lambda c: (c.end, c.track))
        return more

    def _skip(self, reason: str) -> None:
        """Battery: drop the whole queue. Backlog: drop the oldest chunks until under the limit."""
        while self.pending and (reason == "battery" or self.backlog_sec() > self.backlog_policy.max_backlog_sec):
            chunk = self.pending.pop(0)
            self.stats["skipped_sec"] += chunk.duration
            self._record(chunk, reason)

    def _decode(self, chunk: LiveChunk) -> None:
        if not worth_decoding(chunk, self.policy):
            self.stats["silent"] += 1
            self._record(chunk, "silent")
            return
        if chunk.track == "mic" and self._is_bleed(chunk):
            self.stats["bleed"] += 1
            self._record(chunk, "bleed")
            return
        speaker = self._speaker(chunk.track)
        block = Block(chunk.start, chunk.end, speaker, chunk.track, [(chunk.start, chunk.end)])
        t0 = self.clock()
        segments, language = decode_block(block, chunk.audio, chunk.threshold_db, self.models.transcriber(),
                                          self.cfg.languages, self.prior, self.cfg.whisper_vad, self.cfg.vad_split_gap,
                                          base_sec=chunk.audio_start)
        wall = self.clock() - t0
        if language is None:  # VAD found nothing worth a call
            self.stats["silent"] += 1
            self._record(chunk, "silent")
            return
        rtf = wall / max(chunk.duration, 1e-6)
        self.rtf = rtf if self.rtf is None else 0.7 * self.rtf + 0.3 * rtf
        self.stats["decoded"] += 1
        self.stats["decoded_sec"] += chunk.duration
        self.stats["wall_sec"] += wall
        line = self._record(chunk, "decoded", language, [
            {"start": round(s.start, 3), "end": round(s.end, 3), "text": s.text} for s in segments])
        self._announce(line)

    def _is_bleed(self, chunk: LiveChunk) -> bool:
        system = self.chunkers.get("system")
        other = system.recent(chunk.start, chunk.end) if system else None
        mic = chunk.audio[int(round((chunk.start - chunk.audio_start) * SR)):][: int(round(chunk.duration * SR))]
        return other is not None and mic_is_bleed(mic, other, chunk.threshold_db)

    # ------------------------------------------------------------ output

    def _record(self, chunk: LiveChunk, status: str, language: str | None = None, segments: list | None = None) -> dict:
        line = {"v": PARTIAL_VERSION, "track": chunk.track, "seq": chunk.seq, "start": round(chunk.start, 3),
                "end": round(chunk.end, 3), "status": status, "forced": chunk.forced, "language": language,
                "signature": self.signature, "segments": segments or []}
        self.store.append(line)
        return line

    def _announce(self, line: dict) -> None:
        segments = line.get("segments") or []
        if segments:
            text = " ".join(s["text"] for s in segments)
            track, speaker, seq = line["track"], self._speaker(line["track"]), int(line["seq"])
            self.r.live_segment(track, speaker, seq, segments[0]["start"], segments[-1]["end"],
                                line.get("language") or "", text)
            if self.polisher:
                self._send_polish(self.polisher.add(track, speaker, seq, segments[0]["start"], segments[-1]["end"],
                                                    text))

    def _send_polish(self, paragraphs: list) -> None:
        for p in paragraphs:
            self.r.live_polish(p.track, p.speaker, p.para, p.seqs, "rules", p.text)

    def _speaker(self, track: str) -> str:
        return self.speakers.get(track, OTHERS)

    def _report(self, decision: Decision, state: str | None = None) -> None:
        """live_status on a state change, and every STATUS_EVERY_SEC while running."""
        state = state or status_of(decision)
        reason = None if state in ("running", "stopped") else decision.reason
        now = self.clock()
        if (state, reason) == self._status_key and now - self._status_at < STATUS_EVERY_SEC:
            return
        self._status_key, self._status_at = (state, reason), now
        self.r.live_status(state, round(self.backlog_sec(), 1), round(self.stats["skipped_sec"], 1),
                           None if self.rtf is None else round(self.rtf, 3), reason)
