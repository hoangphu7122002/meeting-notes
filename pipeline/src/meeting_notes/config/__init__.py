"""Settings kernel shared by application and adapters: Config, where it is loaded from, secrets."""

from .loader import CONFIG_PATH, REPO_ROOT, hf_token, load_config, redact
from .settings import WHISPER_DEFAULT, WHISPER_FALLBACK, Config, resolve_whisper_model

__all__ = [
    "CONFIG_PATH", "REPO_ROOT", "WHISPER_DEFAULT", "WHISPER_FALLBACK", "Config",
    "hf_token", "load_config", "redact", "resolve_whisper_model",
]
