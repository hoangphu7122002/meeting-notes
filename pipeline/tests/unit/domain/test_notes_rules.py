from meeting_notes.domain.key_lines import as_kind, chunk_lines, self_owner, strong_kind
from meeting_notes.domain.notes_merge import clean_extract, merge_extracts, merge_items, similar
from meeting_notes.domain.notes_rules import ground_notes, normalize_notes, summary_language
from meeting_notes.domain.timecode import parse_time

def test_chunk_lines():
    chunks = chunk_lines(["a" * 10] * 10, 35)
    assert len(chunks) == 4 and all(len(c) <= 35 for c in chunks)


def test_ground_notes_drops_invented_owner_and_due():
    transcript = "[00:00:01] Me: Anh Tuấn sẽ gửi báo cáo trước thứ sáu.\n[00:00:05] Speaker 1: I will fix the login bug."
    notes = normalize_notes({"title": "x", "summary": [], "decisions": [], "open_questions": [], "action_items": [
        {"task": "Gửi báo cáo", "owner": "anh Tuan", "due": "trước thứ sáu"},       # accent-insensitive match
        {"task": "Fix login bug", "owner": "Speaker 1", "due": "2026-10-23"},       # computed date: dropped
        {"task": "Update docs", "owner": "Lan", "due": "next Monday"},             # nobody named Lan, no Monday
        {"task": "Review", "owner": "Không rõ", "due": "N/A"},
    ]})
    out = ground_notes(notes, transcript, ["Me", "Speaker 1"])
    items = out["action_items"]
    assert items[0] == {"task": "Gửi báo cáo", "owner": "anh Tuan", "due": "trước thứ sáu"}
    assert items[1]["owner"] == "Speaker 1" and items[1]["due"] is None
    assert items[2]["owner"] is None and items[2]["due"] is None
    assert items[3]["owner"] is None and items[3]["due"] is None
    assert out["grounding"] == {"dropped_owner": 1, "dropped_due": 2}


def test_summary_language_prefers_vietnamese_when_substantial():
    assert summary_language({"vi": 45.0, "en": 55.0}, "en") == "vi"
    assert summary_language({"vi": 10.0, "en": 90.0}, "en") == "en"
    assert summary_language({}, "en") == "en"
    assert summary_language({"vi": 90.0}, "vi", "en") == "en"


def test_strong_kind_cues():
    assert strong_kind("Vậy mình chốt nhé, dời ngày launch sang 1 tháng 12") == "decision"
    assert strong_kind("So the decision is, we keep the price at $5 per month.") == "decision"
    assert strong_kind("Ngân sách marketing quý 4 là 50 triệu đồng, đã được duyệt rồi nhé.") == "decision"
    assert strong_kind("Okay, I'll fix the payment timeout bug by Friday, October 24th.") == "action"
    assert strong_kind("Anh Tuấn sẽ gửi báo cáo cho chị Minh Anh trước thứ 4, ngày 22 tháng 10.") == "action"
    assert strong_kind("One thing we still haven't decided is whether to support Windows next year.") == "question"
    assert strong_kind("Đồng ý, nhưng phần này chưa cần chốt hôm nay.") == "question"  # not settled: no decision
    for text in ("Sau khi release xong thì mình sẽ test lại trên staging.", "We saw about 20 support tickets.",
                 "Mình cần thêm thời gian để đánh giá lại bảng giá.", "I think we should split the onboarding flow."):
        assert strong_kind(text) is None, text


def test_self_owner_and_pronoun_owner():
    assert self_owner("[00:30:57] Speaker 3: Chị sẽ đặt lịch review thiết kế vào thứ 3 tuần sau.") == "Speaker 3"
    assert self_owner("[00:12:59] Speaker 1: Okay, I'll fix the bug by Friday.") == "Speaker 1"
    assert self_owner("[00:07:20] Me: Anh Tuấn sẽ gửi báo cáo trước thứ 4.") is None
    line = "[00:46:20] Me: Em sẽ viết tài liệu onboarding trước ngày 30 tháng 10."
    assert as_kind({"task": "Viết tài liệu", "owner": "Em", "due": None}, "action", line)["owner"] == "Me"
    assert as_kind({"task": "Viết tài liệu", "owner": "Me", "due": "30/10"}, "action")["owner"] == "Me"
    assert as_kind({"task": "Viết tài liệu", "time": 5.0}, "decision") == {"kind": "decision", "time": 5.0,
                                                                            "text": "Viết tài liệu"}


def test_parse_time():
    assert parse_time("[00:12:59]") == 779 and parse_time("1:02:03") == 3723 and parse_time("12:05") == 725
    assert parse_time("soon", 42.0) == 42.0 and parse_time(None) == 0.0


def test_similar_is_accent_and_punctuation_insensitive():
    assert similar("Dời ngày launch sang 1/12", "dời ngày launch sang 1/12.")
    assert similar("Fix the payment timeout bug", "Fix the payment timeout bug in the checkout service")
    # Same template, different topic: distinct items.
    assert not similar("Đánh giá lại báo cáo doanh thu", "Đánh giá lại bảng giá")
    assert not similar("", "x")


def test_merge_items_folds_duplicates_without_losing_details():
    items = [
        {"task": "Fix timeout bug", "owner": None, "due": None, "time": 300.0},
        {"task": "Write onboarding docs", "owner": "Me", "due": "30/10", "time": 100.0},
        {"task": "fix timeout bug", "owner": "Speaker 1", "due": "Friday", "time": 200.0},
    ]
    out = merge_items(items, "task")
    assert [o["task"] for o in out] == ["Write onboarding docs", "Fix timeout bug"]  # sorted by time
    assert out[1] == {"task": "Fix timeout bug", "owner": "Speaker 1", "due": "Friday", "time": 200.0}


def test_merge_items_keeps_conflicting_owners_apart():
    items = [{"task": "Review the design", "owner": "Me", "due": None, "time": 1.0},
             {"task": "Review the design", "owner": "Speaker 2", "due": None, "time": 2.0},
             {"task": "Review the design", "owner": "Me", "due": "Monday", "time": 3.0},
             {"task": "Review the design", "owner": "Me", "due": "Friday", "time": 4.0}]
    out = merge_items(items, "task")
    assert [(o["owner"], o["due"]) for o in out] == [("Me", "Monday"), ("Speaker 2", None), ("Me", "Friday")]


def test_merge_extracts_is_a_union():
    parts = [clean_extract({"decisions": [{"time": "00:05:00", "text": "A"}, "B"], "action_items": ["Do X", {"task": ""}],
                              "open_questions": [], "points": ["p1"], "sections": {"blockers": []}}, 10.0),
             clean_extract({"decisions": [{"time": "00:00:20", "text": "C"}], "action_items": [],
                              "open_questions": [{"time": "x", "text": "Q?"}], "points": [],
                              "sections": {"blockers": ["db down"]}}, 600.0)]
    notes = merge_extracts(parts)
    assert notes["decisions"] == ["B", "C", "A"]  # B: no time -> part start (10 s); C at 20 s; A at 300 s
    assert notes["action_items"] == [{"task": "Do X", "owner": None, "due": None}]
    assert notes["open_questions"] == ["Q?"] and notes["sections"] == {"blockers": ["db down"]}
    assert "sections" not in merge_extracts([clean_extract({"sections": {"blockers": []}})])
