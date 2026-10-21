"""End-to-end run on a synthetic bilingual meeting (real models + Ollama).

Slow (~1 min after models are cached). Run with: MEETING_NOTES_E2E=1 uv run pytest tests/e2e/test_e2e.py -s
"""

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

pytestmark = pytest.mark.skipif(os.environ.get("MEETING_NOTES_E2E") != "1", reason="set MEETING_NOTES_E2E=1")

HERE = Path(__file__).parent


@pytest.mark.parametrize("bleed", [False, True])
def test_synthetic_meeting(tmp_path, bleed):
    args = [sys.executable, str(HERE / "make_synthetic.py"), str(tmp_path)] + (["--bleed"] if bleed else [])
    folder = Path(subprocess.run(args, check=True, capture_output=True, text=True).stdout.strip())
    out = subprocess.run([sys.executable, "-m", "meeting_notes.entrypoints.cli", "process", str(folder), "--json"],
                         capture_output=True, text=True, timeout=1800)
    assert out.returncode == 0, out.stderr[-2000:]
    events = [json.loads(line) for line in out.stdout.splitlines()]
    done = events[-1]
    assert done["event"] == "done"
    final = Path(done["folder"])
    transcript = json.loads((final / "transcript.json").read_text())
    segs = transcript["segments"]
    truth = json.loads((tmp_path / "truth.json").read_text())
    assert len(segs) == len(truth)
    # Speaker per utterance: the mic is "Me", the two remote voices are distinct speakers.
    labels = [s["speaker"] for s in segs]
    assert labels[0::2] == ["Me"] * 4
    remote = labels[1::2]
    assert remote[0] == remote[2] and remote[1] == remote[3] and remote[0] != remote[1]
    # Per-block language detection handles the code-switching.
    assert [s["language"] for s in segs] == ["vi", "en"] * 4
    assert "giữ giá" in segs[4]["text"]
    notes = (final / "notes.md").read_text()
    assert "## Tóm tắt" in notes and "## Việc cần làm" in notes and "- [ ]" in notes
    status = json.loads((final / "status.json").read_text())
    assert status["state"] == "done"
