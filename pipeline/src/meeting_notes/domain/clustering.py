"""Clustering fallback for speaker diarization: embed short windows, group them by cosine distance."""

from __future__ import annotations

from collections.abc import Callable

import numpy as np

from .intervals import Interval
from .signal import SR
from .speakers import RawTurns


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
