"""scripts/install.sh: dry run changes nothing, and a running MeetingNotes is never quit while it records.

Every external tool the script could run is a stub that logs its call (HOME and PATH are isolated), so even a broken
guard cannot install anything from a test."""

import json
import os
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[4]
INSTALL = ROOT / "scripts" / "install.sh"
STUBS = ("brew", "swift", "curl", "open", "osascript", "codesign", "xcode-select", "ditto")


@pytest.fixture
def env(tmp_path):
    bin_dir, home = tmp_path / "bin", tmp_path / "home"
    bin_dir.mkdir()
    home.mkdir()
    calls = tmp_path / "calls.log"
    for name in STUBS:
        stub = bin_dir / name
        stub.write_text(f'#!/bin/sh\necho "{name} $*" >> "{calls}"\n[ "$1" = "-p" ] && exit 0\nexit 1\n')
        stub.chmod(0o755)
    pgrep = bin_dir / "pgrep"
    pgrep.write_text('#!/bin/sh\n[ -n "$FAKE_APP_PID" ] && echo "$FAKE_APP_PID"\nexit 0\n')
    pgrep.chmod(0o755)
    for tool in ("ffmpeg", "ollama"):  # already installed
        (bin_dir / tool).write_text("#!/bin/sh\nexit 0\n")
        (bin_dir / tool).chmod(0o755)
    state = tmp_path / "state.json"
    base = {"HOME": str(home), "PATH": f"{bin_dir}:/usr/bin:/bin:/usr/sbin:/sbin", "MN_APP_STATE_FILE": str(state)}
    return {"base": base, "state": state, "calls": calls, "bin": bin_dir}


def run(env, *args, app_state=None):
    extra = {}
    if app_state is not None:
        env["state"].write_text(json.dumps({"state": app_state, "processing": None, "queue": 0}))
        extra["FAKE_APP_PID"] = "4242"
    proc = subprocess.run(["bash", str(INSTALL), *args], capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL,
                          env={**env["base"], **extra}, cwd=ROOT)
    calls = env["calls"].read_text().splitlines() if env["calls"].exists() else []
    return proc, [c for c in calls if not c.startswith(("xcode-select -p", "curl "))]  # read-only checks


def test_dry_run_prints_the_plan_and_every_command_but_runs_nothing(env):
    proc, calls = run(env, "--dry-run")
    assert proc.returncode == 0, proc.stderr
    out = proc.stdout
    assert "install  brew: uv" in out and "Homebrew (official" not in out  # brew is a stub, uv is missing
    assert "FluidAudio (~21 MB, no login)" in out
    for command in ("brew install uv", "sync --project", "--product MeetingNotesDiarize", "meeting-notes setup",
                    "scripts/build-app.sh", "meeting-notes doctor"):
        assert any(line.startswith("+ ") and command in line for line in out.splitlines()), command
    assert "dry run: nothing was changed" in out and calls == []


def test_skip_models_leaves_out_setup(env):
    proc, _ = run(env, "--dry-run", "--skip-models")
    assert proc.returncode == 0 and "meeting-notes setup" not in proc.stdout


@pytest.mark.parametrize("state", ["recording", "paused", "starting", "stopping", "garbage"])
def test_a_recording_app_stops_the_install_before_anything_runs(env, state):
    for args in (("--dry-run",), ("--yes",)):  # --yes is not enough: only --force quits a recording app
        proc, calls = run(env, *args, app_state=state)
        assert proc.returncode == 1 and "recording" in proc.stderr and "--force" in proc.stderr
        assert "==> Plan" not in proc.stdout and calls == []


def test_unreadable_state_counts_as_recording(env):
    env["base"]["MN_APP_STATE_FILE"] = str(env["state"].parent / "missing.json")
    proc, calls = run(env, "--yes", app_state="idle")
    assert proc.returncode == 1 and "unknown" in proc.stderr and calls == []


def test_an_idle_app_needs_consent_when_not_interactive(env):
    proc, calls = run(env, app_state="idle")
    assert proc.returncode == 1 and "quit it first, or re-run with --yes" in proc.stderr and calls == []
    proc, calls = run(env, "--dry-run", app_state="idle")
    assert proc.returncode == 0 and "a real run asks before quitting it" in proc.stdout and calls == []


def test_force_passes_through_to_build_app(env):
    proc, calls = run(env, "--dry-run", "--force", app_state="recording")
    assert proc.returncode == 0 and "--force: it will be quit" in proc.stdout
    assert any(line.startswith("+ ") and line.endswith("build-app.sh --force") for line in proc.stdout.splitlines())
    assert calls == []


def test_unknown_argument_is_rejected(env):
    proc, _ = run(env, "--bogus")
    assert proc.returncode == 64 and "unknown argument" in proc.stderr


@pytest.mark.skipif(os.uname().sysname != "Darwin", reason="macOS script")
def test_help_lists_the_flags():
    out = subprocess.run(["bash", str(INSTALL), "--help"], capture_output=True, text=True, timeout=10).stdout
    assert all(flag in out for flag in ("--dry-run", "--yes", "--force", "--skip-models"))
