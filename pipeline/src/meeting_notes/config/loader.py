"""Where configuration comes from: TOML file, MEETING_NOTES_* environment, and the HF token (.env files)."""

from __future__ import annotations

import os
import tomllib
from dataclasses import fields
from pathlib import Path

from .install import shared_install
from .settings import Config, resolve_whisper_model

CONFIG_PATH = Path(os.environ.get("MEETING_NOTES_CONFIG", "~/.config/meeting-notes/config.toml")).expanduser()
# pipeline/src/meeting_notes/config/loader.py -> the repo root is four levels up from this directory.
REPO_ROOT = Path(__file__).resolve().parents[4]

# Environment variable -> Config field (applied after the TOML file).
ENV_OVERRIDES = {
    "MEETING_NOTES_DIR": "notes_dir",
    "MEETING_NOTES_WHISPER_MODEL": "whisper_model",
    "MEETING_NOTES_OLLAMA_MODEL": "ollama_model",
    "MEETING_NOTES_OLLAMA_URL": "ollama_url",
    "MEETING_NOTES_SUMMARY_TEMPLATE": "summary_template",
}


def load_config(path: Path | None = None) -> Config:
    cfg = Config()
    path = path or CONFIG_PATH
    if path.exists():
        with path.open("rb") as f:
            data = tomllib.load(f)
        known = {f.name for f in fields(Config)}
        for key, value in data.items():
            if key in known:
                setattr(cfg, key, value)
    for env, attr in ENV_OVERRIDES.items():
        if os.environ.get(env):
            setattr(cfg, attr, os.environ[env])
    cfg.whisper_model = resolve_whisper_model(cfg.whisper_model)
    return cfg


def hf_token() -> str | None:
    """HF token from the environment, the per-user `~/.config/meeting-notes/.env`, or (dev install only) the repo's
    gitignored .env. A shared install never reads a .env from the shared directory. Never log the value."""
    token = os.environ.get("HF_TOKEN")
    if token:
        return token.strip()
    files = [user_env_file()]
    if shared_install(REPO_ROOT) is None:
        files.append(REPO_ROOT / ".env")
    for env_file in files:
        value = _read_token(env_file)
        if value is not None:
            return value or None
    return None


def user_env_file() -> Path:
    """Per-user secrets file next to config.toml (mode 600 recommended)."""
    return CONFIG_PATH.parent / ".env"


def _read_token(env_file: Path) -> str | None:
    try:
        lines = env_file.read_text().splitlines()
    except OSError:
        return None
    for line in lines:
        if line.startswith("HF_TOKEN="):
            return line.split("=", 1)[1].strip().strip('"').strip("'")
    return None


def redact(text: str) -> str:
    token = hf_token()
    if token and token in text:
        text = text.replace(token, "***")
    return text
