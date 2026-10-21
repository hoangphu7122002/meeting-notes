"""Diarize the recorded tracks and resolve them into labelled speaker turns."""

from __future__ import annotations

import numpy as np

from ..config import Config
from ..domain.signal import bleed_ratio
from ..domain.speakers import Turn, resolve_single_track, resolve_two_tracks
from .ports import Diarizer, ProgressReporter


def diarize_tracks(tracks: dict[str, np.ndarray], diarizer: Diarizer, cfg: Config,
                   reporter: ProgressReporter) -> tuple[list[Turn], list[str], list[str]]:
    """(turns, methods, notes): mic + system are diarized separately and merged; one track is resolved alone."""
    if "system" in tracks and "mic" in tracks:
        reporter.progress(0.0, "Finding remote speakers")
        sys_d = diarizer.diarize(tracks["system"], lambda f: reporter.progress(0.6 * f, "Finding remote speakers"))
        reporter.progress(0.6, "Finding local speakers")
        mic_d = diarizer.diarize(tracks["mic"], lambda f: reporter.progress(0.6 + 0.4 * f, "Finding local speakers"))
        remote = [(s, e) for s, e, _ in sys_d.turns]
        bleed_corr = bleed_ratio(tracks["mic"], tracks["system"], remote)
        bleed = bleed_corr > 0.35
        others = "Others" if sys_d.method == "vad" else None
        turns = resolve_two_tracks(mic_d.turns, sys_d.turns, bleed, cfg.me_name, cfg.mic_speakers, others)
        methods = [f"system={sys_d.method}", f"mic={mic_d.method}"]
        notes = sys_d.notes + [n for n in mic_d.notes if n not in sys_d.notes]
        if bleed:
            notes.append(f"mic picks up speaker audio (corr {bleed_corr:.2f}); mic speech during remote speech was dropped")
    else:
        name = next(iter(tracks))
        d = diarizer.diarize(tracks[name], lambda f: reporter.progress(f, "Finding speakers"))
        if name == "mic":  # mic only (system audio not captured): the user, unless several voices
            turns = resolve_two_tracks(d.turns, [], False, cfg.me_name, cfg.mic_speakers)
        else:
            single = ("Others" if name == "system" else "Speaker") if d.method == "vad" else None
            turns = resolve_single_track(d.turns, name, single)
        methods, notes = [f"{name}={d.method}"], d.notes
    return turns, methods, notes
