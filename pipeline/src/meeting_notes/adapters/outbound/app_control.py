"""The MeetingNotes app from the command line: its state file and the meetingnotes:// URL scheme."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

APP_STATE = Path("~/Library/Application Support/MeetingNotes/state.json").expanduser()


def read_app_state():
    """The app's parsed state.json; raises OSError/ValueError when it is missing or unreadable (app not running)."""
    return json.loads(APP_STATE.read_text())


def send_app_command(action: str) -> int:
    """Open meetingnotes://<action>; only `show` and `start` bring the app to the front."""
    flags = [] if action in ("show", "start") else ["-g"]
    return subprocess.run(["open", *flags, f"meetingnotes://{action}"], check=False).returncode
