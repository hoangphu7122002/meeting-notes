"""Model cache shared across jobs, so a long-lived worker keeps whisper and pyannote warm."""

from __future__ import annotations

import json
import threading
import time
import urllib.request
from collections.abc import Callable

import numpy as np

from .config import Config


class Models:
    """Holds the diarizer and transcriber. `keep=False` (one-shot CLI) frees each after use."""

    def __init__(self, cfg: Config, keep: bool = False, log: Callable[[str], None] = print):
        self.cfg = cfg
        self.keep = keep
        self.log = log
        self._diarizer = None
        self._transcriber = None
        self.last_used = time.monotonic()

    def _signature(self, cfg: Config) -> tuple:
        return (cfg.whisper_model, tuple(cfg.diarization_models), cfg.embedding_model, cfg.diarization_device)

    def update_config(self, cfg: Config) -> None:
        if self._signature(cfg) != self._signature(self.cfg):
            self.release()
        self.cfg = cfg

    @property
    def loaded(self) -> bool:
        return self._diarizer is not None or self._transcriber is not None

    def diarizer(self):
        from .diarize import Diarizer

        if self._diarizer is None:
            self._diarizer = Diarizer(self.cfg, log=self.log)
        self._diarizer.cfg = self.cfg
        self.last_used = time.monotonic()
        return self._diarizer

    def transcriber(self):
        from .transcribe import Transcriber

        if self._transcriber is None:
            self._transcriber = Transcriber(self.cfg)
        self._transcriber.cfg = self.cfg
        self.last_used = time.monotonic()
        return self._transcriber

    def done_with_diarizer(self) -> None:
        if not self.keep and self._diarizer is not None:
            self._diarizer.release()
            self._diarizer = None

    def done_with_transcriber(self) -> None:
        if not self.keep and self._transcriber is not None:
            self._transcriber.release()
            self._transcriber = None

    def warmup(self) -> dict[str, float]:
        """Load models and run tiny inferences so Metal/MPS kernels are compiled."""
        timings = {}
        t = time.monotonic()
        d = self.diarizer()
        pipe = d.pipeline()
        if pipe is None:
            d.embedder()
        silence = np.zeros(16000 * 2, dtype=np.float32)
        silence[8000:24000] = 0.01 * np.sin(np.arange(16000) / 5.0)
        try:
            d.diarize(silence)
        except Exception as exc:  # warm-up must never fail a job
            self.log(f"warmup diarize: {exc}")
        timings["diarization"] = round(time.monotonic() - t, 2)
        t = time.monotonic()
        tr = self.transcriber()
        tr.detect_language(silence)
        timings["whisper"] = round(time.monotonic() - t, 2)
        self.last_used = time.monotonic()
        return timings

    def release(self) -> None:
        if self._diarizer is not None:
            self._diarizer.release()
        if self._transcriber is not None:
            self._transcriber.release()
        self._diarizer = self._transcriber = None


def preload_ollama(cfg: Config) -> threading.Thread:
    """Ask Ollama to load the summary model in the background (no prompt, nothing generated)."""

    def run():
        payload = json.dumps({"model": cfg.ollama_model, "keep_alive": "5m"}).encode()
        req = urllib.request.Request(cfg.ollama_url.rstrip("/") + "/api/generate", data=payload,
                                     headers={"Content-Type": "application/json"})
        try:
            urllib.request.urlopen(req, timeout=120).read()
        except Exception:
            pass  # the summary stage reports real errors

    thread = threading.Thread(target=run, name="ollama-preload", daemon=True)
    thread.start()
    return thread
