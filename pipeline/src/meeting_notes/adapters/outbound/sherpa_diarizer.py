"""Speaker diarization with sherpa-onnx (opt-in, `diarization_engine = "sherpa-onnx"`).

pyannote segmentation-3.0 (ONNX) + a 3D-Speaker/WeSpeaker embedding (ONNX) + sherpa's fast clustering, on CPU
through onnxruntime: no torch and no Hugging Face token for the full pass. The mic single-voice check and every
failure path (sherpa-onnx not installed, download or inference error) use the pyannote Diarizer, so this engine
never makes a job fail. Models: adapters/outbound/sherpa_models.py.
"""

from __future__ import annotations

from collections.abc import Callable

import numpy as np

from ...config import Config
from ...domain.intervals import Interval
from ...domain.signal import SR, energy_vad
from ...domain.speakers import TrackDiarization
from ...domain.voice_check import VoiceCheck

INSTALL_HINT = "install it with `uv sync --extra sherpa` in pipeline/"


class SherpaDiarizer:
    def __init__(self, cfg: Config, log: Callable[[str], None] = print, fallback=None, loader=None):
        self.cfg = cfg
        self.log = log
        self._engine = None
        self._error: str | None = None
        self._fallback = fallback  # pyannote Diarizer, created on demand
        self._loader = loader or _load_engine

    @property
    def name(self) -> str:
        return f"sherpa-onnx:{self.cfg.sherpa_embedding_model}"

    def fallback(self):
        if self._fallback is None:
            from .pyannote_diarizer import Diarizer

            self._fallback = Diarizer(self.cfg, log=self.log)
        self._fallback.cfg = self.cfg
        return self._fallback

    def engine(self):
        if self._engine is None and self._error is None:
            try:
                self._engine = self._loader(self.cfg, self.log)
            except Exception as exc:
                self._error = _short_error(exc)
        return self._engine

    def diarize(self, audio: np.ndarray, progress: Callable[[float], None] | None = None) -> TrackDiarization:
        if not energy_vad(audio):
            return TrackDiarization([], "vad", ["no speech detected"])
        engine = self.engine()
        if engine is not None:
            try:
                return TrackDiarization(run(engine, audio, progress), self.name)
            except Exception as exc:
                note = f"sherpa-onnx failed: {_short_error(exc)}"
        else:
            note = f"sherpa-onnx unavailable: {self._error}"
        self.log(f"diarization: {note}; using pyannote")
        out = self.fallback().diarize(audio, progress)
        return TrackDiarization(out.turns, out.method, [note, *out.notes])

    def voice_check(self, audio: np.ndarray, exclude: list[Interval] | None = None) -> VoiceCheck:
        return self.fallback().voice_check(audio, exclude)  # thresholds are tuned on the pyannote embedder

    def release(self) -> None:
        self._engine = None
        if self._fallback is not None:
            self._fallback.release()
            self._fallback = None

    def trim(self) -> None:
        if self._fallback is not None:
            self._fallback.trim()


def run(engine, audio: np.ndarray, progress: Callable[[float], None] | None = None) -> list[tuple[float, float, str]]:
    """Diarize one 16 kHz track -> raw turns (start, end, cluster id as str), sorted by start."""
    if getattr(engine, "sample_rate", SR) != SR:
        raise RuntimeError(f"sherpa-onnx expects {engine.sample_rate} Hz audio")

    def callback(done: int, total: int) -> int:
        if progress and total:
            progress(min(1.0, done / total))
        return 0  # 0 = continue

    samples = np.ascontiguousarray(audio, dtype=np.float32)
    result = engine.process(samples, callback=callback).sort_by_start_time()
    return [(float(r.start), float(r.end), str(r.speaker)) for r in result]


def _load_engine(cfg: Config, log: Callable[[str], None]):
    from .sherpa_models import embedding_model, segmentation_model

    try:
        import sherpa_onnx
    except ImportError as exc:
        raise RuntimeError(f"sherpa-onnx is not installed ({INSTALL_HINT})") from exc
    segmentation = segmentation_model(log=log)
    embedding = embedding_model(cfg.sherpa_embedding_model, log=log)
    threads = max(1, int(cfg.cpu_threads))
    config = sherpa_onnx.OfflineSpeakerDiarizationConfig(
        segmentation=sherpa_onnx.OfflineSpeakerSegmentationModelConfig(
            pyannote=sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(model=str(segmentation)),
            num_threads=threads, provider="cpu"),
        embedding=sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=str(embedding), num_threads=threads, provider="cpu"),
        clustering=sherpa_onnx.FastClusteringConfig(num_clusters=-1, threshold=float(cfg.sherpa_cluster_threshold)),
        min_duration_on=0.3,
        min_duration_off=0.5,
    )
    if not config.validate():
        raise RuntimeError("invalid sherpa-onnx diarization config")
    return sherpa_onnx.OfflineSpeakerDiarization(config)


def _short_error(exc: Exception) -> str:
    return " ".join(f"{type(exc).__name__}: {exc}".split())[:240]
