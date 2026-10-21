"""Local Ollama HTTP client (LlmClient port). The only place that talks to the summary model."""

from __future__ import annotations

import json
import re
import threading
import urllib.error
import urllib.request
from collections.abc import Callable

from ...application.errors import OllamaError
from ...config import Config
from ...domain.notes_rules import normalize_notes
from ...domain.notes_schema import SCHEMA


class Ollama:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        self.base = cfg.ollama_url.rstrip("/")

    def _request(self, path: str, payload: dict | None = None, timeout: float = 10):
        data = json.dumps(payload).encode() if payload is not None else None
        req = urllib.request.Request(self.base + path, data=data, headers={"Content-Type": "application/json"})
        try:
            return urllib.request.urlopen(req, timeout=timeout)
        except urllib.error.URLError as exc:
            raise OllamaError(
                f"Ollama is not reachable at {self.base} ({exc.reason if hasattr(exc, 'reason') else exc}). "
                "Start it with: brew services start ollama"
            ) from exc

    def list_models(self) -> set[str]:
        """Names of the models installed in Ollama."""
        with self._request("/api/tags") as resp:
            return {m["name"] for m in json.load(resp).get("models", [])}

    def ensure_model(self, progress: Callable[[float, str], None] | None = None) -> None:
        models = self.list_models()
        name = self.cfg.ollama_model
        if name in models or f"{name}:latest" in models:
            return
        with self._request("/api/pull", {"model": name, "stream": True}, timeout=3600) as resp:
            for line in resp:
                info = json.loads(line or b"{}")
                if info.get("error"):
                    raise OllamaError(f"ollama pull {name}: {info['error']}")
                if progress and info.get("total"):
                    progress(info.get("completed", 0) / info["total"], f"Downloading {name}")

    def chat(self, system: str, user: str, tick: Callable[[int], None] | None = None, fmt: dict | None = None,
             raw: bool = False) -> dict:
        """One structured completion. Streams so `tick(tokens_so_far)` can report progress / cancel."""
        payload = {
            "model": self.cfg.ollama_model,
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
            "format": fmt or SCHEMA,
            "stream": True,
            "think": False,
            "keep_alive": self.cfg.ollama_keep_alive,
            "options": {"temperature": 0.2, "num_ctx": self.cfg.ollama_num_ctx},
        }
        if self.cfg.ollama_num_thread > 0:
            payload["options"]["num_thread"] = self.cfg.ollama_num_thread
        parts: list[str] = []
        with self._request("/api/chat", payload, timeout=self.cfg.ollama_timeout_sec) as resp:
            for n, line in enumerate(resp, 1):
                if not line.strip():
                    continue
                chunk = json.loads(line)
                if chunk.get("error"):
                    raise OllamaError(chunk["error"])
                parts.append(chunk.get("message", {}).get("content", ""))
                if tick and n % 8 == 0:
                    tick(n)
                if chunk.get("done"):
                    break
        return parse_json("".join(parts), raw)


def parse_json(content: str, raw: bool = False) -> dict:
    content = re.sub(r"<think>.*?</think>", "", content, flags=re.S).strip()
    match = re.search(r"\{.*\}", content, flags=re.S)
    if not match:
        raise OllamaError("model did not return JSON")
    data = json.loads(match.group(0))
    return data if raw else normalize_notes(data)


def preload(cfg: Config) -> threading.Thread:
    """Ask Ollama to load the summary model in the background (no prompt, nothing generated)."""

    def run():
        try:
            Ollama(cfg)._request("/api/generate", {"model": cfg.ollama_model, "keep_alive": "5m"}, timeout=120).read()
        except Exception:
            pass  # the summary stage reports real errors

    thread = threading.Thread(target=run, name="ollama-preload", daemon=True)
    thread.start()
    return thread
