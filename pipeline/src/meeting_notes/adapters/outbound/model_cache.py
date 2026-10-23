"""Model cache shared across jobs, so a long-lived worker keeps whisper and pyannote warm (ModelProvider).

`keep` follows `keep_models_warm` (domain/warm_policy.py): "auto" holds a model after its stage and between jobs
only while memory pressure is "normal"; under "warn" or worse it is released, and before loading the other heavy
model the idle one is dropped, so at most one is resident. A kept model still drops its freed-buffer cache.
"""

from __future__ import annotations

import time
from collections.abc import Callable

import numpy as np

from ...config import Config
from ...domain.warm_policy import OFF, keep_warm, warm_mode


class Models:
    """Holds the diarizer and transcriber. `keep=False` (one-shot CLI) frees each after use; "auto" / True keep
    them per the warm policy. `pressure` returns kern.memorystatus_vm_pressure_level (tests inject it)."""

    def __init__(self, cfg: Config, keep: bool | str = False, log: Callable[[str], None] = print,
                 pressure: Callable[[], int] | None = None):
        self.cfg = cfg
        self.keep = keep
        self.mode = warm_mode(keep)
        self.log = log
        self._pressure = pressure
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

    def pressure(self) -> int:
        if self._pressure is None:
            from .load_probe import memory_pressure_level

            self._pressure = memory_pressure_level
        try:
            return int(self._pressure())
        except Exception:
            return 0  # unknown: "auto" treats it as not normal

    def keep_now(self) -> bool:
        """Whether a loaded model may stay resident right now."""
        return self.mode != OFF and keep_warm(self.mode, self.pressure())

    def release_if_pressure(self) -> bool:
        """Release every loaded model when the policy no longer allows holding them; True if something was freed."""
        if not self.loaded or self.keep_now():
            return False
        self.release()
        self.log("released models (memory pressure)")
        return True

    def diarizer(self):
        from .pyannote_diarizer import Diarizer

        if self._transcriber is not None and not self.keep_now():
            self._drop_transcriber()  # one heavy model at a time unless memory is plentiful
        if self._diarizer is None:
            self._diarizer = Diarizer(self.cfg, log=self.log)
        self._diarizer.cfg = self.cfg
        self.last_used = time.monotonic()
        return self._diarizer

    def transcriber(self):
        from .mlx_transcriber import Transcriber

        if self._diarizer is not None and not self.keep_now():
            self._drop_diarizer()
        if self._transcriber is None:
            self._transcriber = Transcriber(self.cfg)
        self._transcriber.cfg = self.cfg
        self.last_used = time.monotonic()
        return self._transcriber

    def done_with_diarizer(self) -> None:
        if self._diarizer is None:
            return
        if self.keep_now():
            _trim(self._diarizer)
        else:
            self._drop_diarizer()

    def done_with_transcriber(self) -> None:
        if self._transcriber is None:
            return
        if self.keep_now():
            _trim(self._transcriber)
        else:
            self._drop_transcriber()

    def _drop_diarizer(self) -> None:
        if self._diarizer is not None:
            self._diarizer.release()
            self._diarizer = None

    def _drop_transcriber(self) -> None:
        if self._transcriber is not None:
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
        self._drop_diarizer()
        self._drop_transcriber()


def _trim(model) -> None:
    """Drop a kept model's freed-buffer cache (gc + MLX/MPS cache clear) without unloading its weights."""
    trim = getattr(model, "trim", None)
    if trim is not None:
        try:
            trim()
        except Exception:
            pass
