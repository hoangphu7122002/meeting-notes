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

    def fake_chat(self, system, user, tick=None, fmt=None):
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


def test_templates_schema_and_prompt():
    assert S.template_name("1:1") == "one_on_one" and S.template_name("Standup") == "standup"
    assert S.template_name("nonsense") == "general" and S.template_name(None) == "general"
    assert "sections" not in S.schema("general")["properties"]
    standup = S.schema("standup")
    assert set(standup["properties"]["sections"]["properties"]) == {"updates", "blockers"}
    # The app's summary keys stay required in every template.
    for name in S.TEMPLATES:
        assert {"title", "summary", "decisions", "action_items", "open_questions"} <= set(S.schema(name)["required"])
    system = S.build_system("vi", "interview", ["Tuấn: product lead", "Momos"], ["Me", "Speaker 1"])
    assert "Vietnamese" in system and "job interview" in system and "strengths" in system
    assert "- Tuấn (product lead)" in system and "- Momos" in system and "Speaker 1" in system


def test_ground_notes_drops_invented_owner_and_due():
    transcript = "[00:00:01] Me: Anh Tuấn sẽ gửi báo cáo trước thứ sáu.\n[00:00:05] Speaker 1: I will fix the login bug."
    notes = S.normalize_notes({"title": "x", "summary": [], "decisions": [], "open_questions": [], "action_items": [
        {"task": "Gửi báo cáo", "owner": "anh Tuan", "due": "trước thứ sáu"},       # accent-insensitive match
        {"task": "Fix login bug", "owner": "Speaker 1", "due": "2026-10-23"},       # computed date: dropped
        {"task": "Update docs", "owner": "Lan", "due": "next Monday"},             # nobody named Lan, no Monday
        {"task": "Review", "owner": "Không rõ", "due": "N/A"},
    ]})
    out = S.ground_notes(notes, transcript, ["Me", "Speaker 1"])
    items = out["action_items"]
    assert items[0] == {"task": "Gửi báo cáo", "owner": "anh Tuan", "due": "trước thứ sáu"}
    assert items[1]["owner"] == "Speaker 1" and items[1]["due"] is None
    assert items[2]["owner"] is None and items[2]["due"] is None
    assert items[3]["owner"] is None and items[3]["due"] is None
    assert out["grounding"] == {"dropped_owner": 1, "dropped_due": 2}


def test_summary_language_prefers_vietnamese_when_substantial():
    assert S.summary_language({"vi": 45.0, "en": 55.0}, "en") == "vi"
    assert S.summary_language({"vi": 10.0, "en": 90.0}, "en") == "en"
    assert S.summary_language({}, "en") == "en"
    assert S.summary_language({"vi": 90.0}, "vi", "en") == "en"


def test_summarize_single_pass_grounds_and_tags(monkeypatch):
    seen = {}

    def fake_chat(self, system, user, tick=None, fmt=None):
        seen["system"], seen["fmt"] = system, fmt
        return S.normalize_notes({"title": "Standup", "summary": ["a"], "decisions": [], "open_questions": [],
                                  "action_items": [{"task": "Deploy", "owner": "Minh", "due": "tomorrow"}],
                                  "sections": {"updates": ["Me: done X"], "blockers": []}})

    monkeypatch.setattr(S.Ollama, "ensure_model", lambda self, progress=None: None)
    monkeypatch.setattr(S.Ollama, "chat", fake_chat)
    cfg = Config(glossary=["Momos"], summary_template="standup")
    out = S.summarize(["[00:00:01] Me: I will deploy tomorrow."], "en", cfg)
    assert "sections" in seen["fmt"]["properties"] and "Momos" in seen["system"]
    assert out["template"] == "standup" and out["language"] == "en"
    assert out["action_items"] == [{"task": "Deploy", "owner": None, "due": "tomorrow"}]
    assert out["sections"] == {"updates": ["Me: done X"], "blockers": []}


def test_map_reduce_grounds_each_part(monkeypatch):
    def fake_chat(self, system, user, tick=None, fmt=None):
        if "part 1 of" in user:  # owner "Lan" only appears in part 2: invented for part 1
            return S.normalize_notes({"title": "T", "summary": [], "decisions": [], "open_questions": [],
                                      "action_items": [{"task": "A", "owner": "Lan", "due": None}]})
        if "part 2 of" in user:
            return S.normalize_notes({"title": "T", "summary": [], "decisions": [], "open_questions": [], "action_items": []})
        merged = json.loads(user.split("Partial notes (JSON):\n", 1)[1])
        return S.normalize_notes({"title": "T", "summary": [], "decisions": [], "open_questions": [],
                                  "action_items": [i for p in merged for i in p["action_items"]]})

    monkeypatch.setattr(S.Ollama, "ensure_model", lambda self, progress=None: None)
    monkeypatch.setattr(S.Ollama, "chat", fake_chat)
    lines = ["[00:00:01] Me: " + "x" * 40, "[00:01:00] Speaker 1: Lan joined late."]
    out = S.summarize(lines, "en", Config(summary_chunk_chars=60))
    assert out["action_items"] == [{"task": "A", "owner": None, "due": None}]


def test_render_template_sections_and_summary_language():
    transcript = {"language": "en", "segments": SEGMENTS, "speakers": ["Me"]}
    summary = {"title": "Standup", "summary": ["x"], "decisions": [], "open_questions": [], "action_items": [],
               "language": "vi", "template": "standup", "sections": {"updates": ["Me: xong A"], "blockers": []}}
    md = render_notes({"title": "Meeting"}, transcript, summary)
    assert "## Tóm tắt" in md and "## Cập nhật theo người\n\n- Me: xong A" in md
    assert "Vướng mắc" not in md  # empty sections are omitted
    assert "**Ngôn ngữ:** English" in md  # spoken language stays in the header
