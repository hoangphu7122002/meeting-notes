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
    ollama_model: str = "qwen3:4b"  # qwen3:8b: better summaries, ~2x RAM (see README)
    ollama_num_ctx: int = 12288
    ollama_keep_alive: str = "1m"  # unload soon after the summary to give RAM back
    ollama_num_thread: int = 4
    ollama_timeout_sec: int = 900
    summary_chunk_chars: int = 18000
    ollama_preload: bool = False  # True: load the summary model while transcribing (faster, more RAM at once)
    # Resource limits so processing never makes the Mac feel slow.
    # "low": nice 10 + utility QoS (default) | "background": macOS background QoS, gentlest but ~3x slower
    # | "normal": full speed.
    priority: str = "low"
    cpu_threads: int = 4  # torch / BLAS / OpenMP threads
    diarization_batch_size: int = 8  # pyannote batch size: smaller = shorter GPU bursts
    # Worker (used by the app). keep_models_warm=False unloads whisper/pyannote right after each stage
    # (lowest RAM); True keeps them between meetings until worker_idle_release_min.
    keep_models_warm: bool = False
    worker_idle_release_min: float = 1.0
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
