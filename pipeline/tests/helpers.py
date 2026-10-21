"""Signals shared by several test modules."""

import numpy as np

from meeting_notes.domain.signal import SR


def tone(sec, amp=0.3, sr=SR, freq=220.0):
    t = np.arange(int(sec * sr)) / sr
    return (amp * np.sin(2 * np.pi * freq * t)).astype(np.float32)


def speechlike(sec, f0=140.0):
    t = np.arange(int(sec * SR)) / SR
    return (0.2 * np.sign(np.sin(2 * np.pi * f0 * t)) * (0.6 + 0.4 * np.sin(2 * np.pi * 3 * t))).astype(np.float32)


def room(sec, seed=1):
    """Room tone, not digital zero: frame_db ignores frames below -90 dB when estimating the noise floor."""
    return (0.002 * np.random.default_rng(seed).standard_normal(int(sec * SR))).astype(np.float32)


def continuous(sec):
    """Amplitude-modulated tone: dips every 0.33 s, never a 0.7 s pause."""
    t = np.arange(int(sec * SR)) / SR
    return (tone(sec) * (0.01 + np.abs(np.sin(2 * np.pi * 1.5 * t)) ** 3)).astype(np.float32)
