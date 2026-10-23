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
STUBS = ("brew", "swift", "curl", "open", "osascript", "codesign", "xcode-select", "ditto", "sudo", "rsync", "install")


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


def run(env, *args, app_state=None, extra_env=None):
    extra = dict(extra_env or {})
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


# ---------------------------------------------------------------- --shared


@pytest.fixture
def shared(env, tmp_path):
    apps = tmp_path / "Applications"
    apps.mkdir()
    root = tmp_path / "Shared" / "MeetingNotes"
    root.parent.mkdir()
    return {"MN_SHARED_ROOT": str(root), "MN_APPLICATIONS_DIR": str(apps), "root": root, "apps": apps}


def shared_env(shared):
    return {k: v for k, v in shared.items() if k.startswith("MN_")}


def commands(out):
    return [line[2:] for line in out.splitlines() if line.startswith("+ ")]


def test_shared_dry_run_plans_a_read_only_store_and_changes_nothing(env, shared):
    proc, calls = run(env, "--shared", "--dry-run", extra_env=shared_env(shared))
    assert proc.returncode == 0, proc.stderr
    root, app = shared["root"], shared["apps"] / "MeetingNotes.app"
    cmds = commands(proc.stdout)
    for expected in (
        f"rsync -a --delete --exclude .venv",
        f"--exclude .env {ROOT}/pipeline/ {root}/pipeline/",
        f"install -m 755 {ROOT}/scripts/user-setup.sh {root}/bin/meeting-notes-user-setup",
        f"write {root}/shared-install.json",
        f"UV_PYTHON_INSTALL_DIR={root}/python UV_PYTHON_PREFERENCE=only-managed {root}/bin/uv sync --project {root}/pipeline --frozen",
        f"MEETING_NOTES_CONFIG=/dev/null",
        f"chmod -R u+rwX,go+rX,go-w {root}",
        f"build-app.sh --install-dir {shared['apps']} --pipeline-dir {root}/pipeline --uv-path {root}/bin/uv",
        f"{root}/bin/meeting-notes doctor",
    ):
        assert any(expected in c for c in cmds), expected
    assert f"{root}/bin/meeting-notes-user-setup --open" in proc.stdout and str(app) in proc.stdout
    assert "dry run: nothing was changed" in proc.stdout
    assert calls == [] and not root.exists()  # nothing ran, nothing created


def test_shared_without_admin_rights_installs_the_app_in_the_shared_root_and_only_prints_sudo(env, shared):
    shared["apps"].chmod(0o555)
    try:
        proc, calls = run(env, "--shared", "--dry-run", extra_env=shared_env(shared))
    finally:
        shared["apps"].chmod(0o755)
    root = shared["root"]
    assert proc.returncode == 0, proc.stderr
    assert "not writable" in proc.stdout and f"--install-dir {root} " in proc.stdout
    assert "sudo ditto" in proc.stdout and not any(c.startswith("sudo") for c in commands(proc.stdout))
    assert calls == []


def test_shared_root_writable_by_others_is_refused(env, shared):
    shared["root"].mkdir()
    shared["root"].chmod(0o777)
    proc, calls = run(env, "--shared", "--dry-run", extra_env=shared_env(shared))
    assert proc.returncode == 1 and "not safe to install into" in proc.stderr and calls == []


def test_a_token_file_in_the_shared_root_is_refused(env, shared):
    shared["root"].mkdir()
    (shared["root"] / ".env").write_text("HF_TOKEN=x\n")
    proc, _ = run(env, "--shared", "--dry-run", extra_env=shared_env(shared))
    assert proc.returncode == 1 and "readable by every account" in proc.stderr and "HF_TOKEN=x" not in proc.stderr


def test_an_app_open_in_another_account_is_never_replaced(env, shared):
    app = shared["apps"] / "MeetingNotes.app"
    ps = env["bin"] / "ps"
    ps.write_text(f'#!/bin/sh\necho "99999 otheruser {app}/Contents/MacOS/MeetingNotes"\n')
    ps.chmod(0o755)
    for args in (("--shared", "--dry-run"), ("--shared", "--yes", "--force")):  # --force cannot quit their app
        proc, calls = run(env, *args, extra_env=shared_env(shared))
        assert proc.returncode == 1 and "otheruser" in proc.stderr and "==> Plan" not in proc.stdout
        assert calls == []


def test_user_setup_dry_run_touches_only_this_account(tmp_path):
    root, home = tmp_path / "shared", tmp_path / "home"
    (root / "pipeline" / ".venv" / "bin").mkdir(parents=True)
    home.mkdir()
    cli = root / "pipeline" / ".venv" / "bin" / "meeting-notes"
    cli.write_text("#!/bin/sh\nexit 0\n")
    cli.chmod(0o755)
    (root / "shared-install.json").write_text(json.dumps({"version": 1, "app": "/Applications/MeetingNotes.app"}))
    script = ROOT / "scripts" / "user-setup.sh"
    environ = {"HOME": str(home), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "MN_SHARED_ROOT": str(root)}
    proc = subprocess.run(["bash", str(script), "--dry-run", "--open"], capture_output=True, text=True, timeout=30,
                          env=environ, stdin=subprocess.DEVNULL)
    assert proc.returncode == 0, proc.stderr
    cmds = commands(proc.stdout)
    assert f"mkdir -p {home}/MeetingNotes {home}/.config/meeting-notes" in cmds
    assert f"{cli} doctor --offline" in cmds and 'open /Applications/MeetingNotes.app' in cmds
    assert "Screen & System Audio Recording" in proc.stdout and list(home.iterdir()) == []


def test_user_setup_without_a_shared_install_explains_what_to_run(tmp_path):
    script = ROOT / "scripts" / "user-setup.sh"
    proc = subprocess.run(["bash", str(script), "--dry-run"], capture_output=True, text=True, timeout=30,
                          env={"HOME": str(tmp_path), "PATH": "/usr/bin:/bin", "MN_SHARED_ROOT": str(tmp_path / "none")})
    assert proc.returncode == 1 and "install.sh --shared" in proc.stderr


def test_makefile_has_install_shared():
    assert "install-shared:" in (ROOT / "Makefile").read_text()
