"""Hugging Face Hub: gated-model access check, cache lookup and model download (huggingface_hub, lazy)."""

from __future__ import annotations

from ...config import hf_token


def check_hf_access(models: list[str]) -> dict[str, str]:
    from huggingface_hub import auth_check
    from huggingface_hub.utils import GatedRepoError, HfHubHTTPError

    token = hf_token()
    out = {}
    for model in models:
        try:
            auth_check(model, token=token)
            out[model] = "ok"
        except GatedRepoError:
            out[model] = f"gated: accept the terms at https://huggingface.co/{model}"
        except HfHubHTTPError as exc:
            out[model] = f"error: HTTP {getattr(exc.response, 'status_code', '?')}"
        except Exception as exc:
            out[model] = f"error: {type(exc).__name__}"
    return out


def cached_status(repo: str) -> bool | None:
    """True when the repo's config.json is in the local cache, False when it would be downloaded, None if unknown."""
    try:
        from huggingface_hub import try_to_load_from_cache

        return isinstance(try_to_load_from_cache(repo, "config.json"), str)
    except Exception:
        return None


def download_model(repo: str) -> None:
    from huggingface_hub import snapshot_download

    snapshot_download(repo, token=hf_token())
