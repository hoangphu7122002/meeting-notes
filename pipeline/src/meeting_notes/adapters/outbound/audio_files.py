"""Audio port implementation: ffmpeg for media files (macOS afconvert when ffmpeg is not installed, e.g. the
packaged app), soundfile for the working WAVs."""

from __future__ import annotations

from pathlib import Path

import numpy as np

from . import afconvert_audio, ffmpeg_audio, wav_files


def media_backend():
    """ffmpeg when installed (any format), else afconvert (built into macOS)."""
    try:
        ffmpeg_audio.ffmpeg_bin()
        return ffmpeg_audio
    except RuntimeError:
        if afconvert_audio.available():
            return afconvert_audio
        raise


class AudioFiles:
    def decode(self, path: Path) -> np.ndarray:
        return media_backend().decode(path)

    def encode_m4a(self, inputs: list[tuple[Path, float]], dest: Path) -> None:
        media_backend().encode_m4a(inputs, dest)

    def read_wav(self, path: Path) -> np.ndarray:
        return wav_files.read_wav(path)

    def write_wav(self, path: Path, audio: np.ndarray) -> None:
        wav_files.write_wav(path, audio)
