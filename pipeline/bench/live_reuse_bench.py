"""T4 (realtime.md section 5): how much Stop-time work can live partials save, and at what quality cost?

  uv run python bench/live_reuse_bench.py <scratch> --meeting <folder>[=alias] ... [--synthetic]   (same args as T3)

Needs <scratch>/<alias>/{offline,live}.json from `live_chunk_bench.py`. For each corpus and rule variant
(`spec` = the 4.1 text; `strict` = also re-decode forced and multi-speaker chunks): `merge_partials` over the live
chunks and the existing diarization turns, re-decode only the uncovered turn time with the `transcribe_blocks`
path, then compare reuse + re-decode with the offline transcript. Post-Stop time is modelled from the learned
per-stage speed factors (~/.cache/meeting-notes/timings.json, EMA of real runs) and the measured decode times.
Writes <scratch>/<alias>/redo.<variant>.json and <scratch>/t4.json.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from dataclasses import asdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import live_corpus as lc  # noqa: E402
from live_eval import compare, pct, text_of  # noqa: E402
from live_merge import clip_turns, merge_partials  # noqa: E402

from meeting_notes.domain.intervals import overlap, total  # noqa: E402
from meeting_notes.domain.metrics import wer  # noqa: E402
from meeting_notes.domain.segments import split_long_blocks  # noqa: E402
from meeting_notes.domain.speakers import build_blocks  # noqa: E402

HOUR = 3600.0


def redecode(corpus: lc.Corpus, uncovered, tr, cfg) -> dict:
    from meeting_notes.application.transcribe_blocks import transcribe_blocks

    blocks = split_long_blocks(build_blocks(clip_turns(corpus.turns, uncovered)), corpus.tracks, cfg.whisper_max_chunk_sec)
    t0 = time.monotonic()
    segs = transcribe_blocks(blocks, corpus.tracks, tr, cfg.languages, vad=cfg.whisper_vad, split_gap=cfg.vad_split_gap) if blocks else []
    return {"segments": [asdict(s) for s in segs], "wall_sec": time.monotonic() - t0, "block_sec": sum(b.duration for b in blocks)}


def speaker_agreement(ref: list[dict], hyp: list[dict]) -> float | None:
    same = both = 0.0
    for h in hyp:
        for r in ref:
            if r["track"] == h["track"]:
                o = overlap((h["start"], h["end"]), (r["start"], r["end"]))
                both += o
                same += o if r["speaker"] == h["speaker"] else 0.0
    return same / both if both else None


def track_sec(turns, track: str) -> float:
    return sum(t.duration for t in turns if t.track == track)


def vs_truth(corpus: lc.Corpus, offline: list[dict], final: list[dict]) -> dict | None:
    """Synthetic corpora only: WER of the offline transcript and of reuse + re-decode against the known TTS text."""
    if not corpus.truth:
        return None
    (eo, n), (ef, _) = wer(corpus.truth, text_of(offline)), wer(corpus.truth, text_of(final))
    return {"ref_words": n, "offline_errors": eo, "final_errors": ef}


def evaluate(corpus: lc.Corpus, offline: dict, redo: dict, merged, merged_no_tail) -> dict:
    final = sorted(merged.segments + redo["segments"], key=lambda s: (s["start"], s["end"]))
    ref = offline["segments"]
    out = {
        "name": corpus.name, "kind": corpus.kind, "audio_sec": corpus.audio_sec, "turn_sec": corpus.turn_sec,
        "kept": len(merged.segments), "dropped_outside_turns": len(merged.dropped), "ambiguous_segments": len(merged.ambiguous),
        "minority_sec": merged.minority_sec, "final": compare(ref, final), "speaker_agreement": speaker_agreement(ref, final),
        "vs_truth": vs_truth(corpus, ref, final),
        "redo_wall_sec": redo["wall_sec"], "redo_block_sec": redo["block_sec"],
        "offline_wall_sec": offline["wall_sec"], "offline_block_sec": offline["block_sec"], "tracks": {},
    }
    for track in sorted(corpus.tracks):
        out["tracks"][track] = {"speech_sec": track_sec(corpus.turns, track),
                                "redecode_sec": total(merged.uncovered.get(track, [])),
                                "redecode_sec_no_tail": total(merged_no_tail.uncovered.get(track, []))}
    return out


def pooled(rows: list[dict]) -> dict:
    if not rows:
        return {}
    errors, words = sum(r["final"]["wer_errors"] for r in rows), sum(r["final"]["ref_words"] for r in rows)
    truth = [r["vs_truth"] for r in rows if r["vs_truth"]]
    t_words = sum(t["ref_words"] for t in truth)
    speech = sum(r["turn_sec"] for r in rows)
    system = [r["tracks"]["system"] for r in rows if "system" in r["tracks"]]
    sys_sp = sum(t["speech_sec"] for t in system)
    redo = lambda key, ts: sum(t[key] for t in ts)  # noqa: E731
    all_tracks = [t for r in rows for t in r["tracks"].values()]
    return {
        "corpora": [r["name"] for r in rows], "ref_words": words, "wer_vs_offline": errors / words if words else None,
        "truth_words": t_words, "offline_wer_vs_truth": sum(t["offline_errors"] for t in truth) / t_words if t_words else None,
        "final_wer_vs_truth": sum(t["final_errors"] for t in truth) / t_words if t_words else None,
        "system_speech_sec": sys_sp, "system_redecode_pct": redo("redecode_sec", system) / sys_sp if sys_sp else None,
        "system_redecode_pct_no_tail": redo("redecode_sec_no_tail", system) / sys_sp if sys_sp else None,
        "all_redecode_pct": redo("redecode_sec", all_tracks) / speech if speech else None,
        "all_redecode_pct_no_tail": redo("redecode_sec_no_tail", all_tracks) / speech if speech else None,
        "minority_sec": sum(r["minority_sec"] for r in rows),
        "ambiguous_segments": sum(r["ambiguous_segments"] for r in rows),
        "speaker_agreement": sum((r["speaker_agreement"] or 0) * r["turn_sec"] for r in rows) / speech if speech else None,
    }


def timing_model(rows: list[dict], chunk_wall_p90: float) -> dict:
    """Post-Stop wall time of a 1 h meeting: today vs design A, from learned stage factors and measured ratios.

    Only the transcribe stage shrinks (by the re-decoded share of speech); the tail of a 1 h meeting is one chunk,
    added as its measured p90 decode time. prepare, diarize, summarize, render, finalize are unchanged."""
    from meeting_notes.adapters.outbound.speed_history import load_speed

    speed = load_speed()
    stage = {k: f * HOUR + o for k, (f, o) in speed.items()}
    today = sum(stage.values())
    speech = sum(r["turn_sec"] for r in rows)
    r = sum(t["redecode_sec_no_tail"] for row in rows for t in row["tracks"].values()) / speech if speech else 0.0
    other = today - stage["transcribe"] - stage["diarize"]
    transcribe_a = (stage["transcribe"] - speed["transcribe"][1]) * r + chunk_wall_p90  # worker keeps the model warm
    scenarios = {}
    for label, factor in (("pyannote as today", 1.0), ("diarization 2x faster", 0.5), ("diarization 5x faster", 0.2)):
        post = other + stage["diarize"] * factor + transcribe_a
        scenarios[label] = {"post_stop_sec": post, "ratio_vs_today": post / today}
    return {"stage_sec_1h": stage, "today_sec": today, "redecode_share": r, "transcribe_a_sec": transcribe_a,
            "scenarios": scenarios, "diarize_max_for_50pct_sec": 0.5 * today - other - transcribe_a,
            "diarize_today_sec": stage["diarize"]}


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    lc.add_corpus_args(ap)
    args = ap.parse_args()
    from meeting_notes.adapters.outbound.system_resources import low_priority

    low_priority()
    corpora = lc.corpora(args)
    tr, rows = None, {"spec": [], "strict": []}
    for corpus in corpora:
        work = args.scratch / corpus.name
        offline = json.loads((work / "offline.json").read_text())
        chunks = json.loads((work / "live.json").read_text())
        cfg = lc.make_config(corpus.glossary)
        for variant in rows:
            strict = variant == "strict"
            merged = merge_partials(corpus.turns, chunks, strict=strict)
            no_tail = merge_partials(corpus.turns, [{**c, "tail": False} for c in chunks], strict=strict)

            def compute():
                nonlocal tr
                if not any(merged.uncovered.values()):
                    return {"segments": [], "wall_sec": 0.0, "block_sec": 0.0}
                if tr is None:
                    print(f"memory pressure level {lc.wait_for_normal_pressure(args.max_wait_min, args.allow_warn)}", flush=True)
                    tr = lc.load_transcriber(cfg)
                tr.cfg = tr.inner.cfg = cfg
                return redecode(corpus, merged.uncovered, tr, cfg)

            redo = lc.cached(work / ("redo.json" if not strict else "redo.strict.json"), compute)
            rows[variant].append(evaluate(corpus, offline, redo, merged, no_tail))
            r = rows[variant][-1]
            print(f"{variant:6s} {corpus.name}: kept {r['kept']} dropped {r['dropped_outside_turns']} ambiguous "
                  f"{r['ambiguous_segments']} | WER vs offline {r['final']['wer']} | speaker agree {r['speaker_agreement']}", flush=True)
    walls = [c["wall_sec"] for corpus in corpora for c in json.loads((args.scratch / corpus.name / "live.json").read_text()) if c["speech"]]
    out = {"variants": {}}
    for variant, vrows in rows.items():
        real = [r for r in vrows if r["kind"] == "real"]
        syn = [r for r in vrows if r["kind"] == "synthetic"]
        out["variants"][variant] = {"corpora": vrows, "pooled": {"all": pooled(vrows), "real": pooled(real), "synthetic": pooled(syn)},
                                    "timing": timing_model(vrows, pct(walls, 90) or 0.0)}
    (args.scratch / "t4.json").write_text(json.dumps(out, ensure_ascii=False, indent=1))
    print(json.dumps({v: {"pooled": d["pooled"]["all"], "timing": d["timing"]["scenarios"]} for v, d in out["variants"].items()}, indent=1))


if __name__ == "__main__":
    main()
