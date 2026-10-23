"""Shared install mode: one pipeline + model store for every macOS account on the Mac.

`scripts/install.sh --shared` copies the pipeline to `/Users/Shared/MeetingNotes/pipeline` (owner-writable,
world-readable) and writes `shared-install.json` next to it, so this module finds the marker at REPO_ROOT. In shared
mode the Hugging Face cache is the shared store; for accounts that cannot write it, the hub runs offline (reads the
pre-downloaded files, never tries to lock or download). Everything per user stays per user: config.toml, the
optional HF token (`~/.config/meeting-notes/.env`), recordings, logs and caches outside the model store.

The packaged app (release dmg) uses the same layout for its per-user runtime: its first-run setup copies the bundled
pipeline to `~/Library/Application Support/MeetingNotes/runtime/pipeline`, syncs the environment there and writes the
marker with `"mode": "packaged"` (models in `runtime/models`, writable, so the hub stays online).
"""

from __future__ import annotations

import json
import os
from collections.abc import MutableMapping
from pathlib import Path

MARKER = "shared-install.json"


def shared_install(root: Path) -> dict[str, str] | None:
    """The shared-install marker at `root` as a dict, or None in a normal (per-user, dev) install."""
    path = root / MARKER
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        return None
    return {str(k): str(v) for k, v in data.items()} if isinstance(data, dict) else None


def hf_hub_cache(root: Path, marker: dict[str, str]) -> Path:
    return Path(marker.get("hf_hub_cache") or root / "models" / "huggingface" / "hub")


def apply_shared_env(root: Path, environ: MutableMapping[str, str] | None = None) -> dict[str, str]:
    """Point the Hugging Face cache at the shared model store; offline when this account cannot write it.

    Values the user already set win (setdefault). Returns what was set, for `doctor`. Must run before
    huggingface_hub is imported (it reads the environment at import)."""
    env = os.environ if environ is None else environ
    marker = shared_install(root)
    if marker is None:
        return {}
    applied: dict[str, str] = {}
    cache = hf_hub_cache(root, marker)
    if "HF_HUB_CACHE" not in env and "HF_HOME" not in env:
        env["HF_HUB_CACHE"] = applied["HF_HUB_CACHE"] = str(cache)
    target = Path(env.get("HF_HUB_CACHE") or cache)
    if "HF_HUB_OFFLINE" not in env and not _writable(target):
        env["HF_HUB_OFFLINE"] = applied["HF_HUB_OFFLINE"] = "1"
    return applied


def _writable(path: Path) -> bool:
    while not path.exists() and path != path.parent:
        path = path.parent
    return os.access(path, os.W_OK)
