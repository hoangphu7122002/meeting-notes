"""scripts/release.sh and build-app.sh --packaged: a dry run builds nothing, a packaged build never installs, and the
bundle carries the pipeline source and uv but no secrets.

External tools that would build, sign or publish are stubs that log their call (HOME and PATH are isolated)."""

import os
import plistlib
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[4]
RELEASE = ROOT / "scripts" / "release.sh"
BUILD_APP = ROOT / "scripts" / "build-app.sh"
STUBS = ("hdiutil", "codesign", "osascript", "open", "gh", "git-push", "sudo")

pytestmark = pytest.mark.skipif(os.uname().sysname != "Darwin" or os.uname().machine != "arm64",
                                reason="macOS arm64 release scripts")


@pytest.fixture
def env(tmp_path):
    bin_dir, home = tmp_path / "bin", tmp_path / "home"
    bin_dir.mkdir()
    home.mkdir()
    calls = tmp_path / "calls.log"
    for name in STUBS:
        stub = bin_dir / name
        stub.write_text(f'#!/bin/sh\necho "{name} $*" >> "{calls}"\nexit 0\n')
        stub.chmod(0o755)
    # swift: "builds" fake executables into a bin dir and prints it for --show-bin-path.
    products = tmp_path / "products"
    products.mkdir()
    swift = bin_dir / "swift"
    swift.write_text(f'#!/bin/sh\necho "swift $*" >> "{calls}"\n'
                     f'case "$*" in *--show-bin-path*) echo "{products}";; '
                     f'*) for b in MeetingNotes MeetingNotesDiarize MeetingNotesCaptions MeetingNotesLauncher; do printf "#!/bin/sh\\n" > "{products}/$b"; '
                     f'chmod 755 "{products}/$b"; done;; esac\n')
    swift.chmod(0o755)
    uv = bin_dir / "uv"
    uv.write_text('#!/bin/sh\necho "uv 0.0.0-test"\n')
    uv.chmod(0o755)
    file_stub = bin_dir / "file"  # the uv stub is a script; report it as arm64
    file_stub.write_text('#!/bin/sh\necho "$1: Mach-O 64-bit executable arm64"\n')
    file_stub.chmod(0o755)
    base = {"HOME": str(home), "PATH": f"{bin_dir}:/usr/bin:/bin:/usr/sbin:/sbin", "UV": str(uv),
            "CODESIGN_IDENTITY": "-", "MN_APP_STATE_FILE": str(tmp_path / "state.json")}
    return {"base": base, "calls": calls, "home": home, "tmp": tmp_path}


def run(env, script, *args):
    proc = subprocess.run(["bash", str(script), *args], capture_output=True, text=True, timeout=120,
                          stdin=subprocess.DEVNULL, env=env["base"], cwd=ROOT)
    calls = env["calls"].read_text().splitlines() if env["calls"].exists() else []
    return proc, calls


def test_dry_run_prints_every_step_and_runs_nothing(env):
    out_dir = env["tmp"] / "release"
    proc, calls = run(env, RELEASE, "--dry-run", "--version", "v1.2.3", "--out", str(out_dir))
    assert proc.returncode == 0, proc.stderr
    lines = [line for line in proc.stdout.splitlines() if line.startswith("+ ")]
    for expected in ("build-app.sh --packaged --version 1.2.3", "hdiutil create", "ln -s /Applications",
                     "Read me first.txt", "MeetingNotes-1.2.3.dmg", "shasum -a 256"):
        assert any(expected in line for line in lines), expected
    assert "Dry run: nothing was built" in proc.stdout
    assert calls == [] and not out_dir.exists()


def test_bad_version_and_unsafe_output_are_refused(env):
    proc, calls = run(env, RELEASE, "--dry-run", "--version", "1.2")
    assert proc.returncode == 1 and "invalid version" in proc.stderr and calls == []
    for out in ("/Applications/x", str(env["home"] / "Applications")):
        proc, _ = run(env, RELEASE, "--dry-run", "--out", out)
        assert proc.returncode == 1 and "refusing to write" in proc.stderr


def test_release_never_publishes():
    code = [line for line in RELEASE.read_text().splitlines()
            if not line.lstrip().startswith(("#", "echo"))]  # comments and printed hints only
    for word in ("gh ", "git push", "git tag", "sudo ", "curl ", "/Applications/MeetingNotes"):
        assert not any(word in line for line in code), word


def test_packaged_build_bundles_pipeline_and_uv_and_never_installs(env):
    out = env["tmp"] / "stage"
    proc, calls = run(env, BUILD_APP, "--packaged", "--version", "2.0.1", "--out", str(out), "--uv-path", env["base"]["UV"])
    assert proc.returncode == 0, proc.stderr
    app = out / "MeetingNotes.app" / "Contents"
    info = plistlib.loads((app / "Info.plist").read_bytes())
    assert info["MNPackaged"] is True and "MNPipelineDir" not in info and "MNUvPath" not in info
    assert info["CFBundleShortVersionString"] == "2.0.1"
    for rel in ("MacOS/uv", "MacOS/MeetingNotesDiarize", "MacOS/MeetingNotesCaptions", "MacOS/MeetingNotesLauncher", "Resources/pipeline/uv.lock",
                "Resources/pipeline/pyproject.toml", "Resources/pipeline/src/meeting_notes/entrypoints/cli.py", "Resources/THIRD-PARTY-NOTICES.txt"):
        assert (app / rel).exists(), rel
    shipped = {p.name for p in (app / "Resources" / "pipeline").rglob("*")}
    assert not shipped & {".env", ".venv", "tests", "bench", "__pycache__"}
    assert not (env["home"] / "Applications").exists()
    assert not any(c.startswith(("osascript", "open")) for c in calls)
    assert any("--identifier com.hoangphu.meetingnotes.uv" in c for c in calls if c.startswith("codesign"))
    assert any("--identifier com.hoangphu.meetingnotes.launcher" in c for c in calls if c.startswith("codesign"))
    agent = plistlib.loads((app / "Library" / "LaunchAgents" / "com.hoangphu.meetingnotes.launcher.plist").read_bytes())
    assert agent["Label"] == "com.hoangphu.meetingnotes.launcher"
    assert agent["BundleProgram"] == "Contents/MacOS/MeetingNotesLauncher"
    assert agent["AssociatedBundleIdentifiers"] == ["com.hoangphu.meetingnotes"]
