"""Single-voice check for the mic track: is full diarization needed, or does it hold just one voice?

`resolve_two_tracks` labels the whole mic "Me" when it finds one real cluster, so a full pyannote pass on a
single-voice mic only redraws turn boundaries. This module decides, from a few speaker embeddings, whether the
mic holds one voice. It is biased toward "several voices": anything unclear returns `single=None` and the
caller runs full diarization exactly as before.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from .clustering import agglomerative
from .intervals import Interval, subtract
from .speakers import RawTurns

# Less mic speech than this cannot hold two "real" mic clusters: resolve_two_tracks needs >= 20 s for a
# second cluster and the largest one is at least as long (>= 40 s in total); 30 s leaves margin for the
# energy VAD measuring speech differently from pyannote.
SHORT_SPEECH_SEC = 30.0
WINDOW_SEC = 3.0  # embedding window
MIN_WINDOW_SEC = 1.5  # shorter speech pieces are not embedded
MAX_WINDOWS = 48  # spread over the meeting; a second voice with >= 15 % of the speech gets ~7 windows
MIN_WINDOWS = 8  # fewer usable windows: unsure
# Average-linkage cosine distance that splits voices. Same voice (3 s windows): ~0.17-0.28 on synthetic
# voices; the closest pair of different synthetic voices averages 0.47. Lower = more "several voices".
SPLIT_DIST = 0.45
MAX_STRAY_SHARE = 0.10  # windows matching no other window (cough, laugh, noise): more than this = unsure


@dataclass
class VoiceCheck:
    """Result of a mic voice check: VAD turns for the single-voice path, and the verdict.

    single: True = one voice (skip full diarization), False = several voices, None = unsure."""

    turns: RawTurns
    single: bool | None
    reason: str


def check_windows(regions: list[Interval], exclude: list[Interval] | None = None, max_windows: int = MAX_WINDOWS,
                  window: float = WINDOW_SEC, min_len: float = MIN_WINDOW_SEC) -> list[Interval]:
    """Embedding windows: speech regions minus `exclude` (remote speech: bleed, crosstalk), cut into
    `window`-second pieces, at most `max_windows` of them spread evenly over time."""
    pieces: list[Interval] = []
    for s, e in subtract(sorted(regions), exclude or []):
        t = s
        while e - t >= min_len:
            pieces.append((t, min(e, t + window)))
            t += window
    if len(pieces) <= max_windows:
        return pieces
    idx = np.linspace(0, len(pieces) - 1, max_windows).round().astype(int)
    return [pieces[i] for i in sorted(set(idx.tolist()))]


def precheck(speech_sec: float, n_windows: int) -> tuple[bool | None, str] | None:
    """Verdict that needs no embeddings, or None when the embeddings must decide."""
    if speech_sec < SHORT_SPEECH_SEC:
        return True, f"{speech_sec:.0f} s of mic speech: too little for a second voice"
    if n_windows < MIN_WINDOWS:
        return None, f"only {n_windows} usable windows"
    return None


def single_voice(embeddings: np.ndarray, speech_sec: float) -> tuple[bool | None, str]:
    """(verdict, reason) from window embeddings (one row per window) and the mic's total speech seconds."""
    n = len(embeddings)
    early = precheck(speech_sec, n)
    if early is not None:
        return early
    emb = np.asarray(embeddings, dtype=np.float64)
    norms = np.linalg.norm(emb, axis=1, keepdims=True)
    if not np.all(np.isfinite(emb)) or np.any(norms < 1e-9):
        return None, "invalid embeddings"
    labels = agglomerative(emb / norms, SPLIT_DIST)
    sizes = np.bincount(labels)
    groups = int((sizes >= 2).sum())
    strays = int((sizes == 1).sum())
    if groups > 1:
        return False, f"{groups} voices in {n} windows"
    if groups == 0 or strays > MAX_STRAY_SHARE * n:
        return None, f"{strays} of {n} windows match no other window"
    return True, f"one voice in {n - strays} of {n} windows"
