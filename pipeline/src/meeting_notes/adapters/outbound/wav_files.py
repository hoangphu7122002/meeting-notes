"""16-bit WAV files for the 16 kHz working tracks (soundfile)."""

from __future__ import annotations

from pathlib import Path

import numpy as np
import soundfile as sf

from ...domain.signal import SR


def write_wav(path: Path, audio: np.ndarray, sr: int = SR) -> None:
    sf.write(str(path), audio, sr, subtype="PCM_16")


def read_wav(path: Path) -> np.ndarray:
    audio, _ = sf.read(str(path), dtype="float32")
    return audio
