"""Diarize the recorded tracks and resolve them into labelled speaker turns."""

from __future__ import annotations

from collections.abc import Callable

import numpy as np

from ..config import Config
from ..domain.intervals import Interval, dilate
from ..domain.signal import bleed_ratio, energy_vad
from ..domain.speakers import TrackDiarization, Turn, resolve_single_track, resolve_two_tracks
from .ports import Diarizer, ProgressReporter

SINGLE_VOICE = "single-voice"  # mic method when full diarization was skipped


def diarize_tracks(tracks: dict[str, np.ndarray], diarizer: Diarizer, cfg: Config,
                   reporter: ProgressReporter) -> tuple[list[Turn], list[str], list[str]]:
    """(turns, methods, notes): mic + system are diarized separately and merged; one track is resolved alone."""
    if "system" in tracks and "mic" in tracks:
        reporter.progress(0.0, "Finding remote speakers")
        sys_d = diarizer.diarize(tracks["system"], lambda f: reporter.progress(0.6 * f, "Finding remote speakers"))
        reporter.progress(0.6, "Finding local speakers")
        remote = [(s, e) for s, e, _ in sys_d.turns]
        mic_d = diarize_mic(tracks["mic"], remote, diarizer, cfg, reporter,
                            lambda f: reporter.progress(0.6 + 0.4 * f, "Finding local speakers"))
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
        progress = lambda f: reporter.progress(f, "Finding speakers")  # noqa: E731
        if name == "mic":  # mic only (system audio not captured): the user, unless several voices
            d = diarize_mic(tracks[name], [], diarizer, cfg, reporter, progress)
            turns = resolve_two_tracks(d.turns, [], False, cfg.me_name, cfg.mic_speakers)
        else:
            d = diarizer.diarize(tracks[name], progress)
            single = ("Others" if name == "system" else "Speaker") if d.method == "vad" else None
            turns = resolve_single_track(d.turns, name, single)
        methods, notes = [f"{name}={d.method}"], d.notes
    return turns, methods, notes


def diarize_mic(audio: np.ndarray, remote: list[Interval], diarizer: Diarizer, cfg: Config,
                reporter: ProgressReporter, progress: Callable[[float], None]) -> TrackDiarization:
    """Full diarization of the mic track, unless it surely holds one voice (cfg.mic_voice_check).

    The single-voice path only changes turn boundaries (voice activity instead of pyannote); labels stay
    "Me". When the check is unsure or hears several voices, the full path runs exactly as without the check."""
    if cfg.mic_voice_check:
        if cfg.mic_speakers == "me":  # every mic turn is the user anyway: no check needed
            reporter.log("mic voice check: skipped full diarization (mic_speakers = me)")
            return TrackDiarization([(s, e, "0") for s, e in energy_vad(audio)], SINGLE_VOICE,
                                    ["mic: full diarization skipped (mic_speakers = me)"])
        check = diarizer.voice_check(audio, dilate(remote, 0.05, 0.35))
        verdict = {True: "one voice", False: "several voices", None: "unsure"}[check.single]
        reporter.log(f"mic voice check: {verdict} ({check.reason})")
        if check.single is True:
            progress(1.0)
            return TrackDiarization(check.turns, SINGLE_VOICE, [f"mic: one voice ({check.reason}); full diarization skipped"])
    return diarizer.diarize(audio, progress)
