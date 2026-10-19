import json

from meeting_notes import summarize as S
from meeting_notes.config import Config
from meeting_notes.render import paragraphs, render_notes, timestamp, transcript_lines


def test_parse_json_strips_think_and_normalizes():
    raw = '<think>hmm</think>{"title": " \\"Sprint sync\\" ", "summary": "one", "decisions": [], ' \
          '"action_items": [{"task": "Fix crash", "owner": "null", "due": "Friday"}, {"task": ""}], "open_questions": null}'
    notes = S.parse_json(raw)
    assert notes["title"] == "Sprint sync"
    assert notes["summary"] == ["one"]
    assert notes["action_items"] == [{"task": "Fix crash", "owner": None, "due": "Friday"}]
    assert notes["open_questions"] == []


def test_chunk_lines():
    chunks = S.chunk_lines(["a" * 10] * 10, 35)
    assert len(chunks) == 4 and all(len(c) <= 35 for c in chunks)


def test_summarize_map_reduce(monkeypatch):
    calls = []

    def fake_chat(self, system, user):
        calls.append(user)
        assert "Vietnamese" in system
        return {"title": "T", "summary": [user[:10]], "decisions": [], "action_items": [], "open_questions": []}

    monkeypatch.setattr(S.Ollama, "ensure_model", lambda self, progress=None: None)
    monkeypatch.setattr(S.Ollama, "chat", fake_chat)
    cfg = Config(summary_chunk_chars=50)
    out = S.summarize(["x" * 30] * 4, "vi", cfg)
    assert out["title"] == "T"
    assert all(f"part {i} of 4" in calls[i - 1] for i in range(1, 5)) and "Partial notes" in calls[-1]


def test_ollama_unreachable_message():
    cfg = Config(ollama_url="http://127.0.0.1:9")
    try:
        S.Ollama(cfg).ensure_model()
    except S.OllamaError as exc:
        assert "brew services start ollama" in str(exc)
    else:
        raise AssertionError("expected OllamaError")


SEGMENTS = [
    {"start": 1.0, "end": 3.0, "speaker": "Me", "text": "Chào mọi người."},
    {"start": 3.5, "end": 5.0, "speaker": "Me", "text": "Bắt đầu nhé."},
    {"start": 6.0, "end": 9.0, "speaker": "Speaker 1", "text": "Sounds good."},
]


def test_paragraphs_and_lines():
    paras = paragraphs(SEGMENTS)
    assert len(paras) == 2 and paras[0]["text"] == "Chào mọi người. Bắt đầu nhé."
    assert transcript_lines(SEGMENTS)[1] == "[00:00:06] Speaker 1: Sounds good."
    assert timestamp(3725) == "01:02:05"


def test_render_notes_vietnamese():
    meeting = {"title": "Meeting", "started_at": "2026-10-19T14:30:00+07:00"}
    transcript = {"language": "vi", "duration_sec": 600, "speakers": ["Me", "Speaker 1"], "segments": SEGMENTS,
                  "diarization": {"note": ""}}
    summary = {"title": "Họp ra mắt", "summary": ["Điểm A"], "decisions": [], "open_questions": ["Windows?"],
               "action_items": [{"task": "Sửa lỗi", "owner": "Speaker 1", "due": "thứ sáu"}]}
    md = render_notes(meeting, transcript, summary)
    assert md.startswith("# Họp ra mắt")
    assert "## Tóm tắt" in md and "- [ ] Sửa lỗi — **Speaker 1**, hạn: thứ sáu" in md
    assert "## Quyết định chính\n\nKhông có." in md
    assert "**[00:00:01] Me:** Chào mọi người. Bắt đầu nhé." in md


def test_render_without_summary():
    md = render_notes({"title": "Meeting"}, {"language": "en", "segments": SEGMENTS}, None, "Ollama down")
    assert "Summary unavailable:** Ollama down" in md and "## Transcript" in md
