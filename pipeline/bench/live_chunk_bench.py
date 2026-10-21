"""T3 (realtime.md section 5): does per-VAD-chunk decoding during a meeting hurt quality?

  uv run python bench/live_chunk_bench.py <scratch> --meeting <folder>[=alias] ... [--synthetic] [--minutes 10]

Replays each track as a growing stream, cuts chunks with the design-A policy (min 4 s, max 28 s, pause >= 0.7 s,
pad 0.25 s), decodes each with the `transcribe_blocks` path and compares with the offline transcript, which
is the reference here (no human transcripts exist). Writes <scratch>/<alias>/{offline,live}.json and
<scratch>/t3.json; `live_reuse_bench.py` (T4) reuses those caches. Runs one model, one corpus at a time, nice 10.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import live_corpus as lc  # noqa: E402
from live_chunks import ChunkPolicy, replay_track  # noqa: E402
from live_eval import (compare, gate, language_agreement, pct, speech_recall, speech_seconds,  # noqa: E402
                       term_recall, text_of)

from meeting_notes.domain.metrics import wer  # noqa: E402


def chunk_stats(chunks: list[dict]) -> dict:
    speech = [c for c in chunks if c["speech"]]
    cut = [c for c in speech if not c["tail"]]  # policy cuts (the tail is whatever is left at Stop)
    rtf = [c["wall_sec"] / (c["end"] - c["start"]) for c in speech]
    lengths = [c["end"] - c["start"] for c in speech]
    return {
        "chunks": len(chunks), "speech_chunks": len(speech), "policy_cuts": len(cut),
        "forced": sum(c["forced"] for c in cut), "forced_pct": sum(c["forced"] for c in cut) / len(cut) if cut else None,
        "forced_all": sum(c["forced"] for c in chunks), "non_tail_chunks": sum(not c["tail"] for c in chunks),
        "len_median": pct(lengths, 50), "len_p90": pct(lengths, 90), "len_max": max(lengths, default=None),
        "rtf_median": pct(rtf, 50), "rtf_p90": pct(rtf, 90), "rtf_max": max(rtf, default=None),
        "wall_median": pct([c["wall_sec"] for c in speech], 50), "wall_p90": pct([c["wall_sec"] for c in speech], 90),
        "rtf_over_1": sum(r > 1.0 for r in rtf),
        "wall_sum": sum(c["wall_sec"] for c in speech), "chunk_sec_sum": sum(lengths),
    }


def vs_truth(corpus: lc.Corpus, offline: list[dict], live: list[dict]) -> dict | None:
    """Synthetic corpus only: WER of both transcripts against the known TTS text (the real corpora have none)."""
    if not corpus.truth:
        return None
    (eo, n), (el, _) = wer(corpus.truth, text_of(offline)), wer(corpus.truth, text_of(live))
    return {"ref_words": n, "offline_wer": eo / n, "live_wer": el / n, "delta": (el - eo) / n}


def evaluate(corpus: lc.Corpus, offline: dict, chunks: list[dict]) -> dict:
    ref = offline["segments"]
    live_all = [s for c in chunks for s in c["segments"]]
    live = gate(live_all, corpus.turns)
    return {
        "name": corpus.name, "kind": corpus.kind, "audio_sec": corpus.audio_sec, "turn_sec": corpus.turn_sec,
        "ref_segments": len(ref), "ref_speech_sec": speech_seconds(ref), "live_speech_sec": speech_seconds(live),
        "gated_out_segments": len(live_all) - len(live),
        "gated": compare(ref, live), "raw": compare(ref, live_all), "vs_truth": vs_truth(corpus, ref, live),
        "language": language_agreement(ref, live), "speech_recall": speech_recall(ref, live), "terms": term_recall(ref, live, corpus.glossary),
        "chunks": chunk_stats(chunks),
        "offline_wall_sec": offline["wall_sec"], "offline_block_sec": offline["block_sec"],
    }


def pooled(rows: list[dict]) -> dict:
    ch = [r["chunks"] for r in rows]
    cuts = sum(c["policy_cuts"] for c in ch)
    errors, words = sum(r["gated"]["wer_errors"] for r in rows), sum(r["gated"]["ref_words"] for r in rows)
    raw = sum(r["raw"]["wer_errors"] for r in rows)
    lang = (sum(r["language"]["agree_sec"] for r in rows), sum(r["language"]["overlap_sec"] for r in rows))
    terms = (sum(r["terms"]["hits"] for r in rows), sum(r["terms"]["present"] for r in rows))
    rtf_n = sum(c["speech_chunks"] for c in ch)
    return {
        "corpora": [r["name"] for r in rows], "ref_words": words,
        "wer_gated": errors / words if words else None, "wer_raw": raw / words if words else None,
        "forced_pct": sum(c["forced"] for c in ch) / cuts if cuts else None, "policy_cuts": cuts,
        "forced_pct_all_chunks": sum(c["forced_all"] for c in ch) / max(1, sum(c["non_tail_chunks"] for c in ch)),
        "all_chunks": sum(c["non_tail_chunks"] for c in ch),
        "language_pct": lang[0] / lang[1] if lang[1] else None, "language_sec": lang[1],
        "term_recall": terms[0] / terms[1] if terms[1] else None, "terms_present": terms[1],
        "speech_chunks": rtf_n, "rtf_over_1": sum(c["rtf_over_1"] for c in ch),
        "wall_sum": sum(c["wall_sum"] for c in ch), "chunk_sec_sum": sum(c["chunk_sec_sum"] for c in ch),
    }


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    lc.add_corpus_args(ap)
    ap.add_argument("--force", action="store_true", help="ignore cached offline/live results")
    ap.add_argument("--min-sec", type=float, default=ChunkPolicy.min_sec, help="policy variant: minimum chunk length")
    ap.add_argument("--pause-sec", type=float, default=ChunkPolicy.pause_sec, help="policy variant: pause that closes a chunk")
    ap.add_argument("--tag", default="", help="suffix for live/t3 result files of a policy variant")
    args = ap.parse_args()
    from meeting_notes.adapters.outbound.system_resources import low_priority

    low_priority()
    corpora = lc.corpora(args)
    if not corpora:
        raise SystemExit("no corpus: pass --meeting and/or --synthetic")
    suffix = f".{args.tag}" if args.tag else ""
    cached_all = all((args.scratch / c.name / f).exists() for c in corpora for f in ("offline.json", f"live{suffix}.json"))
    if not cached_all or args.force:
        print(f"memory pressure level {lc.wait_for_normal_pressure(args.max_wait_min, args.allow_warn)} (1 = normal)", flush=True)
    policy, rows = ChunkPolicy(min_sec=args.min_sec, pause_sec=args.pause_sec), []
    tr = cfg = None
    for corpus in corpora:
        cfg = lc.make_config(corpus.glossary)
        work = args.scratch / corpus.name
        if tr is None or any(not (work / f).exists() for f in ("offline.json", f"live{suffix}.json")) or args.force:
            tr = tr or lc.load_transcriber(cfg)
            tr.cfg = tr.inner.cfg = cfg  # per-corpus glossary for the prompt; the model stays loaded
        offline = lc.cached(work / "offline.json", lambda: lc.offline_reference(corpus, tr, cfg), args.force)
        chunks = lc.cached(work / f"live{suffix}.json", lambda: [c for n, x in corpus.tracks.items()
                                                        for c in replay_track(x, n, tr, cfg, policy)], args.force)
        rows.append(evaluate(corpus, offline, chunks))
        g = rows[-1]
        print(f"{corpus.name}: audio {g['audio_sec']:.0f}s turns {g['turn_sec']:.0f}s | WER live-vs-offline "
              f"{g['gated']['wer']} CER {g['gated']['cer']} | forced {g['chunks']['forced_pct']} | "
              f"lang {g['language']['pct']} | rtf p90 {g['chunks']['rtf_p90']}", flush=True)
    real, syn = [r for r in rows if r["kind"] == "real"], [r for r in rows if r["kind"] == "synthetic"]
    out = {"policy": policy.__dict__, "corpora": rows,
           "pooled": {"all": pooled(rows), "real": pooled(real) if real else None, "synthetic": pooled(syn) if syn else None}}
    (args.scratch / f"t3{suffix}.json").write_text(json.dumps(out, ensure_ascii=False, indent=1))
    print(json.dumps(out["pooled"], indent=1))
    print(json.dumps({r["name"]: r["vs_truth"] for r in rows if r["vs_truth"]}, indent=1))


if __name__ == "__main__":
    main()
