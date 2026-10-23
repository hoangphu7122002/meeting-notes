"""Shared install mode (scripts/install.sh --shared): marker, model-store environment and per-user HF token."""

import json
import os

import pytest

from meeting_notes.adapters.inbound import commands
from meeting_notes.config import SHARED_INSTALL_MARKER, apply_shared_env, loader, shared_install


def write_marker(root, **extra):
    (root / SHARED_INSTALL_MARKER).write_text(json.dumps({"version": 1, **extra}))


def test_no_marker_means_a_per_user_install(tmp_path):
    env = {}
    assert shared_install(tmp_path) is None
    assert apply_shared_env(tmp_path, env) == {} and env == {}


def test_garbage_marker_is_ignored(tmp_path):
    (tmp_path / SHARED_INSTALL_MARKER).write_text("not json")
    assert shared_install(tmp_path) is None


def test_owner_gets_the_shared_cache_online(tmp_path):
    hub = tmp_path / "models" / "huggingface" / "hub"
    hub.mkdir(parents=True)
    write_marker(tmp_path, hf_hub_cache=str(hub))
    env = {}
    assert apply_shared_env(tmp_path, env) == {"HF_HUB_CACHE": str(hub)}
    assert env == {"HF_HUB_CACHE": str(hub)}


def test_default_cache_location_is_under_the_shared_models_dir(tmp_path):
    write_marker(tmp_path)
    env = {}
    apply_shared_env(tmp_path, env)
    assert env["HF_HUB_CACHE"] == str(tmp_path / "models" / "huggingface" / "hub")


@pytest.mark.skipif(os.geteuid() == 0, reason="root can write anything")
def test_other_accounts_read_the_store_offline(tmp_path):
    hub = tmp_path / "hub"
    hub.mkdir()
    write_marker(tmp_path, hf_hub_cache=str(hub))
    hub.chmod(0o555)
    try:
        env = {}
        apply_shared_env(tmp_path, env)
        assert env == {"HF_HUB_CACHE": str(hub), "HF_HUB_OFFLINE": "1"}
    finally:
        hub.chmod(0o755)


def test_user_values_win(tmp_path):
    write_marker(tmp_path)
    env = {"HF_HOME": "/custom", "HF_HUB_OFFLINE": "0"}
    assert apply_shared_env(tmp_path, env) == {}
    assert env == {"HF_HOME": "/custom", "HF_HUB_OFFLINE": "0"}


@pytest.fixture
def token_env(tmp_path, monkeypatch):
    repo, config = tmp_path / "repo", tmp_path / "config"
    repo.mkdir()
    config.mkdir()
    monkeypatch.delenv("HF_TOKEN", raising=False)
    monkeypatch.setattr(loader, "REPO_ROOT", repo)
    monkeypatch.setattr(loader, "CONFIG_PATH", config / "config.toml")
    return repo, config


def test_dev_install_reads_the_repo_env(token_env):
    repo, _ = token_env
    (repo / ".env").write_text("HF_TOKEN=repo-token\n")
    assert loader.hf_token() == "repo-token"


def test_per_user_env_file_comes_first(token_env):
    repo, config = token_env
    (repo / ".env").write_text("HF_TOKEN=repo-token\n")
    (config / ".env").write_text('HF_TOKEN="user-token"\n')
    assert loader.hf_token() == "user-token"


def test_shared_install_never_reads_a_env_in_the_shared_dir(token_env):
    repo, config = token_env
    write_marker(repo)
    (repo / ".env").write_text("HF_TOKEN=shared-token\n")
    assert loader.hf_token() is None
    (config / ".env").write_text("HF_TOKEN=user-token\n")
    assert loader.hf_token() == "user-token"


def test_doctor_reports_the_install_mode(tmp_path, monkeypatch):
    monkeypatch.setattr(commands, "REPO_ROOT", tmp_path)
    assert commands.install_mode().startswith("per-user")
    write_marker(tmp_path)
    monkeypatch.setenv("HF_HUB_CACHE", "/Users/Shared/MeetingNotes/models/huggingface/hub")
    monkeypatch.setenv("HF_HUB_OFFLINE", "1")
    assert commands.install_mode() == (f"shared ({tmp_path}); models /Users/Shared/MeetingNotes/models/huggingface/hub "
                                       "(read-only, offline)")


def test_helper_lookup_includes_the_shared_app(tmp_path, monkeypatch):
    from meeting_notes.adapters.outbound import fluidaudio_diarizer as fa

    monkeypatch.setattr(fa, "REPO_ROOT", tmp_path)
    write_marker(tmp_path, app=str(tmp_path / "MeetingNotes.app"))
    assert tmp_path / "MeetingNotes.app" / "Contents" / "MacOS" / fa.BINARY in fa.candidates({})


def test_doctor_reports_the_packaged_app_runtime(tmp_path, monkeypatch):
    monkeypatch.setattr(commands, "REPO_ROOT", tmp_path)
    write_marker(tmp_path, mode="packaged")
    monkeypatch.setenv("HF_HUB_CACHE", str(tmp_path / "models" / "huggingface" / "hub"))
    assert commands.install_mode() == f"packaged app runtime ({tmp_path}); models {tmp_path}/models/huggingface/hub"


def test_packaged_runtime_never_reads_a_dot_env_next_to_it(tmp_path, monkeypatch):
    monkeypatch.setattr(loader, "REPO_ROOT", tmp_path)
    monkeypatch.setattr(loader, "CONFIG_PATH", tmp_path / "cfg" / "config.toml")
    monkeypatch.delenv("HF_TOKEN", raising=False)
    write_marker(tmp_path, mode="packaged")
    (tmp_path / ".env").write_text("HF_TOKEN=should-not-be-read\n")
    assert loader.hf_token() is None
