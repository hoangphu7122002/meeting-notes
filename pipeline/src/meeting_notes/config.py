"""Configuration: defaults, optional TOML file, environment overrides."""

from __future__ import annotations

import os
import tomllib
from dataclasses import dataclass, field, fields
from pathlib import Path

CONFIG_PATH = Path(os.environ.get("MEETING_NOTES_CONFIG", "~/.config/meeting-notes/config.toml")).expanduser()
# pipeline/src/meeting_notes/config.py -> repo root is three levels up from the package dir.
REPO_ROOT = Path(__file__).resolve().parents[3]


@dataclass
class Config:
    notes_dir: str = "~/MeetingNotes"
    # Transcription (mlx-whisper, Hugging Face repo id or local path).
    whisper_model: str = "mlx-community/whisper-large-v3-turbo"
    # Allowed spoken languages (ISO 639-1). Detection is restricted to this set; empty = any language.
    languages: list[str] = field(default_factory=lambda: ["vi", "en"])
    initial_prompt: str = ""
    # Diarization. Gated pyannote pipelines are tried in order; the fallback clusters speaker
    # embeddings from an ungated model, or labels tracks "Me" / "Others" if that also fails.
    diarization_models: list[str] = field(
        default_factory=lambda: [
            "pyannote/speaker-diarization-community-1",
            "pyannote/speaker-diarization-3.1",
        ]
    )
    embedding_model: str = "pyannote/wespeaker-voxceleb-resnet34-LM"
    cluster_threshold: float = 0.6  # cosine distance; lower = more speakers
    diarization_device: str = "auto"  # auto | mps | cpu
    me_name: str = "Me"
    # "auto": several distinct voices on the mic (in-person meeting) get their own labels.
    # "me": everything on the mic track is the user.
    mic_speakers: str = "auto"
    # Summary (Ollama, local).
    ollama_url: str = "http://127.0.0.1:11434"
    ollama_model: str = "qwen3:8b"
    ollama_num_ctx: int = 16384
    ollama_timeout_sec: int = 900
    summary_chunk_chars: int = 24000
    # Housekeeping.
    keep_wav: bool = False
    rename_folder: bool = True

    @classmethod
    def load(cls, path: Path | None = None) -> "Config":
        cfg = cls()
        path = path or CONFIG_PATH
        if path.exists():
            with path.open("rb") as f:
                data = tomllib.load(f)
            known = {f.name for f in fields(cls)}
            for key, value in data.items():
                if key in known:
                    setattr(cfg, key, value)
        env_map = {
            "MEETING_NOTES_DIR": "notes_dir",
            "MEETING_NOTES_WHISPER_MODEL": "whisper_model",
            "MEETING_NOTES_OLLAMA_MODEL": "ollama_model",
            "MEETING_NOTES_OLLAMA_URL": "ollama_url",
        }
        for env, attr in env_map.items():
            if os.environ.get(env):
                setattr(cfg, attr, os.environ[env])
        return cfg

    @property
    def notes_path(self) -> Path:
        return Path(self.notes_dir).expanduser()


def hf_token() -> str | None:
    """HF token from the environment or the repo's gitignored .env. Never log the value."""
    token = os.environ.get("HF_TOKEN")
    if token:
        return token.strip()
    env_file = REPO_ROOT / ".env"
    if env_file.exists():
        for line in env_file.read_text().splitlines():
            if line.startswith("HF_TOKEN="):
                value = line.split("=", 1)[1].strip().strip('"').strip("'")
                return value or None
    return None


def redact(text: str) -> str:
    token = hf_token()
    if token and token in text:
        text = text.replace(token, "***")
    return text
