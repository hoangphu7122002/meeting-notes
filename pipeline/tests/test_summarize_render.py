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


def test_summarize_long_extracts_parts_then_overview(monkeypatch):
    calls = []

    def fake_chat(self, system, user, tick=None, fmt=None, raw=False):
        calls.append((system, user, fmt))
        if "Part " in user:
            assert "Vietnamese" in system and "points" in fmt["properties"] and raw
            return {"decisions": [], "action_items": [], "open_questions": [], "points": [user.splitlines()[1][:20]]}
        assert fmt == S.OVERVIEW_SCHEMA and "Main points per part" in user
        return {"title": "T", "summary": ["s1", "s2"]}

    monkeypatch.setattr(S.Ollama, "ensure_model", lambda self, progress=None: None)
    monkeypatch.setattr(S.Ollama, "chat", fake_chat)
    cfg = Config(summary_chunk_chars=50, summary_extract_chars=50)
    out = S.summarize(["x" * 30] * 4, "vi", cfg)
    assert out["title"] == "T" and out["summary"] == ["s1", "s2"]
    assert all(f"Part {i} of 4" in calls[i - 1][1] for i in range(1, 5)) and len(calls) == 5


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


def test_long_path_grounds_each_part_and_keeps_every_item(monkeypatch):
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

    monkeypatch.setattr(S.Ollama, "ensure_model", lambda self, progress=None: None)
    monkeypatch.setattr(S.Ollama, "chat", fake_chat)
    lines = ["[00:00:01] Me: " + "x" * 40,
             "[00:01:00] Speaker 1: Lan joined late. I will migrate Postgres to 17 by November 7."]
    out = S.summarize(lines, "en", Config(summary_chunk_chars=60, summary_extract_chars=60))
    assert out["decisions"] == ["Keep the price at five dollars", "Move alerts to Slack"]
    assert out["action_items"] == [{"task": "Send the Q3 report", "owner": None, "due": None},
                                   {"task": "Migrate Postgres to 17", "owner": "Speaker 1", "due": "November 7"}]
    assert out["open_questions"] == ["Support Windows next year?"]
    assert out["summary"] == ["pricing", "alerts"]


def test_strong_kind_cues():
    assert S.strong_kind("Vậy mình chốt nhé, dời ngày launch sang 1 tháng 12") == "decision"
    assert S.strong_kind("So the decision is, we keep the price at $5 per month.") == "decision"
    assert S.strong_kind("Ngân sách marketing quý 4 là 50 triệu đồng, đã được duyệt rồi nhé.") == "decision"
    assert S.strong_kind("Okay, I'll fix the payment timeout bug by Friday, October 24th.") == "action"
    assert S.strong_kind("Anh Tuấn sẽ gửi báo cáo cho chị Minh Anh trước thứ 4, ngày 22 tháng 10.") == "action"
    assert S.strong_kind("One thing we still haven't decided is whether to support Windows next year.") == "question"
    assert S.strong_kind("Đồng ý, nhưng phần này chưa cần chốt hôm nay.") == "question"  # not settled: no decision
    for text in ("Sau khi release xong thì mình sẽ test lại trên staging.", "We saw about 20 support tickets.",
                 "Mình cần thêm thời gian để đánh giá lại bảng giá.", "I think we should split the onboarding flow."):
        assert S.strong_kind(text) is None, text


def test_self_owner_and_pronoun_owner():
    assert S.self_owner("[00:30:57] Speaker 3: Chị sẽ đặt lịch review thiết kế vào thứ 3 tuần sau.") == "Speaker 3"
    assert S.self_owner("[00:12:59] Speaker 1: Okay, I'll fix the bug by Friday.") == "Speaker 1"
    assert S.self_owner("[00:07:20] Me: Anh Tuấn sẽ gửi báo cáo trước thứ 4.") is None
    line = "[00:46:20] Me: Em sẽ viết tài liệu onboarding trước ngày 30 tháng 10."
    assert S.as_kind({"task": "Viết tài liệu", "owner": "Em", "due": None}, "action", line)["owner"] == "Me"
    assert S.as_kind({"task": "Viết tài liệu", "owner": "Me", "due": "30/10"}, "action")["owner"] == "Me"
    assert S.as_kind({"task": "Viết tài liệu", "time": 5.0}, "decision") == {"kind": "decision", "time": 5.0,
                                                                            "text": "Viết tài liệu"}


def test_key_lines_the_parts_missed_or_misfiled_are_written(monkeypatch):
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

    monkeypatch.setattr(S.Ollama, "ensure_model", lambda self, progress=None: None)
    monkeypatch.setattr(S.Ollama, "chat", fake_chat)
    out = S.summarize(lines, "vi", Config(summary_chunk_chars=100, summary_extract_chars=1000))
    assert sum(c.startswith("Items:") for c in calls) == 1
    assert out["action_items"] == [
        {"task": "Sửa lỗi timeout thanh toán", "owner": "Speaker 1", "due": "by Friday, October 24th"},
        {"task": "Đặt lịch review thiết kế", "owner": "Speaker 3", "due": "thứ 3 tuần sau"},  # pronoun -> speaker
        {"task": "Xem lại phần x", "owner": "Me", "due": None},
    ]
    assert out["decisions"] == ["Ngân sách quý 4 là 50 triệu đã được duyệt"]  # the misfiled decision is gone
    assert out["open_questions"] == ["Đồng ý, nhưng phần này chưa cần chốt hôm nay."]


def test_key_lines_survive_a_failed_write_call(monkeypatch):
    def fake_chat(self, system, user, tick=None, fmt=None, raw=False):
        if "Part " in user:
            return {"decisions": [], "action_items": [], "open_questions": [], "points": []}
        if user.startswith("Items:"):
            raise S.OllamaError("boom")
        return {"title": "", "summary": []}

    monkeypatch.setattr(S.Ollama, "ensure_model", lambda self, progress=None: None)
    monkeypatch.setattr(S.Ollama, "chat", fake_chat)
    lines = ["[00:00:05] Speaker 1: Okay, I'll fix the payment timeout bug by Friday.",
             "[00:00:30] Me: " + "x" * 60]
    out = S.summarize(lines, "en", Config(summary_chunk_chars=50, summary_extract_chars=1000))
    assert out["action_items"] == [{"task": "Okay, I'll fix the payment timeout bug by Friday.",
                                    "owner": "Speaker 1", "due": None}]


def test_parse_time():
    assert S.parse_time("[00:12:59]") == 779 and S.parse_time("1:02:03") == 3723 and S.parse_time("12:05") == 725
    assert S.parse_time("soon", 42.0) == 42.0 and S.parse_time(None) == 0.0


def test_similar_is_accent_and_punctuation_insensitive():
    assert S.similar("Dời ngày launch sang 1/12", "dời ngày launch sang 1/12.")
    assert S.similar("Fix the payment timeout bug", "Fix the payment timeout bug in the checkout service")
    # Same template, different topic: distinct items.
    assert not S.similar("Đánh giá lại báo cáo doanh thu", "Đánh giá lại bảng giá")
    assert not S.similar("", "x")


def test_merge_items_folds_duplicates_without_losing_details():
    items = [
        {"task": "Fix timeout bug", "owner": None, "due": None, "time": 300.0},
        {"task": "Write onboarding docs", "owner": "Me", "due": "30/10", "time": 100.0},
        {"task": "fix timeout bug", "owner": "Speaker 1", "due": "Friday", "time": 200.0},
    ]
    out = S.merge_items(items, "task")
    assert [o["task"] for o in out] == ["Write onboarding docs", "Fix timeout bug"]  # sorted by time
    assert out[1] == {"task": "Fix timeout bug", "owner": "Speaker 1", "due": "Friday", "time": 200.0}


def test_merge_items_keeps_conflicting_owners_apart():
    items = [{"task": "Review the design", "owner": "Me", "due": None, "time": 1.0},
             {"task": "Review the design", "owner": "Speaker 2", "due": None, "time": 2.0},
             {"task": "Review the design", "owner": "Me", "due": "Monday", "time": 3.0},
             {"task": "Review the design", "owner": "Me", "due": "Friday", "time": 4.0}]
    out = S.merge_items(items, "task")
    assert [(o["owner"], o["due"]) for o in out] == [("Me", "Monday"), ("Speaker 2", None), ("Me", "Friday")]


def test_merge_extracts_is_a_union():
    parts = [S.clean_extract({"decisions": [{"time": "00:05:00", "text": "A"}, "B"], "action_items": ["Do X", {"task": ""}],
                              "open_questions": [], "points": ["p1"], "sections": {"blockers": []}}, 10.0),
             S.clean_extract({"decisions": [{"time": "00:00:20", "text": "C"}], "action_items": [],
                              "open_questions": [{"time": "x", "text": "Q?"}], "points": [],
                              "sections": {"blockers": ["db down"]}}, 600.0)]
    notes = S.merge_extracts(parts)
    assert notes["decisions"] == ["B", "C", "A"]  # B: no time -> part start (10 s); C at 20 s; A at 300 s
    assert notes["action_items"] == [{"task": "Do X", "owner": None, "due": None}]
    assert notes["open_questions"] == ["Q?"] and notes["sections"] == {"blockers": ["db down"]}
    assert "sections" not in S.merge_extracts([S.clean_extract({"sections": {"blockers": []}})])


def test_render_template_sections_and_summary_language():
    transcript = {"language": "en", "segments": SEGMENTS, "speakers": ["Me"]}
    summary = {"title": "Standup", "summary": ["x"], "decisions": [], "open_questions": [], "action_items": [],
               "language": "vi", "template": "standup", "sections": {"updates": ["Me: xong A"], "blockers": []}}
    md = render_notes({"title": "Meeting"}, transcript, summary)
    assert "## Tóm tắt" in md and "## Cập nhật theo người\n\n- Me: xong A" in md
    assert "Vướng mắc" not in md  # empty sections are omitted
    assert "**Ngôn ngữ:** English" in md  # spoken language stays in the header
