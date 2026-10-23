from meeting_notes.adapters.outbound.ollama_client import Ollama, parse_json
from meeting_notes.application.errors import OllamaError
from meeting_notes.config import Config

def test_parse_json_strips_think_and_normalizes():
    raw = '<think>hmm</think>{"title": " \\"Sprint sync\\" ", "summary": "one", "decisions": [], ' \
          '"action_items": [{"task": "Fix crash", "owner": "null", "due": "Friday"}, {"task": ""}], "open_questions": null}'
    notes = parse_json(raw)
    assert notes["title"] == "Sprint sync"
    assert notes["summary"] == ["one"]
    assert notes["action_items"] == [{"task": "Fix crash", "owner": None, "due": "Friday"}]
    assert notes["open_questions"] == []


def test_ollama_unreachable_message():
    cfg = Config(ollama_url="http://127.0.0.1:9")
    try:
        Ollama(cfg).ensure_model()
    except OllamaError as exc:
        assert "brew services start ollama" in str(exc)
    else:
        raise AssertionError("expected OllamaError")


class _Resp:
    def __init__(self, body: dict):
        import io as _io
        import json as _json

        self.fp = _io.BytesIO(_json.dumps(body).encode())

    def read(self, *a):
        return self.fp.read(*a)

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def test_unload_if_resident_only_touches_our_model(monkeypatch):
    from meeting_notes.adapters.outbound import ollama_client

    sent = []

    def fake_request(self, path, payload=None, timeout=10):
        sent.append((path, payload))
        return _Resp({"models": [{"name": "qwen3:4b"}, {"name": "llama3:8b"}]} if path == "/api/ps" else {})

    monkeypatch.setattr(ollama_client.Ollama, "_request", fake_request)
    assert ollama_client.unload_if_resident(Config(ollama_model="qwen3:4b"))
    assert sent[-1] == ("/api/generate", {"model": "qwen3:4b", "keep_alive": 0})
    sent.clear()
    assert not ollama_client.unload_if_resident(Config(ollama_model="qwen3:8b"))
    assert sent == [("/api/ps", None)]  # not resident: nothing unloaded


def test_unload_if_resident_never_raises():
    assert not __import__("meeting_notes.adapters.outbound.ollama_client", fromlist=["x"]).unload_if_resident(
        Config(ollama_url="http://127.0.0.1:9"))


def test_free_llm_under_pressure_skips_under_normal(monkeypatch):
    from meeting_notes.adapters.outbound import load_probe, ollama_client
    from meeting_notes.entrypoints import wiring

    monkeypatch.setattr(ollama_client, "unload_if_resident", lambda cfg: True)
    monkeypatch.setattr(load_probe, "memory_pressure_level", lambda libc=None: 1)
    assert not wiring.free_llm_under_pressure(Config())
    monkeypatch.setattr(load_probe, "memory_pressure_level", lambda libc=None: 2)
    assert wiring.free_llm_under_pressure(Config())
