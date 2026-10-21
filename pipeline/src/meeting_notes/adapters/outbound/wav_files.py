"""16-bit WAV files for the 16 kHz working tracks (soundfile, imported lazily)."""

from __future__ import annotations

from pathlib import Path
from typing import TYPE_CHECKING

from ...domain.signal import SR

if TYPE_CHECKING:
    import numpy as np


def write_wav(path: Path, audio: np.ndarray, sr: int = SR) -> None:
    import soundfile as sf

    sf.write(str(path), audio, sr, subtype="PCM_16")


def read_wav(path: Path) -> np.ndarray:
    import soundfile as sf

    audio, _ = sf.read(str(path), dtype="float32")
    return audio
