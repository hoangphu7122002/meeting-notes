from meeting_notes.application import summarize_meeting as S
from meeting_notes.application.errors import OllamaError
from meeting_notes.config import Config
from meeting_notes.domain.notes_rules import normalize_notes
from meeting_notes.domain.notes_schema import OVERVIEW_SCHEMA, TEMPLATES, schema, template_name


def fake_llm(chat):
    """LlmClient fake: model checks pass, `chat(self, system, user, tick, fmt, raw)` answers."""

    class FakeLlm:
        def ensure_model(self, progress=None):
            return None

        def list_models(self):
            return set()

    FakeLlm.chat = chat
    return FakeLlm()

def test_summarize_long_extracts_parts_then_overview():
    calls = []

    def fake_chat(self, system, user, tick=None, fmt=None, raw=False):
        calls.append((system, user, fmt))
        if "Part " in user:
            assert "Vietnamese" in system and "points" in fmt["properties"] and raw
            return {"decisions": [], "action_items": [], "open_questions": [], "points": [user.splitlines()[1][:20]]}
        assert fmt == OVERVIEW_SCHEMA and "Main points per part" in user
        return {"title": "T", "summary": ["s1", "s2"]}

    cfg = Config(summary_chunk_chars=50, summary_extract_chars=50)
    out = S.summarize(["x" * 30] * 4, "vi", cfg, llm=fake_llm(fake_chat))
    assert out["title"] == "T" and out["summary"] == ["s1", "s2"]
    assert all(f"Part {i} of 4" in calls[i - 1][1] for i in range(1, 5)) and len(calls) == 5


def test_templates_schema_and_prompt():
    assert template_name("1:1") == "one_on_one" and template_name("Standup") == "standup"
    assert template_name("nonsense") == "general" and template_name(None) == "general"
    assert "sections" not in schema("general")["properties"]
    standup = schema("standup")
    assert set(standup["properties"]["sections"]["properties"]) == {"updates", "blockers"}
    # The app's summary keys stay required in every template.
    for name in TEMPLATES:
        assert {"title", "summary", "decisions", "action_items", "open_questions"} <= set(schema(name)["required"])
    system = S.build_system("vi", "interview", ["Tuấn: product lead", "Momos"], ["Me", "Speaker 1"])
    assert "Vietnamese" in system and "job interview" in system and "strengths" in system
    assert "- Tuấn (product lead)" in system and "- Momos" in system and "Speaker 1" in system


def test_summarize_single_pass_grounds_and_tags():
    seen = {}

    def fake_chat(self, system, user, tick=None, fmt=None):
        seen["system"], seen["fmt"] = system, fmt
        return normalize_notes({"title": "Standup", "summary": ["a"], "decisions": [], "open_questions": [],
                                  "action_items": [{"task": "Deploy", "owner": "Minh", "due": "tomorrow"}],
                                  "sections": {"updates": ["Me: done X"], "blockers": []}})

    cfg = Config(glossary=["Momos"], summary_template="standup")
    out = S.summarize(["[00:00:01] Me: I will deploy tomorrow."], "en", cfg, llm=fake_llm(fake_chat))
    assert "sections" in seen["fmt"]["properties"] and "Momos" in seen["system"]
    assert out["template"] == "standup" and out["language"] == "en"
    assert out["action_items"] == [{"task": "Deploy", "owner": None, "due": "tomorrow"}]
    assert out["sections"] == {"updates": ["Me: done X"], "blockers": []}


def test_long_path_grounds_each_part_and_keeps_every_item():
    def fake_chat(self, system, user, tick=None, fmt=None, raw=False):
        # Parts are one sentence each here; answer by content. Owner "Lan" is not in part 1: invented there.
        if "Part " in user and "xxxx" in user:
            return {"decisions": [{"time": "00:00:01", "text": "Keep the price at five dollars"}],
                    "action_items": [{"time": "00:00:01", "task": "Send the Q3 report", "owner": "Lan", "due": None}],
                    "open_questions": [], "points": ["pricing"]}
        if "Part " in user and "Postgres" in user:
            return {"decisions": [{"time": "00:01:00", "text": "Move alerts to Slack"},
                                  {"time": "00:01:00", "text": "keep the price at five dollars."}],
                    "action_items": [{"time": "[00:01:00]", "task": "Migrate Postgres to 17", "owner": "Speaker 1",
                                      "due": "November 7"}],
                    "open_questions": [{"time": "bad", "text": "Support Windows next year?"}], "points": ["alerts"]}
        if "Part " in user:
            return {"decisions": [], "action_items": [], "open_questions": [], "points": []}
        return {"title": "T", "summary": []}  # empty overview: fall back to the part points

    lines = ["[00:00:01] Me: " + "x" * 40,
             "[00:01:00] Speaker 1: Lan joined late. I will migrate Postgres to 17 by November 7."]
    out = S.summarize(lines, "en", Config(summary_chunk_chars=60, summary_extract_chars=60), llm=fake_llm(fake_chat))
    assert out["decisions"] == ["Keep the price at five dollars", "Move alerts to Slack"]
    assert out["action_items"] == [{"task": "Send the Q3 report", "owner": None, "due": None},
                                   {"task": "Migrate Postgres to 17", "owner": "Speaker 1", "due": "November 7"}]
    assert out["open_questions"] == ["Support Windows next year?"]
    assert out["summary"] == ["pricing", "alerts"]


def test_key_lines_the_parts_missed_or_misfiled_are_written():
    calls = []
    lines = ["[00:00:05] Speaker 1: Okay, I'll fix the payment timeout bug by Friday, October 24th.",
             "[00:00:20] Speaker 3: Chị sẽ đặt lịch review thiết kế vào thứ 3 tuần sau.",
             "[00:00:40] Speaker 2: Ngân sách quý 4 là 50 triệu, đã được duyệt rồi nhé.",
             "[00:01:00] Me: Đồng ý, nhưng phần này chưa cần chốt hôm nay.",
             "[00:01:10] Me: Đồng ý, nhưng phần này chưa cần chốt hôm nay.",
             "[00:01:30] Me: " + "x" * 60]

    def fake_chat(self, system, user, tick=None, fmt=None, raw=False):
        calls.append(user)
        if "Part " in user:
            # Misses the timeout line; files the design review as a decision; noise item on the filler line.
            return {"decisions": [{"time": "00:00:20", "text": "Đặt lịch review thiết kế vào thứ 3 tuần sau"}],
                    "action_items": [{"time": "00:01:30", "task": "Xem lại phần x", "owner": "Me", "due": None}],
                    "open_questions": [], "points": ["p"]}
        if user.startswith("Items:"):
            assert "text_in_vietnamese" in fmt["properties"]["items"]["items"]["required"]
            ids = [int(x.split()[1]) for x in user.splitlines() if x.startswith("id ")]
            assert ids == [0, 1, 2, 3]  # every key line no part item holds; the repeated sentence once
            return {"items": [
                {"id": 0, "kind": "action", "text_in_vietnamese": "Sửa lỗi timeout thanh toán", "owner": "Speaker 1",
                 "due": "by Friday, October 24th"},
                {"id": 1, "kind": "action", "text_in_vietnamese": "Đặt lịch review thiết kế", "owner": "Chị",
                 "due": "thứ 3 tuần sau"},
                {"id": 2, "kind": "decision", "text_in_vietnamese": "Ngân sách quý 4 là 50 triệu đã được duyệt",
                 "owner": None, "due": None},
                # id 3 is not answered: the line's own text is kept.
            ]}
        return {"title": "T", "summary": ["s"]}

    out = S.summarize(lines, "vi", Config(summary_chunk_chars=100, summary_extract_chars=1000), llm=fake_llm(fake_chat))
    assert sum(c.startswith("Items:") for c in calls) == 1
    assert out["action_items"] == [
        {"task": "Sửa lỗi timeout thanh toán", "owner": "Speaker 1", "due": "by Friday, October 24th"},
        {"task": "Đặt lịch review thiết kế", "owner": "Speaker 3", "due": "thứ 3 tuần sau"},  # pronoun -> speaker
        {"task": "Xem lại phần x", "owner": "Me", "due": None},
    ]
    assert out["decisions"] == ["Ngân sách quý 4 là 50 triệu đã được duyệt"]  # the misfiled decision is gone
    assert out["open_questions"] == ["Đồng ý, nhưng phần này chưa cần chốt hôm nay."]


def test_key_lines_survive_a_failed_write_call():
    def fake_chat(self, system, user, tick=None, fmt=None, raw=False):
        if "Part " in user:
            return {"decisions": [], "action_items": [], "open_questions": [], "points": []}
        if user.startswith("Items:"):
            raise OllamaError("boom")
        return {"title": "", "summary": []}

    lines = ["[00:00:05] Speaker 1: Okay, I'll fix the payment timeout bug by Friday.",
             "[00:00:30] Me: " + "x" * 60]
    out = S.summarize(lines, "en", Config(summary_chunk_chars=50, summary_extract_chars=1000), llm=fake_llm(fake_chat))
    assert out["action_items"] == [{"task": "Okay, I'll fix the payment timeout bug by Friday.",
                                    "owner": "Speaker 1", "due": None}]
