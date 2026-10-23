"""scripts/version.sh and release-tag.sh: the version comes from vX.Y.Z tags, and release-tag only tags a clean,
pushed, green master, never pushes. Runs in a throwaway repo with a bare "origin" and a stub gh."""

import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[4]
SCRIPTS = ("version.sh", "release-tag.sh")


IDENTITY = {"GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
            "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com"}
ENV: dict = {}  # set per test by the fixture: isolated HOME, stub gh first on PATH


def git(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=True,
                          env=ENV).stdout.strip()


@pytest.fixture
def repo(tmp_path):
    bin_dir, home = tmp_path / "bin", tmp_path / "home"
    bin_dir.mkdir()
    home.mkdir()
    state = tmp_path / "ci-state"
    state.write_text("completed success")
    gh = bin_dir / "gh"
    gh.write_text(f'#!/bin/sh\ncat "{state}"\n')
    gh.chmod(0o755)
    env = {"HOME": str(home), "PATH": f"{bin_dir}:/usr/bin:/bin", **IDENTITY}
    ENV.clear()
    ENV.update(env)
    origin, work = tmp_path / "origin.git", tmp_path / "work"
    subprocess.run(["git", "init", "-q", "--bare", "-b", "master", str(origin)], check=True, env=env)
    subprocess.run(["git", "init", "-q", "-b", "master", str(work)], check=True, env=env)
    (work / "scripts").mkdir()
    for name in SCRIPTS:
        shutil.copy2(ROOT / "scripts" / name, work / "scripts" / name)
    git(work, "add", ".")
    git(work, "commit", "-qm", "init")
    git(work, "remote", "add", "origin", str(origin))
    git(work, "push", "-q", "origin", "master")
    return {"work": work, "origin": origin, "env": env, "state": state}


def run(repo, script, *args):
    return subprocess.run(["bash", str(repo["work"] / "scripts" / script), *args], capture_output=True, text=True,
                          timeout=60, env=repo["env"], cwd=repo["work"], stdin=subprocess.DEVNULL)


def commit_and_push(repo, name):
    (repo["work"] / name).write_text(name)
    git(repo["work"], "add", name)
    git(repo["work"], "commit", "-qm", name)
    git(repo["work"], "push", "-q", "origin", "master")


def test_version_follows_tags(repo):
    assert run(repo, "version.sh").stdout.strip() == "0.0.0"
    assert run(repo, "version.sh", "--describe").stdout.strip().startswith("0.0.0-edge.1+g")
    git(repo["work"], "tag", "-a", "v1.2.0", "-m", "x")
    assert run(repo, "version.sh").stdout.strip() == "1.2.0"
    assert run(repo, "version.sh", "--describe").stdout.strip() == "1.2.0"
    commit_and_push(repo, "a")
    assert run(repo, "version.sh").stdout.strip() == "1.2.0"
    assert run(repo, "version.sh", "--describe").stdout.strip().startswith("1.2.0-edge.1+g")


def test_tags_green_master_and_never_pushes(repo):
    proc = run(repo, "release-tag.sh", "1.0.0")
    assert proc.returncode == 0, proc.stderr
    assert "git push origin v1.0.0" in proc.stdout and "Nothing was pushed" in proc.stdout
    assert git(repo["work"], "cat-file", "-t", "v1.0.0") == "tag"  # annotated
    assert git(repo["origin"], "tag", "-l") == ""
    assert run(repo, "version.sh").stdout.strip() == "1.0.0"


@pytest.mark.parametrize("version", ["", "1.2", "1.2.3-rc1", "x.y.z"])
def test_bad_version_is_refused(repo, version):
    proc = run(repo, "release-tag.sh", version)
    assert proc.returncode == 1 and "usage" in proc.stderr


def test_refuses_dirty_tree_other_branch_unpushed_and_red_ci(repo):
    (repo["work"] / "dirty").write_text("x")
    assert "uncommitted" in run(repo, "release-tag.sh", "1.0.0").stderr
    (repo["work"] / "dirty").unlink()
    git(repo["work"], "checkout", "-qb", "feature")
    assert "tagged on master only" in run(repo, "release-tag.sh", "1.0.0").stderr
    git(repo["work"], "checkout", "-q", "master")
    (repo["work"] / "local").write_text("x")
    git(repo["work"], "add", "local")
    git(repo["work"], "commit", "-qm", "local")
    assert "differs from origin/master" in run(repo, "release-tag.sh", "1.0.0").stderr
    git(repo["work"], "push", "-q", "origin", "master")
    repo["state"].write_text("in_progress ")
    proc = run(repo, "release-tag.sh", "1.0.0")
    assert proc.returncode == 1 and "wait until it is green" in proc.stderr
    assert git(repo["work"], "tag", "-l") == ""


def test_refuses_existing_or_older_version(repo):
    assert run(repo, "release-tag.sh", "1.1.0").returncode == 0
    assert "already exists" in run(repo, "release-tag.sh", "1.1.0").stderr
    commit_and_push(repo, "b")
    for older in ("1.0.9", "0.9.0"):
        assert "not newer" in run(repo, "release-tag.sh", older).stderr
    assert run(repo, "release-tag.sh", "1.1.1").returncode == 0
