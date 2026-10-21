"""Build a synthetic bilingual meeting with macOS `say`.

Writes <out>/<name>/ with mic.wav ("Me", Vietnamese voice Linh), system.wav (two English
remote voices) and meeting.json, mimicking what the menu bar app records, plus <out>/mixed.wav
(all voices in one file) for the `import` path.

Usage: uv run python tests/e2e/make_synthetic.py <out_dir> [--bleed]
"""

from __future__ import annotations

import argparse
import json
import subprocess
import tempfile
from pathlib import Path

import numpy as np

from meeting_notes.adapters.outbound.ffmpeg_audio import decode
from meeting_notes.adapters.outbound.wav_files import write_wav
from meeting_notes.domain.signal import SR, mix

SCRIPT = [
    ("mic", "Linh", "Chào mọi người, hôm nay mình họp nhanh về việc ra mắt phiên bản hai của ứng dụng ghi chú cuộc họp."),
    ("system", "Samantha", "Thanks. The beta build is ready, but we still have two crash reports from users on macOS fourteen."),
    ("mic", "Linh", "Được rồi, vậy chị Sarah sẽ sửa lỗi crash đó trước thứ sáu tuần này nhé."),
    ("system", "Daniel", "I can update the landing page and the pricing table by next Monday."),
    ("mic", "Linh", "Tốt. Chúng ta quyết định giữ giá cũ là năm đô la một tháng, không tăng giá trong quý này."),
    ("system", "Samantha", "Agreed. One open question: do we support Windows next year or not?"),
    ("mic", "Linh", "Câu đó mình chưa trả lời được, để buổi họp sau bàn tiếp."),
    ("system", "Daniel", "Sounds good. I will also send the release notes to the marketing team tomorrow."),
]
GAP_SEC = 0.8
SYSTEM_OFFSET_SEC = 0.12  # the system track starts slightly later, as in real captures


def say(voice: str, text: str, tmp: Path, i: int) -> np.ndarray:
    path = tmp / f"{i:02d}.aiff"
    subprocess.run(["say", "-v", voice, "-o", str(path), text], check=True)
    return decode(path)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("out", type=Path)
    ap.add_argument("--name", default="2026-10-19 0900 Meeting")
    ap.add_argument("--bleed", action="store_true", help="mix an attenuated copy of the remote voices into the mic")
    args = ap.parse_args()

    with tempfile.TemporaryDirectory() as td:
        clips = [(track, say(voice, text, Path(td), i)) for i, (track, voice, text) in enumerate(SCRIPT)]
    cursor = 1.0
    placed = []
    for track, clip in clips:
        placed.append((track, cursor, clip))
        cursor += len(clip) / SR + GAP_SEC
    length = int((cursor + 1.0) * SR)
    tracks = {"mic": np.zeros(length, np.float32), "system": np.zeros(length, np.float32)}
    for track, start, clip in placed:
        i = int(start * SR)
        tracks[track][i:i + len(clip)] += 0.6 * clip
    rng = np.random.default_rng(0)
    tracks["mic"] += rng.normal(0, 0.002, length).astype(np.float32)  # room noise
    if args.bleed:
        tracks["mic"] += 0.15 * np.roll(tracks["system"], int(0.03 * SR))

    folder = args.out / args.name
    folder.mkdir(parents=True, exist_ok=True)
    write_wav(folder / "mic.wav", tracks["mic"])
    shift = int(SYSTEM_OFFSET_SEC * SR)  # the system file itself starts later; meeting.json records it
    write_wav(folder / "system.wav", tracks["system"][shift:])
    (folder / "meeting.json").write_text(json.dumps({
        "version": 1, "title": "Meeting", "title_source": "default", "app_hint": None,
        "started_at": "2026-10-19T09:00:00+07:00", "ended_at": "2026-10-19T09:01:00+07:00",
        "duration_sec": round(length / SR, 2),
        "tracks": {"mic": {"file": "mic.wav", "start_offset_sec": 0.0, "sample_rate": SR},
                   "system": {"file": "system.wav", "start_offset_sec": SYSTEM_OFFSET_SEC, "sample_rate": SR}},
        "warnings": [],
    }, indent=2))
    write_wav(args.out / "mixed.wav", mix([tracks["mic"], tracks["system"]]))
    truth = [{"start": round(s, 2), "end": round(s + len(c) / SR, 2), "track": t} for t, s, c in placed]
    (args.out / "truth.json").write_text(json.dumps(truth, indent=2))
    print(folder)


if __name__ == "__main__":
    main()
