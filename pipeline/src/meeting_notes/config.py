"""Configuration: defaults, optional TOML file, environment overrides."""

from __future__ import annotations

import os
import tomllib
from dataclasses import dataclass, field, fields
from pathlib import Path

CONFIG_PATH = Path(os.environ.get("MEETING_NOTES_CONFIG", "~/.config/meeting-notes/config.toml")).expanduser()
# pipeline/src/meeting_notes/config.py -> repo root is three levels up from the package dir.
REPO_ROOT = Path(__file__).resolve().parents[3]
WHISPER_DEFAULT = "mlx-community/whisper-large-v3-turbo-q4"
WHISPER_FALLBACK = "mlx-community/whisper-large-v3-turbo"  # fp16; used when a local model path is missing


@dataclass
class Config:
    notes_dir: str = "~/MeetingNotes"
    # Transcription (mlx-whisper, Hugging Face repo id or local path). Default: turbo quantized to 4 bits,
    # same measured WER as fp16 at about half the GPU memory (docs/research/phowhisper-mlx.md).
    whisper_model: str = WHISPER_DEFAULT
    # Allowed spoken languages (ISO 639-1). Detection is restricted to this set; empty = any language.
    languages: list[str] = field(default_factory=lambda: ["vi", "en"])
    initial_prompt: str = ""  # free-text hint prepended to the glossary in the whisper prompt
    # Custom vocabulary: names, products, jargon. Used in the whisper prompt (spelling) and the summary
    # prompt (correct names, owners). An entry may carry a note after ":", e.g. "Tuấn: product lead";
    # the note goes to the summary only.
    glossary: list[str] = field(default_factory=list)
    # Voice-activity trimming inside each speaker block: skip silent blocks, cut long pauses (>= vad_split_gap
    # seconds) so whisper never decodes long silence (the main source of hallucinated repeats).
    whisper_vad: bool = True
    vad_split_gap: float = 2.0
    # Re-decode at higher temperature when a window looks degenerate (repeats / low confidence).
    whisper_temperature_fallback: bool = True
    whisper_condition_on_previous_text: bool = False  # True feeds earlier text back in: more repeat loops
    whisper_max_chunk_sec: float = 28.0  # whisper only applies the prompt to the first 30 s window of a call
    mlx_cache_limit_mb: int = 256  # cap on MLX's freed-buffer cache during transcription; -1 = MLX default (unbounded)
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
    summary_chunk_chars: int = 18000  # transcripts up to this size get one summary call
    summary_extract_chars: int = 9000  # longer ones: items are extracted from parts of this size, merged in Python
    # Summary template: general | one_on_one | standup | interview (a meeting.json "template" key overrides it).
    summary_template: str = "general"
    # Notes language: "auto" = the meeting's main spoken language, or an ISO code such as "vi" / "en".
    summary_language: str = "auto"
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
            "MEETING_NOTES_SUMMARY_TEMPLATE": "summary_template",
        }
        for env, attr in env_map.items():
            if os.environ.get(env):
                setattr(cfg, attr, os.environ[env])
        cfg.whisper_model = resolve_whisper_model(cfg.whisper_model)
        return cfg

    @property
    def notes_path(self) -> Path:
        return Path(self.notes_dir).expanduser()


def resolve_whisper_model(name: str) -> str:
    """Expand a local model path; fall back to fp16 turbo (with a warning) when that path does not exist.

    Hugging Face repo ids ("owner/name") are returned unchanged and downloaded on first use."""
    name = (name or "").strip() or WHISPER_DEFAULT
    if not name.startswith(("/", "./", "../", "~")):
        return name
    path = Path(name).expanduser()
    if path.is_dir() and (path / "config.json").exists():
        return str(path)
    import sys

    print(f"whisper_model {name!r} not found; falling back to {WHISPER_FALLBACK}", file=sys.stderr)
    return WHISPER_FALLBACK


def glossary_entries(glossary: list[str] | str | None) -> list[tuple[str, str]]:
    """Parse glossary entries into (term, note) pairs. Accepts a list or one comma/newline separated string."""
    if not glossary:
        return []
    items = glossary.replace("\n", ",").split(",") if isinstance(glossary, str) else [str(g) for g in glossary]
    out: list[tuple[str, str]] = []
    seen: set[str] = set()
    for item in items:
        term, _, note = item.partition(":")
        term, note = " ".join(term.split()), " ".join(note.split())
        if term and term.lower() not in seen:
            seen.add(term.lower())
            out.append((term, note))
    return out


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
