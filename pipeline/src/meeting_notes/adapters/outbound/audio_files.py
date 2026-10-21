"""Audio port implementation: ffmpeg for media files, soundfile for the working WAVs."""

from __future__ import annotations

from pathlib import Path

import numpy as np

from . import ffmpeg_audio, wav_files


class AudioFiles:
    def decode(self, path: Path) -> np.ndarray:
        return ffmpeg_audio.decode(path)

    def encode_m4a(self, inputs: list[tuple[Path, float]], dest: Path) -> None:
        ffmpeg_audio.encode_m4a(inputs, dest)

    def read_wav(self, path: Path) -> np.ndarray:
        return wav_files.read_wav(path)

    def write_wav(self, path: Path, audio: np.ndarray) -> None:
        wav_files.write_wav(path, audio)
