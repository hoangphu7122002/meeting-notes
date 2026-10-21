"""Signals shared by several test modules."""

import numpy as np

from meeting_notes.domain.signal import SR


def tone(sec, amp=0.3, sr=SR, freq=220.0):
    t = np.arange(int(sec * sr)) / sr
    return (amp * np.sin(2 * np.pi * freq * t)).astype(np.float32)


def speechlike(sec, f0=140.0):
    t = np.arange(int(sec * SR)) / SR
    return (0.2 * np.sign(np.sin(2 * np.pi * f0 * t)) * (0.6 + 0.4 * np.sin(2 * np.pi * 3 * t))).astype(np.float32)
