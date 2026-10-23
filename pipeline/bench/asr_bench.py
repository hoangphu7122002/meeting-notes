"""Transcription benchmark on synthetic Vietnamese / English / code-switched speech (macOS `say`).

  uv run python bench/asr_bench.py make <dir>             # synthesize corpus.wav + corpus.json once
  uv run python bench/asr_bench.py run <dir> <variant>    # one variant, prints a JSON result line
  uv run python bench/asr_bench.py all <dir> [variants]   # every variant, each in its own process
  ... run|all ... --model <repo|path>      # override the whisper model (e.g. a converted ../models/phowhisper-large-mlx)
  ... run|all ... --vi-model <repo|path>   # route blocks detected as vi to this model; detection + other languages
                                           # use --model (default turbo); both models stay loaded
  ... run|all ... --label <name>           # result name (default: variant, or variant@<model dir name>)

Each variant runs in a fresh process (nice 10, 4 threads) so peak memory is measured per variant.
The corpus mimics what reaches whisper after diarization: one block per utterance, some blocks with
trailing silence (loose diarization), a ~40 s monologue block, and noise-only blocks (room tone,
keyboard clicks) that should produce no text.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import numpy as np

GLOSSARY = ["Momos", "Kubernetes", "Jira", "Zalo", "Slack", "Grafana", "Postgres", "OKR", "hotfix", "deploy",
            "retention", "onboarding", "sprint", "Tuấn", "Minh Anh", "Sarah", "Daniel"]

# (speaker, voice, category, text). Numbers are spelled out so the reference matches what `say` reads.
UTTERANCES = [
    ("Me", "Linh", "vi", "Chào mọi người, hôm nay chúng ta họp nhanh về kế hoạch quý tới."),
    ("Me", "Linh", "vi", "Anh Tuấn sẽ phụ trách phần báo cáo doanh thu và gửi cho chị Minh Anh trước thứ sáu."),
    ("Me", "Linh", "vi", "Khách hàng phản hồi rằng ứng dụng chạy chậm khi mở danh sách đơn hàng."),
    ("Me", "Linh", "vi", "Chúng ta quyết định hoãn việc ra mắt tính năng mới sang tháng sau."),
    ("Me", "Linh", "vi", "Mình nghĩ cần thêm một buổi họp với đội thiết kế để chốt giao diện."),
    ("Me", "Linh", "vi", "Ai có thể kiểm tra lại số liệu tuần trước giúp em được không?"),
    ("Speaker 1", "Samantha", "en", "Let's start with a quick update on the onboarding flow."),
    ("Speaker 2", "Daniel", "en", "Sarah will fix the login bug before Friday."),
    ("Speaker 1", "Samantha", "en", "We agreed to keep the current pricing for this quarter."),
    ("Speaker 1", "Samantha", "en", "Daniel, can you share the dashboard in Grafana after the meeting?"),
    ("Speaker 2", "Daniel", "en", "The main open question is whether we support Windows next year."),
    ("Speaker 2", "Daniel", "en", "Minh Anh will send the Momos report to the whole team tomorrow."),
    ("Me", "Linh", "mixed", "Bên mình sẽ deploy bản hotfix lên Kubernetes tối nay."),
    ("Me", "Linh", "mixed", "Em đã tạo ticket trên Jira và gắn tag cho anh Tuấn rồi."),
    ("Me", "Linh", "mixed", "OKR của quý này tập trung vào retention và onboarding."),
    ("Me", "Linh", "mixed", "Chị gửi file báo cáo qua Zalo hoặc Slack đều được."),
    ("Me", "Linh", "mixed", "Database Postgres đang bị chậm, mình cần thêm index cho bảng orders."),
    ("Me", "Linh", "mixed", "Momos sẽ demo tính năng mới cho khách hàng vào tuần sau."),
    ("Me", "Linh", "mixed", "Sau buổi sprint review, anh Tuấn sẽ cập nhật dashboard trên Grafana."),
]
# A long Vietnamese monologue (one block, ~40 s) with glossary terms late in the block.
MONOLOGUE = [
    "Trước hết mình tóm tắt lại tình hình của tuần vừa rồi.",
    "Đội kỹ thuật đã sửa xong phần lớn các lỗi mà khách hàng báo cáo.",
    "Tuy nhiên vẫn còn một vài vấn đề về hiệu năng khi tải trang đầu tiên.",
    "Chị Minh Anh đề xuất chúng ta dành thêm hai ngày để kiểm thử kỹ hơn.",
    "Sau đó anh Tuấn sẽ deploy lên Kubernetes và theo dõi trên Grafana.",
    "Nếu mọi thứ ổn định thì cuối tuần này Momos sẽ thông báo cho khách hàng.",
]
NOISE_BLOCKS = [("room", 8.0), ("keyboard", 12.0), ("room", 25.0)]
SR = 16000
GAP = 1.0
LOOSE_EVERY = 3  # every third utterance block also covers 3 s of trailing silence

VARIANTS = {
    # name: (model, config overrides)
    "before": ("turbo", {"whisper_vad": False, "whisper_max_chunk_sec": 45.0, "glossary": []}),
    "glossary": ("turbo", {"whisper_vad": False, "whisper_max_chunk_sec": 45.0}),
    "vad": ("turbo", {"glossary": []}),
    "new": ("turbo", {}),
    "new-no-fallback": ("turbo", {"whisper_temperature_fallback": False}),
    "new-condition-prev": ("turbo", {"whisper_condition_on_previous_text": True}),
    "new-lead-prompt": ("turbo", {"_prompt_lead": {"vi": "Cuộc họp. Từ khóa:", "en": "Meeting. Terms:"}}),
    "new-vi-sentence": ("turbo", {"_prompt_lead": {"vi": "Cuộc họp có nhắc đến", "en": "The meeting mentions"}}),
    "large-before": ("large", {"whisper_vad": False, "whisper_max_chunk_sec": 45.0, "glossary": []}),
    "large-new": ("large", {}),
}
MODELS = {"turbo": "mlx-community/whisper-large-v3-turbo", "large": "mlx-community/whisper-large-v3-mlx"}


def say(voice: str, text: str, tmp: Path) -> np.ndarray:
    from meeting_notes.adapters.outbound.ffmpeg_audio import decode

    path = tmp / f"{abs(hash((voice, text)))}.aiff"
    subprocess.run(["say", "-v", voice, "-o", str(path), text], check=True)
    return decode(path)


def make(out: Path) -> None:
    from meeting_notes.adapters.outbound.wav_files import write_wav

    rng = np.random.default_rng(7)
    out.mkdir(parents=True, exist_ok=True)
    pieces: list[tuple[str, np.ndarray, dict]] = []
    with tempfile.TemporaryDirectory() as td:
        for i, (speaker, voice, cat, text) in enumerate(UTTERANCES):
            pieces.append(("speech", say(voice, text, Path(td)), {"speaker": speaker, "category": cat, "text": text,
                                                                     "loose": i % LOOSE_EVERY == 2}))
        mono = [say("Linh", t, Path(td)) for t in MONOLOGUE]
    joined = []
    for clip in mono:
        joined += [clip, np.zeros(int(0.6 * SR), np.float32)]
    pieces.insert(9, ("speech", np.concatenate(joined[:-1]), {"speaker": "Me", "category": "monologue",
                                                               "text": " ".join(MONOLOGUE), "loose": False}))
    for j, (kind, sec) in enumerate(NOISE_BLOCKS):
        pieces.insert(4 + 7 * j, ("noise", np.zeros(int(sec * SR), np.float32), {"kind": kind}))

    cursor, placed = 1.0, []
    for kind, clip, meta in pieces:
        placed.append((kind, cursor, clip, meta))
        cursor += len(clip) / SR + GAP + (3.0 if meta.get("loose") else 0.0)
    length = int((cursor + 1.0) * SR)
    track = np.zeros(length, np.float32)
    blocks = []
    for kind, start, clip, meta in placed:
        i = int(start * SR)
        end = start + len(clip) / SR
        if kind == "speech":
            track[i:i + len(clip)] += 0.6 * clip
            blocks.append({"start": round(start - 0.1, 3), "end": round(end + (3.0 if meta["loose"] else 0.1), 3), **meta})
        else:
            if meta["kind"] == "keyboard":
                taps = np.arange(start, end - 0.1, 0.18)
                for t in taps + rng.uniform(0, 0.08, len(taps)):
                    k = int(t * SR)
                    burst = rng.normal(0, 0.05, int(0.012 * SR)).astype(np.float32) * np.hanning(int(0.012 * SR)).astype(np.float32)
                    track[k:k + len(burst)] += burst
            blocks.append({"start": round(start, 3), "end": round(end, 3), "speaker": "Speaker 1", "category": "noise",
                           "text": "", "kind": meta["kind"], "loose": False})
    # Room tone everywhere: low pink-ish noise plus a faint mains hum.
    white = rng.normal(0, 1, length)
    pink = np.convolve(white, np.ones(8) / 8, mode="same")
    t = np.arange(length) / SR
    track += (0.003 * pink / pink.std() + 0.0015 * np.sin(2 * np.pi * 50 * t)).astype(np.float32)
    write_wav(out / "corpus.wav", track)
    (out / "corpus.json").write_text(json.dumps({"glossary": GLOSSARY, "blocks": blocks}, ensure_ascii=False, indent=1))
    speech = sum(b["end"] - b["start"] for b in blocks if b["category"] != "noise")
    print(f"{out}: {length / SR:.0f} s audio, {len(blocks)} blocks, {speech:.0f} s in speech blocks")


def cer(ref: str, hyp: str) -> tuple[int, int]:
    """(char errors, reference chars) on normalized words joined by single spaces."""
    from meeting_notes.domain.metrics import edit_distance, words

    r, h = " ".join(words(ref)), " ".join(words(hyp))
    return edit_distance(list(r), list(h)), len(r)


def routed_transcriber(cfg, vi_model: str):
    """Transcriber that detects language with cfg.whisper_model and decodes vi blocks with `vi_model`.

    mlx_whisper.transcribe reloads whenever the model path changes, so both models are loaded once and
    swapped into ModelHolder before each call."""
    import mlx.core as mx
    from mlx_whisper.load_models import load_model
    from mlx_whisper.transcribe import ModelHolder

    from meeting_notes.adapters.outbound.mlx_transcriber import Transcriber

    class Routed(Transcriber):
        _vi = None

        def transcribe_auto(self, audio, choose):
            language = choose(self.detect_language(audio))  # detect with the base model, decode routed
            return language, self.transcribe(audio, language)

        def transcribe(self, audio, language):
            base = self._load()
            if language == "vi":
                if Routed._vi is None:
                    Routed._vi = load_model(vi_model, mx.float16)
                ModelHolder.model, ModelHolder.model_path = Routed._vi, self.cfg.whisper_model
            try:
                return super().transcribe(audio, language)
            finally:
                ModelHolder.model, ModelHolder.model_path = base, self.cfg.whisper_model

    return Routed(cfg)


def run(out: Path, variant: str, model_path: str | None = None, vi_model: str | None = None) -> dict:
    from meeting_notes.adapters.outbound.mlx_transcriber import Transcriber
    from meeting_notes.adapters.outbound.wav_files import read_wav
    from meeting_notes.application import transcribe_blocks as TB
    from meeting_notes.application.transcribe_blocks import transcribe_blocks
    from meeting_notes.config import Config
    from meeting_notes.domain.metrics import term_hits, wer
    from meeting_notes.domain.segments import split_long_blocks
    from meeting_notes.domain.speakers import Block

    model, overrides = VARIANTS[variant]
    corpus = json.loads((out / "corpus.json").read_text())
    cfg = Config(whisper_model=model_path or MODELS[model], languages=["vi", "en"], glossary=corpus["glossary"])
    for k, v in overrides.items():
        if k == "_prompt_lead":
            TB.PROMPT_LEAD = v
        else:
            setattr(cfg, k, v)
    track = read_wav(out / "corpus.wav")
    tracks = {"mixed": track}
    truth = corpus["blocks"]
    tr = routed_transcriber(cfg, vi_model) if vi_model else Transcriber(cfg)
    t0 = time.monotonic()
    tr._load()
    tr.detect_language(np.zeros(SR, np.float32))
    load_sec = time.monotonic() - t0

    results = []
    t0 = time.monotonic()
    for b in truth:
        blk = Block(b["start"], b["end"], b["speaker"], "mixed", [(b["start"], b["end"])])
        pieces = split_long_blocks([blk], tracks, max_len=cfg.whisper_max_chunk_sec)
        segs = transcribe_blocks(pieces, tracks, tr, cfg.languages, vad=cfg.whisper_vad, split_gap=cfg.vad_split_gap)
        results.append(" ".join(s.text for s in segs))
    asr_sec = time.monotonic() - t0

    agg: dict[str, list[int]] = {}
    cagg: dict[str, list[int]] = {}
    hallucinated = 0
    terms = [0, 0]
    examples = []
    for b, hyp in zip(truth, results):
        if b["category"] == "noise":
            hallucinated += len(hyp.split())
            if hyp:
                examples.append({"noise": b["kind"], "hyp": hyp[:120]})
            continue
        e, n = wer(b["text"], hyp)
        ce, cn = cer(b["text"], hyp)
        for key in (b["category"], "all"):
            agg.setdefault(key, [0, 0])
            agg[key][0] += e
            agg[key][1] += n
            cagg.setdefault(key, [0, 0])
            cagg[key][0] += ce
            cagg[key][1] += cn
        h, p = term_hits(b["text"], hyp, corpus["glossary"])
        terms[0] += h
        terms[1] += p
        if e / max(n, 1) > 0.25:
            examples.append({"ref": b["text"][:120], "hyp": hyp[:160]})
    try:
        import mlx.core as mx

        peak_gpu = mx.get_peak_memory() / 2**30
    except Exception:
        peak_gpu = None
    import resource

    speech_sec = sum(b["end"] - b["start"] for b in truth)
    return {
        "variant": variant, "model": cfg.whisper_model.rstrip("/").split("/")[-1],
        "vi_model": vi_model.rstrip("/").split("/")[-1] if vi_model else None,
        "wer": {k: round(e / n, 4) for k, (e, n) in agg.items()},
        "cer": {k: round(e / n, 4) for k, (e, n) in cagg.items()},
        "term_recall": round(terms[0] / max(terms[1], 1), 3), "hallucinated_words": hallucinated,
        "asr_sec": round(asr_sec, 1), "rtf": round(asr_sec / speech_sec, 3), "load_sec": round(load_sec, 1),
        "peak_rss_gb": round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 2**30, 2),
        "peak_mlx_gb": round(peak_gpu, 2) if peak_gpu is not None else None,
        "examples": examples,
        "hyps": results,
    }


def label_for(name: str, opts: dict) -> str:
    if opts.get("label"):
        return opts["label"]
    tags = [Path(opts[k]).name for k in ("model", "vi_model") if opts.get(k)]
    return "@".join([name, *tags])


def run_all(out: Path, names: list[str], opts: dict | None = None) -> None:
    opts = opts or {}
    rows = []
    env = {**os.environ, "OMP_NUM_THREADS": "4", "VECLIB_MAXIMUM_THREADS": "4", "MKL_NUM_THREADS": "4"}
    extra = [a for k in ("model", "vi_model") if opts.get(k) for a in (f"--{k.replace('_', '-')}", opts[k])]
    for variant in names:
        name = label_for(variant, opts)
        proc = subprocess.run(["nice", "-n", "10", sys.executable, __file__, "run", str(out), variant, *extra],
                              capture_output=True, text=True, env=env)
        if proc.returncode:
            print(f"{name}: failed\n{proc.stderr[-1500:]}", file=sys.stderr)
            continue
        row = json.loads(proc.stdout.strip().splitlines()[-1])
        row["label"] = name
        rows.append(row)
        (out / f"result.{name}.json").write_text(json.dumps(row, ensure_ascii=False, indent=1))
        print(f"{name:20s} WER all {row['wer']['all']:.3f} vi {row['wer'].get('vi', 0):.3f} en {row['wer'].get('en', 0):.3f} "
              f"mixed {row['wer'].get('mixed', 0):.3f} mono {row['wer'].get('monologue', 0):.3f} "
              f"| CER vi {row['cer'].get('vi', 0):.3f} en {row['cer'].get('en', 0):.3f} mixed {row['cer'].get('mixed', 0):.3f} | terms {row['term_recall']:.2f} "
              f"| halluc {row['hallucinated_words']} | asr {row['asr_sec']}s rtf {row['rtf']} load {row['load_sec']}s "
              f"| rss {row['peak_rss_gb']} GB mlx {row['peak_mlx_gb']} GB", flush=True)


def main() -> None:
    import argparse

    ap = argparse.ArgumentParser(usage=__doc__)
    ap.add_argument("cmd", choices=["make", "run", "all"])
    ap.add_argument("out", type=Path)
    ap.add_argument("variants", nargs="?")
    ap.add_argument("--model")
    ap.add_argument("--vi-model")
    ap.add_argument("--label")
    a = ap.parse_args()
    cmd, out = a.cmd, a.out
    if cmd == "make":
        make(out)
    elif cmd == "run":
        from meeting_notes.adapters.outbound.system_resources import low_priority

        low_priority()
        print(json.dumps(run(out, a.variants or "new", a.model, a.vi_model), ensure_ascii=False))
    elif cmd == "all":
        run_all(out, a.variants.split(",") if a.variants else list(VARIANTS),
                {"model": a.model, "vi_model": a.vi_model, "label": a.label})


if __name__ == "__main__":
    main()
