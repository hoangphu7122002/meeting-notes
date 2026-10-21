"""Speaker diarization: pyannote pipeline (gated) -> embedding clustering (ungated) -> VAD only."""

from __future__ import annotations

import os
import warnings
from collections.abc import Callable

import numpy as np

from ...config import Config, hf_token, redact
from ...domain.clustering import cluster_speakers
from ...domain.signal import SR, energy_vad
from ...domain.speakers import RawTurns, TrackDiarization

os.environ.setdefault("PYANNOTE_METRICS_ENABLED", "false")
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")


def _device(pref: str):
    import torch

    from .system_resources import apply_torch_threads

    apply_torch_threads(int(os.environ.get("OMP_NUM_THREADS", "4")))

    if pref == "cpu":
        return torch.device("cpu")
    if pref in ("mps", "auto") and torch.backends.mps.is_available():
        return torch.device("mps")
    return torch.device("cpu")


class Diarizer:
    def __init__(self, cfg: Config, log: Callable[[str], None] = print):
        self.cfg = cfg
        self.log = log
        self._pipeline = None
        self._pipeline_name: str | None = None
        self._pipeline_error: str | None = None
        self._embedder = None
        self._embedder_error: str | None = None

    # ------------------------------------------------------------ loaders

    def pipeline(self):
        if self._pipeline is not None or self._pipeline_error is not None:
            return self._pipeline
        token = hf_token()
        errors = []
        if not token:
            errors.append("HF_TOKEN not set")
        else:
            with warnings.catch_warnings():
                warnings.simplefilter("ignore")
                from pyannote.audio import Pipeline

                for name in self.cfg.diarization_models:
                    try:
                        pipe = Pipeline.from_pretrained(name, token=token)
                    except Exception as exc:  # gated / offline / incompatible
                        errors.append(f"{name}: {_short_error(exc)}")
                        continue
                    if pipe is None:
                        errors.append(f"{name}: not available")
                        continue
                    for attr in ("embedding_batch_size", "segmentation_batch_size"):
                        if hasattr(pipe, attr):
                            setattr(pipe, attr, self.cfg.diarization_batch_size)
                    try:
                        pipe.to(_device(self.cfg.diarization_device))
                    except Exception as exc:
                        self.log(f"diarization: device move failed, using CPU ({_short_error(exc)})")
                    self._pipeline, self._pipeline_name = pipe, name
                    return pipe
        self._pipeline_error = "; ".join(errors)
        return None

    def embedder(self):
        if self._embedder is not None or self._embedder_error is not None:
            return self._embedder
        try:
            with warnings.catch_warnings():
                warnings.simplefilter("ignore")
                import torch
                from pyannote.audio import Inference, Model

                model = Model.from_pretrained(self.cfg.embedding_model, token=hf_token())
                inference = Inference(model, window="whole", device=_device(self.cfg.diarization_device))

            def embed(chunk: np.ndarray) -> np.ndarray:
                wav = torch.from_numpy(np.ascontiguousarray(chunk, dtype=np.float32))[None]
                return np.asarray(inference({"waveform": wav, "sample_rate": SR})).reshape(-1)

            self._embedder = embed
        except Exception as exc:
            self._embedder_error = f"{self.cfg.embedding_model}: {_short_error(exc)}"
        return self._embedder

    def release(self) -> None:
        self._pipeline = None
        self._embedder = None
        try:
            import gc

            import torch

            gc.collect()
            if torch.backends.mps.is_available():
                torch.mps.empty_cache()
        except Exception:
            pass

    # ------------------------------------------------------------ diarization

    def diarize(self, audio: np.ndarray, progress: Callable[[float], None] | None = None) -> TrackDiarization:
        regions = energy_vad(audio)
        if not regions:
            return TrackDiarization([], "vad", ["no speech detected"])
        pipe = self.pipeline()
        notes = []
        if pipe is not None:
            try:
                return TrackDiarization(self._run_pipeline(pipe, audio, progress), f"pyannote:{self._pipeline_name}")
            except Exception as exc:
                first_error = _short_error(exc)
            try:  # MPS kernels occasionally fail: retry once on CPU
                import torch

                pipe.to(torch.device("cpu"))
                return TrackDiarization(self._run_pipeline(pipe, audio, progress), f"pyannote:{self._pipeline_name}")
            except Exception as exc:
                notes.append(f"pyannote failed: {first_error}; on CPU: {_short_error(exc)}")
        elif self._pipeline_error:
            notes.append(f"pyannote unavailable: {self._pipeline_error}")
        embed = self.embedder()
        if embed is not None:
            try:
                turns = cluster_speakers(audio, regions, embed, self.cfg.cluster_threshold, progress)
                return TrackDiarization(turns, "clustering", notes)
            except Exception as exc:
                notes.append(f"clustering failed: {_short_error(exc)}")
        elif self._embedder_error:
            notes.append(f"embedding model unavailable: {self._embedder_error}")
        return TrackDiarization([(s, e, "0") for s, e in regions], "vad", notes)

    def _run_pipeline(self, pipe, audio: np.ndarray, progress) -> RawTurns:
        import torch

        def hook(step_name, step_artifact, file=None, total=None, completed=None):
            if progress and total and completed is not None:
                weight = {"segmentation": (0.0, 0.3), "embeddings": (0.3, 0.95)}.get(step_name, (0.95, 1.0))
                progress(weight[0] + (weight[1] - weight[0]) * completed / max(total, 1))

        wav = torch.from_numpy(np.ascontiguousarray(audio, dtype=np.float32))[None]
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            out = pipe({"waveform": wav, "sample_rate": SR}, hook=hook)
        ann = getattr(out, "exclusive_speaker_diarization", None) or getattr(out, "speaker_diarization", None) or out
        return [(float(seg.start), float(seg.end), str(label)) for seg, _, label in ann.itertracks(yield_label=True)]


def _short_error(exc: Exception) -> str:
    text = " ".join(str(exc).split())
    if "GatedRepoError" in type(exc).__name__ or "gated" in text.lower() or "403" in text:
        return "access denied (gated model: accept its terms on huggingface.co)"
    if "401" in text:
        return "invalid Hugging Face token"
    return redact(f"{type(exc).__name__}: {text}")[:240]
