from meeting_notes.domain.notes_markdown import paragraphs, render_notes, transcript_lines
from meeting_notes.domain.timecode import timestamp

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


def test_render_template_sections_and_summary_language():
    transcript = {"language": "en", "segments": SEGMENTS, "speakers": ["Me"]}
    summary = {"title": "Standup", "summary": ["x"], "decisions": [], "open_questions": [], "action_items": [],
               "language": "vi", "template": "standup", "sections": {"updates": ["Me: xong A"], "blockers": []}}
    md = render_notes({"title": "Meeting"}, transcript, summary)
    assert "## Tóm tắt" in md and "## Cập nhật theo người\n\n- Me: xong A" in md
    assert "Vướng mắc" not in md  # empty sections are omitted
    assert "**Ngôn ngữ:** English" in md  # spoken language stays in the header
