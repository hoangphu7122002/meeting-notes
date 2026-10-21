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
