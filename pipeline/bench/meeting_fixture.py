"""Long synthetic two-track meetings (macOS `say`) with exact reference text and speaker turns.

The plan (who says what, when) is pure and seeded; only `synthesize` calls `say`. Output of `make_fixture`:

  <out>/meeting/        mic.wav, system.wav, meeting.json (what the menu bar app records)
  <out>/reference.json  {"duration_sec", "options", "segments": [{track, speaker, start, end, text, language}]}
  <out>/reference.rttm  the same turns as RTTM (for pyannote.metrics or other tools)

Speakers: "Me" (vi + code-switched, voice Linh) on the mic, optionally "Local 2" (en, a second person in the
room) on the mic, and "Remote 1..N" (en) on the system track. Synthetic speech has no disfluencies, so these
fixtures measure speed and memory well but quality only roughly; real fixtures are still needed (plan 0.2b).
"""

from __future__ import annotations

import json
import subprocess
import tempfile
from collections.abc import Callable
from dataclasses import asdict, dataclass
from pathlib import Path

import numpy as np
from asr_bench import MONOLOGUE, UTTERANCES

SR = 16000
SYSTEM_OFFSET_SEC = 0.12  # the system file starts slightly later, as in real captures
MEETING_NAME = "2026-10-20 0900 Meeting"
VI_LINES = [t for _, _, cat, t in UTTERANCES if cat in ("vi", "mixed")] + MONOLOGUE
EN_LINES = [t for _, _, cat, t in UTTERANCES if cat == "en"] + [
    "I checked the crash logs this morning and most of them come from the same screen.",
    "Can we move the design review to Thursday afternoon instead?",
    "The new onboarding numbers look better than last month.",
    "I think we should ship the hotfix first and then plan the bigger refactor.",
    "Let me share my screen so everyone can see the dashboard.",
    "We still need someone to own the pricing page update.",
    "Sorry, could you repeat the last part? The connection dropped for a second.",
    "That works for me, I will write it down in the meeting notes.",
]
LOCAL_VOICES = ["Linh", "Moira"]  # "Me", then a second person in the room
REMOTE_VOICES = ["Samantha", "Daniel", "Rishi", "Tessa", "Fred", "Karen"]


@dataclass
class Line:
    track: str  # mic | system
    speaker: str
    voice: str
    language: str
    text: str


@dataclass
class Placed:
    track: str
    speaker: str
    voice: str
    language: str
    text: str
    start: float
    end: float


def script(n: int, remote: int = 2, local: int = 1, seed: int = 0) -> list[Line]:
    """`n` lines of turn-taking: the mic speaks ~45 % of the lines, sometimes several in a row."""
    if not 1 <= remote <= len(REMOTE_VOICES) or not 1 <= local <= len(LOCAL_VOICES):
        raise ValueError(f"remote must be 1-{len(REMOTE_VOICES)}, local 1-{len(LOCAL_VOICES)}")
    rng = np.random.default_rng(seed)
    out: list[Line] = []
    for _ in range(n):
        if out and rng.random() < 0.25:  # the same speaker goes on
            prev = out[-1]
            pool = VI_LINES if prev.language == "vi" else EN_LINES
            out.append(Line(prev.track, prev.speaker, prev.voice, prev.language, str(rng.choice(pool))))
        elif rng.random() < 0.45:
            k = 0 if local == 1 or rng.random() < 0.6 else int(rng.integers(1, local))
            speaker = "Me" if k == 0 else f"Local {k + 1}"
            vi = k == 0
            out.append(Line("mic", speaker, LOCAL_VOICES[k], "vi" if vi else "en",
                            str(rng.choice(VI_LINES if vi else EN_LINES))))
        else:
            k = int(rng.integers(0, remote))
            out.append(Line("system", f"Remote {k + 1}", REMOTE_VOICES[k], "en", str(rng.choice(EN_LINES))))
    return out


def layout(lines: list[Line], durations: list[float], minutes: float, seed: int = 0,
           overlap_p: float = 0.08) -> list[Placed]:
    """Place lines on the meeting timeline until `minutes` are filled: 0.3-1.2 s gaps, a few longer pauses,
    and some cross-track overlaps (a remote speaker starts while the mic is still talking, or vice versa)."""
    rng = np.random.default_rng(seed + 1)
    cursor, out = 1.0, []
    for line, dur in zip(lines, durations):
        if cursor >= minutes * 60:
            break
        start = cursor
        if out and out[-1].track != line.track and rng.random() < overlap_p:
            start = max(out[-1].start + 0.5, out[-1].end - 0.6)
        start = max(start, max((p.end + 0.2 for p in out[-6:] if p.track == line.track), default=0.0))
        out.append(Placed(line.track, line.speaker, line.voice, line.language, line.text,
                          round(start, 3), round(start + dur, 3)))
        gap = rng.uniform(0.3, 1.2) + (rng.uniform(4, 8) if rng.random() < 0.03 else 0.0)
        cursor = max(cursor, start + dur + gap)
    return out


def say(voice: str, text: str, tmp: Path) -> np.ndarray:
    from meeting_notes.adapters.outbound.ffmpeg_audio import decode

    path = tmp / f"{abs(hash((voice, text)))}.aiff"
    subprocess.run(["say", "-v", voice, "-o", str(path), text], check=True)
    return decode(path)


def synthesize(lines: list[Line], tts: Callable[[str, str, Path], np.ndarray] = say) -> list[np.ndarray]:
    """Audio per line; each distinct (voice, text) is synthesized once."""
    cache: dict[tuple[str, str], np.ndarray] = {}
    with tempfile.TemporaryDirectory() as td:
        for line in lines:
            key = (line.voice, line.text)
            if key not in cache:
                cache[key] = tts(line.voice, line.text, Path(td))
    return [cache[(line.voice, line.text)] for line in lines]


def render(placed: list[Placed], clips: list[np.ndarray], bleed: bool = False, seed: int = 0) -> dict[str, np.ndarray]:
    end = max(p.end for p in placed) + 1.0
    length = int(end * SR)
    tracks = {"mic": np.zeros(length, np.float32), "system": np.zeros(length, np.float32)}
    for p, clip in zip(placed, clips):
        i = int(p.start * SR)
        tracks[p.track][i:i + len(clip)] += 0.6 * clip
    rng = np.random.default_rng(seed)
    tracks["mic"] += rng.normal(0, 0.002, length).astype(np.float32)  # room noise
    tracks["system"] += rng.normal(0, 0.0005, length).astype(np.float32)
    if bleed:
        tracks["mic"] += 0.15 * np.roll(tracks["system"], int(0.03 * SR))
    return tracks


def rttm(placed: list[Placed], uri: str = "meeting") -> str:
    return "".join(f"SPEAKER {uri} 1 {p.start:.3f} {p.end - p.start:.3f} <NA> <NA> {p.speaker.replace(' ', '_')} <NA> <NA>\n"
                   for p in sorted(placed, key=lambda p: p.start))


def make_fixture(out: Path, minutes: float, remote: int = 2, local: int = 1, bleed: bool = False, seed: int = 0,
                 tts: Callable[[str, str, Path], np.ndarray] = say) -> Path:
    from meeting_notes.adapters.outbound.wav_files import write_wav

    lines = script(int(minutes * 60 / 2.5) + 20, remote, local, seed)  # lines last >= ~2.5 s with gaps
    clips = synthesize(lines, tts)
    placed = layout(lines, [len(c) / SR for c in clips], minutes, seed)
    clips = clips[:len(placed)]
    tracks = render(placed, clips, bleed, seed)
    folder = out / "meeting"
    folder.mkdir(parents=True, exist_ok=True)
    write_wav(folder / "mic.wav", tracks["mic"])
    write_wav(folder / "system.wav", tracks["system"][int(SYSTEM_OFFSET_SEC * SR):])
    duration = round(len(tracks["mic"]) / SR, 2)
    (folder / "meeting.json").write_text(json.dumps({
        "version": 1, "title": "Meeting", "title_source": "default", "app_hint": None,
        "started_at": "2026-10-20T09:00:00+07:00", "duration_sec": duration,
        "tracks": {"mic": {"file": "mic.wav", "start_offset_sec": 0.0, "sample_rate": SR},
                   "system": {"file": "system.wav", "start_offset_sec": SYSTEM_OFFSET_SEC, "sample_rate": SR}},
        "warnings": [],
    }, indent=2))
    options = {"minutes": minutes, "remote": remote, "local": local, "bleed": bleed, "seed": seed}
    segments = [{k: v for k, v in asdict(p).items() if k != "voice"} for p in placed]
    (out / "reference.json").write_text(json.dumps({"duration_sec": duration, "options": options, "segments": segments},
                                                   ensure_ascii=False, indent=1))
    (out / "reference.rttm").write_text(rttm(placed))
    return folder
