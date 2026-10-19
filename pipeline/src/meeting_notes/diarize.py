"""Speaker diarization: pyannote pipeline (gated) -> embedding clustering (ungated) -> VAD only."""

from __future__ import annotations

import os
import warnings
from collections.abc import Callable
from dataclasses import dataclass, field

import numpy as np

from .audio import SR, Interval, energy_vad
from .config import Config, hf_token, redact

os.environ.setdefault("PYANNOTE_METRICS_ENABLED", "false")
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")

RawTurns = list[tuple[float, float, str]]


@dataclass
class TrackDiarization:
    turns: RawTurns
    method: str  # "pyannote:<model>" | "clustering" | "vad"
    notes: list[str] = field(default_factory=list)


def _device(pref: str):
    import torch

    from .resources import apply_torch_threads

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


def cluster_speakers(
    audio: np.ndarray,
    regions: list[Interval],
    embed: Callable[[np.ndarray], np.ndarray],
    threshold: float = 0.6,
    progress: Callable[[float], None] | None = None,
    window: float = 2.0,
    min_window: float = 0.8,
) -> RawTurns:
    """Fallback diarization: split speech regions into short windows, embed, cluster (cosine, average linkage)."""
    windows: list[Interval] = []
    for s, e in regions:
        n = max(1, int(round((e - s) / window)))
        step = (e - s) / n
        windows += [(s + i * step, s + (i + 1) * step) for i in range(n)]
    usable = [i for i, (s, e) in enumerate(windows) if e - s >= min_window]
    if len(usable) < 2:
        return [(s, e, "0") for s, e in regions]

    vectors = []
    for k, i in enumerate(usable):
        s, e = windows[i]
        vectors.append(embed(audio[int(s * SR): int(e * SR)]))
        if progress and k % 10 == 0:
            progress(0.9 * k / len(usable))
    emb = np.stack(vectors).astype(np.float64)
    emb /= np.maximum(np.linalg.norm(emb, axis=1, keepdims=True), 1e-9)
    labels = agglomerative(emb, threshold)
    labels = absorb_small_clusters(emb, labels, [windows[i][1] - windows[i][0] for i in usable])

    assigned: dict[int, int] = dict(zip(usable, labels))
    centers = np.array([(windows[i][0] + windows[i][1]) / 2 for i in usable])
    out: RawTurns = []
    for i, (s, e) in enumerate(windows):
        if i not in assigned:  # short window: take the temporally nearest labelled window
            assigned[i] = int(labels[int(np.argmin(np.abs(centers - (s + e) / 2)))])
        label = str(assigned[i])
        if out and out[-1][2] == label and abs(out[-1][1] - s) < 1e-6:
            out[-1] = (out[-1][0], e, label)
        else:
            out.append((s, e, label))
    if progress:
        progress(1.0)
    return out


def agglomerative(emb: np.ndarray, threshold: float) -> np.ndarray:
    from scipy.cluster.hierarchy import fcluster, linkage

    if len(emb) == 1:
        return np.zeros(1, dtype=int)
    z = linkage(emb, method="average", metric="cosine")
    return fcluster(z, t=threshold, criterion="distance") - 1


def absorb_small_clusters(emb: np.ndarray, labels: np.ndarray, durations: list[float], min_share: float = 0.05, min_sec: float = 4.0) -> np.ndarray:
    """Merge clusters with little speech into the nearest large cluster (by centroid cosine)."""
    labels = labels.copy()
    dur = np.asarray(durations)
    totals = {c: float(dur[labels == c].sum()) for c in np.unique(labels)}
    all_sec = sum(totals.values())
    big = [c for c, t in totals.items() if t >= min_sec and t >= min_share * all_sec]
    if not big:
        big = [max(totals, key=totals.get)]
    centroids = {c: emb[labels == c].mean(axis=0) for c in big}
    for c in totals:
        if c in big:
            continue
        v = emb[labels == c].mean(axis=0)
        nearest = max(big, key=lambda b: float(np.dot(v, centroids[b]) / (np.linalg.norm(v) * np.linalg.norm(centroids[b]) + 1e-9)))
        labels[labels == c] = nearest
    _, relabeled = np.unique(labels, return_inverse=True)
    return relabeled


def _short_error(exc: Exception) -> str:
    text = " ".join(str(exc).split())
    if "GatedRepoError" in type(exc).__name__ or "gated" in text.lower() or "403" in text:
        return "access denied (gated model: accept its terms on huggingface.co)"
    if "401" in text:
        return "invalid Hugging Face token"
    return redact(f"{type(exc).__name__}: {text}")[:240]
