"""Fakes for live transcription tests: a voice track builder and a transcriber whose text names the pitch."""

import numpy as np
from helpers import room, speechlike

from meeting_notes.domain.live_backlog import LoadSample
from meeting_notes.domain.signal import SR


def voice_track(total_sec, spans, f0, seed=1):
    """Room tone with speech-like bursts at `spans` [(start, end)] seconds."""
    x = room(total_sec, seed)
    for s, e in spans:
        a = int(s * SR)
        burst = speechlike(e - s, f0)
        x[a:a + len(burst)] += burst
    return x


class PitchTranscriber:
    """Whisper stand-in: one segment over the voiced part, text = the dominant pitch (same audio, same text)."""

    cfg = None

    def __init__(self):
        self.calls = 0

    def detect_language(self, audio):
        return {"vi": 0.9, "en": 0.1}

    def transcribe(self, audio, language):
        self.calls += 1
        spectrum = np.abs(np.fft.rfft(audio * np.hanning(len(audio))))
        freqs = np.fft.rfftfreq(len(audio), 1 / SR)
        band = (freqs > 60) & (freqs < 500)
        f0 = freqs[band][np.argmax(spectrum[band])]
        return [{"start": 0.0, "end": len(audio) / SR, "text": f" voice {int(round(f0 / 10)) * 10} ",
                 "no_speech_prob": 0.01, "avg_logprob": -0.2, "compression_ratio": 1.1}]

    def transcribe_auto(self, audio, choose):
        language = choose(self.detect_language(audio))
        return language, self.transcribe(audio, language)

    def release(self):
        pass


class FakeModels:
    def __init__(self, transcriber=None):
        self.tr = transcriber or PitchTranscriber()
        self.released = 0

    def transcriber(self):
        return self.tr

    def diarizer(self):
        raise AssertionError("live never diarizes")

    def done_with_transcriber(self):
        self.released += 1

    def done_with_diarizer(self):
        pass


class ListStore:
    def __init__(self, lines=None):
        self.lines = list(lines or [])

    def load(self):
        return list(self.lines)

    def append(self, chunk):
        self.lines.append(dict(chunk))


class Probe:
    def __init__(self, *samples):
        self.samples = list(samples) or [LoadSample(1, 0.1, 0, False)]
        self.n = 0

    def sample(self):
        self.n += 1
        return self.samples[min(self.n - 1, len(self.samples) - 1)]


class Events:
    """ProgressReporter stand-in that records live events."""

    log_file = None
    audio_sec = None
    timings: dict = {}

    def __init__(self):
        self.segments, self.status, self.polish = [], [], []

    def live_segment(self, track, speaker, seq, start, end, language, text):
        self.segments.append({"track": track, "speaker": speaker, "seq": seq, "start": start, "end": end, "text": text})

    def live_polish(self, track, speaker, para, seqs, tier, text):
        self.polish.append({"track": track, "speaker": speaker, "para": para, "seqs": list(seqs), "tier": tier,
                            "text": text})

    def live_status(self, state, backlog_sec, skipped_sec, rtf, reason=None):
        self.status.append({"state": state, "backlog_sec": backlog_sec, "skipped_sec": skipped_sec, "reason": reason})

    def log(self, message):
        pass


class StreamSource:
    """LiveAudioSource over in-memory tracks: each poll releases `step` seconds (a fake clock)."""

    def __init__(self, tracks, step=1.0, offsets=None):
        self.audio, self.step = tracks, step
        self.offsets = offsets or {t: 0.0 for t in tracks}
        self.sent = {t: 0 for t in tracks}
        self.polls = 0

    def tracks(self):
        return sorted(self.audio)

    def poll(self, track, max_sec):
        self.polls += 1
        x, a = self.audio[track], self.sent[track]
        z = min(len(x), a + int(min(self.step, max_sec) * SR))
        self.sent[track] = z
        return self.offsets[track] + a / SR, x[a:z]

    def position(self, track):
        return self.offsets[track] + self.sent[track] / SR

    def finished(self):
        return all(self.sent[t] >= len(x) for t, x in self.audio.items())


class Stop:
    """Never set unless told; wait() returns immediately (the fake source is the clock)."""

    def __init__(self, after_waits=None):
        self.flag, self.after, self.waits = False, after_waits, 0

    def is_set(self):
        return self.flag

    def set(self):
        self.flag = True

    def wait(self, timeout=None):
        self.waits += 1
        if self.after is not None and self.waits >= self.after:
            self.flag = True
        return self.flag
