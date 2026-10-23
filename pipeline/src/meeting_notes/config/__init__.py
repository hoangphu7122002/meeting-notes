"""Settings kernel shared by application and adapters: Config, where it is loaded from, secrets, install mode."""

from .install import MARKER as SHARED_INSTALL_MARKER
from .install import apply_shared_env, hf_hub_cache, shared_install
from .loader import CONFIG_PATH, REPO_ROOT, hf_token, load_config, redact, user_env_file
from .settings import WHISPER_DEFAULT, WHISPER_FALLBACK, Config, resolve_whisper_model

__all__ = [
    "CONFIG_PATH", "REPO_ROOT", "SHARED_INSTALL_MARKER", "WHISPER_DEFAULT", "WHISPER_FALLBACK", "Config",
    "apply_shared_env", "hf_hub_cache", "hf_token", "load_config", "redact", "resolve_whisper_model",
    "shared_install", "user_env_file",
]
