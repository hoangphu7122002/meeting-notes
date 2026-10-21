"""Summary benchmark on synthetic transcripts with known facts (needs Ollama).

  uv run python tests/eval/summary_bench.py [--model qwen3:4b] [--impl new|old] [--cases a,b] [--out result.json]
  uv run python tests/eval/summary_bench.py --long <meeting>/transcript.json [--impl old]

`--long` scores a real pipeline transcript of the ~60 min synthetic meeting (make_long.py: 10 planted
decisions / action items / one open question among filler) and reports recall, owner/due accuracy,
output size, wall time and peak Ollama memory.

`--impl old` loads summarize.py from git HEAD (the previous prompt) for a before/after comparison.
Scores per case: task recall, owner accuracy, invented owners / due dates (set where the transcript has
none, or not supported by the transcript), decision recall, open-question recall, output language, time.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import re
import subprocess
import sys
import time
import unicodedata
from pathlib import Path

HERE = Path(__file__).resolve().parent
PIPELINE = HERE.parents[1]


def fold(text: str) -> str:
    text = unicodedata.normalize("NFD", (text or "").lower().replace("đ", "d"))
    text = re.sub(r"[^\w\s]", " ", "".join(c for c in text if unicodedata.category(c) != "Mn"))
    return " ".join(re.sub(r"(\d)(st|nd|rd|th)\b", r"\1", text).split())  # "7th" -> "7"


# Each task: (keywords, any of which identifies it in the output (folded), gold owner or None, gold due or None).
CASES = {
    "vi_planning": {
        "template": "general", "languages": {"vi": 95.0, "en": 5.0}, "expect_lang": "vi",
        "lines": [
            "[00:00:02] Me: Chào mọi người, hôm nay mình họp về kế hoạch ra mắt bản hai của ứng dụng.",
            "[00:00:10] Speaker 1: Dạ, bản beta đã xong, nhưng còn hai lỗi crash trên máy cũ.",
            "[00:00:18] Me: Vậy anh Tuấn sửa hai lỗi crash đó trước thứ sáu tuần này nhé.",
            "[00:00:24] Speaker 1: Dạ được, em là Tuấn, em nhận việc này.",
            "[00:00:30] Speaker 2: Hôm qua ngày mười lăm bên marketing có hỏi về giá.",
            "[00:00:38] Me: Mình quyết định giữ giá cũ, năm đô một tháng, không tăng trong quý này.",
            "[00:00:46] Speaker 2: Ok. Em sẽ cập nhật trang giới thiệu sản phẩm.",
            "[00:00:52] Me: Cần ai đó kiểm tra lại số liệu doanh thu tháng trước, chưa biết ai làm.",
            "[00:01:00] Speaker 2: Còn một câu hỏi: năm sau mình có hỗ trợ Windows không?",
            "[00:01:06] Me: Câu đó chưa trả lời được, để buổi sau bàn tiếp.",
        ],
        "tasks": [
            (["crash", "loi"], ["Tuấn", "Speaker 1"], "thứ sáu"),
            (["trang gioi thieu", "landing", "gioi thieu san pham"], "Speaker 2", None),
            (["doanh thu", "so lieu"], None, None),
        ],
        "decisions": [["gia", "pricing", "price"]],
        "questions": [["windows"]],
    },
    "en_sync": {
        "template": "general", "languages": {"en": 100.0}, "expect_lang": "en",
        "lines": [
            "[00:00:01] Speaker 1: Thanks everyone. The beta build is ready, but we have two crash reports on macOS fourteen.",
            "[00:00:09] Me: Sarah, can you fix those crashes before Friday?",
            "[00:00:13] Speaker 2: Yes, this is Sarah, I'll take it.",
            "[00:00:18] Speaker 1: I can update the landing page and the pricing table by next Monday.",
            "[00:00:25] Me: Great. We agreed to keep the old price of five dollars a month this quarter.",
            "[00:00:32] Speaker 2: Someone should also look at the onboarding drop-off numbers at some point.",
            "[00:00:39] Speaker 1: Open question: do we support Windows next year or not?",
            "[00:00:44] Me: Let's decide that next meeting.",
        ],
        "tasks": [
            (["crash"], ["Sarah", "Speaker 2"], "Friday"),
            (["landing", "pricing table"], "Speaker 1", "next Monday"),
            (["onboarding", "drop off"], None, None),
        ],
        "decisions": [["price", "pricing", "five dollars"]],
        "questions": [["windows"]],
    },
    "mixed": {
        "template": "general", "languages": {"vi": 60.0, "en": 40.0}, "expect_lang": "vi",
        "lines": [
            "[00:00:01] Me: Ok team, hôm nay sync nhanh về incident tối qua trên Kubernetes.",
            "[00:00:08] Speaker 1: The root cause was a bad config in the ingress, we rolled back at eleven pm.",
            "[00:00:15] Me: Minh Anh, em viết postmortem và gửi qua Slack trước thứ tư nhé.",
            "[00:00:21] Speaker 2: Dạ ok anh, em là Minh Anh, em sẽ viết.",
            "[00:00:26] Speaker 1: I'll add an alert in Grafana for the error rate.",
            "[00:00:31] Me: Mình chốt là từ giờ mọi thay đổi config phải có review của hai người.",
            "[00:00:38] Speaker 1: Do we need a staging cluster for this? Not sure about the budget.",
            "[00:00:44] Me: Chưa biết, để hỏi lại anh Tuấn bên finance.",
        ],
        "tasks": [
            (["postmortem", "post mortem"], ["Minh Anh", "Speaker 2"], "thứ tư"),
            (["alert", "canh bao", "grafana"], "Speaker 1", None),
        ],
        "decisions": [["review", "hai nguoi"]],
        "questions": [["staging"]],
    },
    "standup": {
        "template": "standup", "languages": {"en": 100.0}, "expect_lang": "en",
        "lines": [
            "[00:00:01] Me: Quick standup. Yesterday I finished the export feature, today I'm on the settings page.",
            "[00:00:08] Speaker 1: Yesterday I reviewed two pull requests. Today I'll write tests for the parser.",
            "[00:00:15] Speaker 1: I'm blocked on the staging database, it's been down since this morning.",
            "[00:00:21] Speaker 2: I'm still on the billing bug. No blockers.",
            "[00:00:26] Me: I'll ping DevOps about the staging database right after this.",
        ],
        "tasks": [
            (["staging", "devops"], "Me", None),
            (["tests", "parser"], "Speaker 1", None),
        ],
        "decisions": [],
        "questions": [],
        "sections": {"blockers": [["staging"]]},
    },
}


def long_case() -> dict:
    """~25 min-like meeting: filler discussion around the en_sync facts, summarized in parts."""
    base = CASES["vi_planning"]
    filler = [
        "[00:{m:02d}:{s:02d}] Speaker {k}: Mình bàn thêm về giao diện màn hình chính, màu sắc và bố cục các nút bấm cho dễ dùng hơn.",
        "[00:{m:02d}:{s:02d}] Me: Đồng ý, nhưng phần này chưa cần chốt hôm nay, cứ ghi nhận ý kiến của mọi người trước đã.",
    ]
    lines = []
    for i, line in enumerate(base["lines"]):
        lines.append(line)
        for j in range(6):
            m, s = divmod(70 + i * 60 + j * 9, 60)
            lines.append(filler[j % 2].format(m=m % 60, s=s, k=1 + j % 2))
    return {**base, "lines": lines, "chunk_chars": 2200}


# Planted items of the 1-hour synthetic meeting (make_long.py PLANTED). Keywords are folded and tolerate ASR
# misspellings and the summary translating English lines into Vietnamese.
# (kind, key, keywords, accepted owners, due keywords)
LONG_PLANTED = [
    ("action", "Tuấn: Q3 revenue report -> Minh Anh by Wed Oct 22", ["quy 3", "quy ba", "q3"], ["Tuấn"],
     ["thu 4", "thu tu", "22"]),
    ("action", "Sarah: fix payment timeout bug by Fri Oct 24", ["timeout", "time out"], ["Sarah", "Speaker 1"],
     ["friday", "24", "thu 6", "thu sau"]),
    ("decision", "Mobile v3 launch moved Nov 15 -> Dec 1", ["launch", "ra mat", "1 thang 12", "1 12", "december", "15 thang 11"],
     None, None),
    ("decision", "Keep price at $5/month for rest of year", ["5 per month", "5 month", "5 thang", "5 usd", "5 do", "giu gia", "price"],
     None, None),
    ("action", "Minh Anh: schedule design review next Tuesday", ["review thiet ke", "design review", "team design", "nhom thiet ke"],
     ["Minh Anh", "Speaker 3"], ["thu 3", "thu ba", "tuesday"]),
    ("action", "Daniel: migrate Postgres to v17 by Nov 7", ["postgres", "postgre"], ["Daniel", "Speaker 2"],
     ["november 7", "nov 7", "7 thang 11", "7 11"]),
    ("decision", "Error alerts move from email to Slack #incident", ["slack", "slat", "incident"], None, None),
    ("action", "Me: onboarding docs for 2 new interns by Oct 30", ["intern", "in ton", "thuc tap", "on waring"], ["Me"],
     ["30"]),
    ("question", "Open: support Windows next year?", ["windows"], None, None),
    ("decision", "Q4 marketing budget 50M VND approved", ["50 trieu", "ngan sach", "budget"], None, None),
]
LONG_GLOSSARY = ["Tuấn", "Minh Anh", "Sarah", "Daniel", "Grafana", "Kubernetes", "Slack", "Postgres", "Jira", "staging"]


def score_long(notes: dict) -> dict:
    lists = {
        "decision": [(d, None, None) for d in notes.get("decisions", [])],
        "action": [(a["task"], a.get("owner"), a.get("due")) for a in notes.get("action_items", [])],
        "question": [(q, None, None) for q in notes.get("open_questions", [])],
    }
    # Partial credit: a planted decision listed as an action (or the reverse) still counts as captured.
    anywhere = [x for v in lists.values() for x in v] + [(s, None, None) for s in notes.get("summary", [])]
    used: set[tuple[str, int]] = set()
    found, found_any, owner_ok, due_ok, misses = 0, 0, 0, 0, []
    n_actions = sum(k == "action" for k, *_ in LONG_PLANTED)
    for kind, key, keys, owners, dues in LONG_PLANTED:
        hit = next((i for i, (text, *_rest) in enumerate(lists[kind])
                    if (kind, i) not in used and any(k in fold(text) for k in keys)), None)
        if hit is None:
            if any(any(k in fold(t) for k in keys) for t, *_ in anywhere):
                found_any += 1
            misses.append(key)
            continue
        used.add((kind, hit))
        found += 1
        found_any += 1
        _, owner, due = lists[kind][hit]
        if owners and owner and any(fold(o) in fold(owner) for o in owners):
            owner_ok += 1
        if dues and due and any(f" {d} " in f" {fold(due)} " for d in dues):
            due_ok += 1
    total = sum(len(v) for v in lists.values())
    return {"recall": f"{found}/{len(LONG_PLANTED)}", "recall_any_section": f"{found_any}/{len(LONG_PLANTED)}",
            "owner_ok": f"{owner_ok}/{n_actions}", "due_ok": f"{due_ok}/{n_actions}",
            "n_items": total, "n_decisions": len(lists["decision"]), "n_actions": len(lists["action"]),
            "n_questions": len(lists["question"]), "planted_share": round(found / total, 2) if total else 0.0,
            "missed": misses}


class OllamaMemory:
    """Peak memory of the Ollama model runner while a summary runs (runner RSS and /api/ps size)."""

    def __init__(self, url: str):
        import threading

        self.url, self.peak_rss_mb, self.peak_ps_mb = url, 0, 0
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._loop, daemon=True)

    def _loop(self) -> None:
        import urllib.request

        while not self._stop.wait(1.0):
            out = subprocess.run(["ps", "-axo", "rss=,command="], capture_output=True, text=True).stdout
            rss = sum(int(line.split(None, 1)[0]) for line in out.splitlines() if "ollama runner" in line or ("llama-server" in line and ".ollama" in line))
            self.peak_rss_mb = max(self.peak_rss_mb, rss // 1024)
            try:
                with urllib.request.urlopen(self.url.rstrip("/") + "/api/ps", timeout=2) as resp:
                    size = sum(m.get("size", 0) for m in json.load(resp).get("models", []))
                self.peak_ps_mb = max(self.peak_ps_mb, size // 2**20)
            except OSError:
                pass

    def __enter__(self):
        self._thread.start()
        return self

    def __exit__(self, *exc):
        self._stop.set()
        self._thread.join()


def run_long(mod, impl: str, path: Path, model: str, runs: int) -> list[dict]:
    from meeting_notes.config import Config
    from meeting_notes.render import transcript_lines

    transcript = json.loads(path.read_text())
    lines = transcript_lines(transcript["segments"])
    rows = []
    for run in range(runs):
        cfg = Config(ollama_model=model, ollama_keep_alive="30s", glossary=LONG_GLOSSARY)
        with OllamaMemory(cfg.ollama_url) as mem:
            t0 = time.monotonic()
            if impl == "new":
                notes = mod.summarize(lines, "vi", cfg, template="general")
            else:
                notes = mod.summarize(lines, "vi", cfg)
            elapsed = time.monotonic() - t0
        row = {"case": "long_1h", "run": run, "impl": impl, "model": model, "sec": round(elapsed, 1),
               "peak_runner_rss_mb": mem.peak_rss_mb, "peak_ollama_ps_mb": mem.peak_ps_mb, **score_long(notes),
               "notes": notes}
        rows.append(row)
        print(json.dumps({k: v for k, v in row.items() if k != "notes"}, ensure_ascii=False), flush=True)
    return rows


def load_impl(impl: str):
    if impl == "new":
        from meeting_notes import summarize

        return summarize
    src = subprocess.run(["git", "show", "HEAD:pipeline/src/meeting_notes/summarize.py"], cwd=PIPELINE,
                         capture_output=True, text=True, check=True).stdout
    path = PIPELINE / ".pytest_cache" / "summarize_old.py"
    path.write_text(src.replace("from .config import", "from meeting_notes.config import"))
    spec = importlib.util.spec_from_file_location("summarize_old", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def is_vietnamese(text: str) -> bool:
    letters = [c for c in text if c.isalpha()]
    marked = [c for c in letters if unicodedata.normalize("NFD", c) != c or c in "đĐ"]
    return len(letters) > 0 and len(marked) / len(letters) > 0.08


def score(case: dict, notes: dict) -> dict:
    transcript = fold("\n".join(case["lines"]))
    items = notes.get("action_items", [])
    matched, owner_ok, invented_owner, invented_due, due_ok = 0, 0, 0, 0, 0
    used = set()
    for keys, owner, due in case["tasks"]:
        hit = next((i for i, it in enumerate(items) if i not in used and any(k in fold(it["task"]) for k in keys)), None)
        if hit is None:
            continue
        used.add(hit)
        matched += 1
        got_owner, got_due = items[hit].get("owner"), items[hit].get("due")
        owners = owner if isinstance(owner, list) else [owner] if owner else []
        if (not owners and not got_owner) or (got_owner and any(fold(o) in fold(got_owner) for o in owners)):
            owner_ok += 1
        if owner is None and got_owner:
            invented_owner += 1
        if (due is None and not got_due) or (due and got_due and fold(due) in fold(got_due)):
            due_ok += 1
        if due is None and got_due:
            invented_due += 1
    # Unmatched extra items: an owner/due not supported by the transcript counts as invented too.
    for i, it in enumerate(items):
        if i in used:
            continue
        if it.get("owner") and fold(it["owner"]) not in transcript and it["owner"] not in ("Me",) and not it["owner"].startswith("Speaker"):
            invented_owner += 1
        if it.get("due") and not all(w in transcript.split() for w in fold(it["due"]).split()[:3]):
            invented_due += 1
    text = " ".join(notes.get("summary", []) + notes.get("decisions", []) + [i["task"] for i in items])
    dec = sum(any(k in fold(" ".join(notes.get("decisions", []))) for k in keys) for keys in case["decisions"])
    qs = sum(any(k in fold(" ".join(notes.get("open_questions", []))) for k in keys) for keys in case["questions"])
    sec_hits = sum(any(k in fold(" ".join((notes.get("sections") or {}).get(name, []))) for k in keys)
                   for name, groups in (case.get("sections") or {}).items() for keys in groups)
    sec_total = sum(len(g) for g in (case.get("sections") or {}).values())
    lang_ok = is_vietnamese(text) == (case["expect_lang"] == "vi")
    return {"tasks": f"{matched}/{len(case['tasks'])}", "owner_ok": f"{owner_ok}/{len(case['tasks'])}",
            "due_ok": f"{due_ok}/{len(case['tasks'])}", "invented_owner": invented_owner, "invented_due": invented_due,
            "decisions": f"{dec}/{len(case['decisions'])}", "questions": f"{qs}/{len(case['questions'])}",
            "sections": f"{sec_hits}/{sec_total}" if sec_total else "-", "lang_ok": lang_ok, "n_items": len(items)}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="qwen3:4b")
    ap.add_argument("--impl", default="new", choices=["new", "old"])
    ap.add_argument("--cases", default="")
    ap.add_argument("--runs", type=int, default=1)
    ap.add_argument("--out")
    ap.add_argument("--long", help="transcript.json of the 1-hour synthetic meeting (make_long.py)")
    args = ap.parse_args()
    from meeting_notes.config import Config
    from meeting_notes.resources import low_priority

    low_priority()
    mod = load_impl(args.impl)
    if args.long:
        rows = run_long(mod, args.impl, Path(args.long), args.model, args.runs)
        if args.out:
            Path(args.out).write_text(json.dumps(rows, ensure_ascii=False, indent=1))
        return
    cases = {**CASES, "long_vi": long_case()}
    names = args.cases.split(",") if args.cases else list(cases)
    rows = []
    for name in names:
        case = cases[name]
        for run in range(args.runs):
            cfg = Config(ollama_model=args.model, ollama_keep_alive="2m",
                         glossary=["Tuấn", "Minh Anh", "Sarah", "Kubernetes", "Grafana", "Slack"],
                         summary_chunk_chars=case.get("chunk_chars", 18000),
                         summary_extract_chars=min(case.get("chunk_chars", 18000), Config().summary_extract_chars))
            t0 = time.monotonic()
            if args.impl == "new":
                lang = mod.summary_language(case["languages"], max(case["languages"], key=case["languages"].get))
                notes = mod.summarize(case["lines"], lang, cfg, template=case["template"])
            else:
                lang = max(case["languages"], key=case["languages"].get)
                notes = mod.summarize(case["lines"], lang, cfg)
            elapsed = time.monotonic() - t0
            row = {"case": name, "run": run, "impl": args.impl, "model": args.model, "sec": round(elapsed, 1),
                   **score(case, notes), "notes": notes}
            rows.append(row)
            print(json.dumps({k: v for k, v in row.items() if k != "notes"}, ensure_ascii=False), flush=True)
    if args.out:
        Path(args.out).write_text(json.dumps(rows, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    sys.path.insert(0, str(PIPELINE / "src"))
    main()
