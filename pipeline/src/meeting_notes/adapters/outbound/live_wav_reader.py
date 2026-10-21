"""Tail the WAVs that the app is still writing (LiveAudioSource for live transcription).

`TrackWriter` (AVAudioFile) writes 16-bit mono PCM; Core Audio may put padding chunks such as `FLLR` before
`data`, and the header sizes stay stale until the file is closed. So the RIFF chunks are walked to find `data`
and then everything up to EOF is read in whole frames. Samples are resampled to 16 kHz in blocks aligned to
the resampling ratio with context on both sides, so the stream equals one resample of the whole file. File
positions map to recorded time with the track's `start_offset_sec` from the provisional `meeting.json`.
"""

from __future__ import annotations

import json
import struct
from math import gcd
from pathlib import Path

import numpy as np

from ...domain.signal import SR

CONTEXT_SEC = 0.02  # resampling filter context kept on each side of a block


class WavTail:
    """Incremental reader of one growing WAV file, returning 16 kHz float32 audio."""

    def __init__(self, path: Path):
        self.path = path
        self.data_offset: int | None = None
        self.rate = 0
        self.channels = 1
        self.width = 2  # bytes per sample
        self.float = False
        self.read_frames = 0  # source frames read from the file
        self.pending = np.zeros(0, np.float32)  # source samples not yet resampled (incl. left context)
        self.pending_from = 0  # source frame index of pending[0]
        self.done = 0  # source frames already turned into output
        self.out_samples = 0

    # ------------------------------------------------------------ header

    def _parse_header(self) -> bool:
        """Find `fmt ` and the start of `data`; False while the header is not complete yet."""
        try:
            with self.path.open("rb") as f:
                head = f.read(65536)
        except OSError:
            return False
        if len(head) < 12 or head[:4] != b"RIFF" or head[8:12] != b"WAVE":
            return False
        pos, fmt = 12, None
        while pos + 8 <= len(head):
            cid, size = head[pos:pos + 4], struct.unpack("<I", head[pos + 4:pos + 8])[0]
            body = pos + 8
            if cid == b"fmt ":
                if body + 16 > len(head):
                    return False
                tag, channels, rate, _, _, bits = struct.unpack("<HHIIHH", head[body:body + 16])
                if tag == 0xFFFE and size >= 40 and body + 26 <= len(head):
                    tag = struct.unpack("<H", head[body + 24:body + 26])[0]  # WAVE_FORMAT_EXTENSIBLE subformat
                fmt = (tag, channels, rate, bits)
            elif cid == b"data":
                if fmt is None:
                    return False
                tag, channels, rate, bits = fmt
                if not ((tag == 1 and bits == 16) or (tag == 3 and bits == 32)):
                    raise ValueError(f"{self.path.name}: unsupported WAV format {tag}/{bits} bit")
                self.data_offset, self.rate, self.channels = body, rate, max(1, channels)
                self.width, self.float = bits // 8, tag == 3
                return True
            pos = body + size + (size & 1)
        return False

    # ------------------------------------------------------------ reading

    def read(self, max_sec: float, final: bool = False) -> np.ndarray:
        """New 16 kHz samples (at most ~max_sec). `final` flushes the right context (file closed)."""
        if self.data_offset is None and not self._parse_header():
            return np.zeros(0, np.float32)
        frame = self.width * self.channels
        try:
            size = self.path.stat().st_size
        except OSError:
            return np.zeros(0, np.float32)
        available = max(0, (size - self.data_offset) // frame - self.read_frames)
        count = min(available, int(max_sec * self.rate))
        if count > 0:
            with self.path.open("rb") as f:
                f.seek(self.data_offset + self.read_frames * frame)
                raw = f.read(count * frame)
            count = len(raw) // frame
            dtype = "<f4" if self.float else "<i2"
            x = np.frombuffer(raw[: count * frame], dtype=dtype).astype(np.float32)
            if not self.float:
                x /= 32768.0
            if self.channels > 1:
                x = x.reshape(-1, self.channels).mean(axis=1)
            self.pending = np.concatenate([self.pending, x])
            self.read_frames += count
        return self._resample(final)

    def _resample(self, final: bool) -> np.ndarray:
        if self.rate == SR:
            out = self.pending[self.done - self.pending_from:]
            self.done = self.read_frames
            self.pending, self.pending_from = np.zeros(0, np.float32), self.done
            self.out_samples += out.size
            return out
        from scipy.signal import resample_poly

        g = gcd(SR, self.rate)
        up, down = SR // g, self.rate // g
        ctx = -(-int(CONTEXT_SEC * self.rate) // down) * down  # context rounded up to whole `down` blocks
        end = self.read_frames if final else self.read_frames - ctx
        end = self.done + max(0, (end - self.done) // down * down)
        if final and end < self.read_frames:
            end = self.read_frames
        if end <= self.done:
            return np.zeros(0, np.float32)
        lo = max(self.pending_from, self.done - ctx)
        hi = min(self.read_frames, end + ctx)
        y = resample_poly(self.pending[lo - self.pending_from:hi - self.pending_from], up, down).astype(np.float32)
        a = (self.done - lo) * up // down
        n = -(-(end - self.done) * up // down) if final else (end - self.done) * up // down
        out = y[a:a + n]
        self.done = end
        keep = max(self.pending_from, self.done - ctx)
        self.pending, self.pending_from = self.pending[keep - self.pending_from:], keep
        self.out_samples += out.size
        return out


class LiveWavSource:
    """LiveAudioSource over `<folder>/mic.wav` and `system.wav` while the app records them."""

    def __init__(self, folder: Path):
        self.folder = folder
        self.tails: dict[str, WavTail] = {}
        self.offsets: dict[str, float] = {}

    def tracks(self) -> list[str]:
        if not self.tails:
            try:
                meta = json.loads((self.folder / "meeting.json").read_text(encoding="utf-8"))
            except (OSError, ValueError):
                return []
            for name, info in (meta.get("tracks") or {}).items():
                if str(info.get("file", "")).lower().endswith(".wav") and info.get("start_offset_sec") is not None:
                    self.tails[name] = WavTail(self.folder / info["file"])
                    self.offsets[name] = float(info["start_offset_sec"])
        return sorted(self.tails)

    def poll(self, track: str, max_sec: float) -> tuple[float, np.ndarray]:
        tail = self.tails[track]
        start = self.offsets[track] + tail.out_samples / SR
        return start, tail.read(max_sec)

    def position(self, track: str) -> float:
        tail = self.tails[track]
        if tail.data_offset is None or tail.rate <= 0:
            return self.offsets[track]
        try:
            frames = (tail.path.stat().st_size - tail.data_offset) // (tail.width * tail.channels)
        except OSError:
            frames = tail.read_frames
        return self.offsets[track] + max(0, frames) / tail.rate

    def finished(self) -> bool:
        return False
