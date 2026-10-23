"""Pure helpers for pipeline_bench: DER, per-track WER, system-counter parsing and run summaries."""

from __future__ import annotations

import re
import statistics

import numpy as np

from meeting_notes.domain.metrics import wer

PRESSURE_NAMES = {1: "normal", 2: "warn", 4: "critical"}  # kern.memorystatus_vm_pressure_level; 0 = unknown

Turn = tuple[float, float, str]


def der(ref: list[Turn], hyp: list[Turn], collar: float = 0.0, step: float = 0.01) -> dict:
    """Frame-based diarization error rate with an optimal one-to-one speaker mapping (overlap allowed).

    `collar` seconds around every reference boundary are not scored (0.25 is the usual forgiving setting)."""
    from scipy.optimize import linear_sum_assignment

    end = max([e for _, e, _ in ref + hyp], default=0.0)
    n = int(np.ceil(end / step)) + 1
    ref_labels = sorted({s for *_, s in ref})
    hyp_labels = sorted({s for *_, s in hyp})
    R = np.zeros((len(ref_labels), n), bool)
    H = np.zeros((len(hyp_labels), n), bool)
    for turns, labels, mat in ((ref, ref_labels, R), (hyp, hyp_labels, H)):
        for s, e, spk in turns:
            mat[labels.index(spk), int(round(s / step)):int(round(e / step))] = True
    scored = np.ones(n, bool)
    if collar > 0:
        c = int(round(collar / step))
        for s, e, _ in ref:
            for t in (s, e):
                i = int(round(t / step))
                scored[max(0, i - c):i + c] = False
    R, H = R[:, scored], H[:, scored]
    n_ref, n_hyp = R.sum(axis=0), H.sum(axis=0)
    correct = 0
    if ref_labels and hyp_labels:
        co = R.astype(np.int64) @ H.T.astype(np.int64)
        rows, cols = linear_sum_assignment(-co)
        correct = int(co[rows, cols].sum())
    total = int(n_ref.sum())
    miss = int(np.maximum(n_ref - n_hyp, 0).sum())
    fa = int(np.maximum(n_hyp - n_ref, 0).sum())
    conf = int(np.minimum(n_ref, n_hyp).sum()) - correct
    rate = (miss + fa + conf) / total if total else 0.0
    return {"der": round(rate, 4), "miss": round(miss / max(total, 1), 4), "fa": round(fa / max(total, 1), 4),
            "confusion": round(conf / max(total, 1), 4), "ref_sec": round(total * step, 1)}


def track_wer(ref_segments: list[dict], hyp_segments: list[dict]) -> dict[str, float]:
    """WER per track ("mic", "system") and over both, comparing time-ordered text per track."""
    out, agg = {}, [0, 0]
    for track in sorted({s["track"] for s in ref_segments}):
        ref = " ".join(s["text"] for s in sorted(ref_segments, key=lambda s: s["start"]) if s["track"] == track)
        hyp = " ".join(s["text"] for s in sorted(hyp_segments, key=lambda s: s["start"]) if s["track"] == track)
        e, n = wer(ref, hyp)
        out[track] = round(e / max(n, 1), 4)
        agg[0] += e
        agg[1] += n
    out["all"] = round(agg[0] / max(agg[1], 1), 4)
    return out


def parse_swap_used_mb(text: str) -> float | None:
    """`sysctl -n vm.swapusage` -> used MB ("total = 18432.00M  used = 17302.75M  free = ...")."""
    m = re.search(r"used\s*=\s*([\d.]+)([MG])", text)
    if not m:
        return None
    return float(m.group(1)) * (1024 if m.group(2) == "G" else 1)


def parse_vm_stat(text: str) -> dict[str, int]:
    """`vm_stat` -> {"page_size", "pageins", "pageouts", "swapins", "swapouts"} (pages; missing keys omitted)."""
    out: dict[str, int] = {}
    m = re.search(r"page size of (\d+) bytes", text)
    if m:
        out["page_size"] = int(m.group(1))
    for key, label in (("pageins", "Pageins"), ("pageouts", "Pageouts"), ("swapins", "Swapins"), ("swapouts", "Swapouts")):
        m = re.search(rf"^{label}:\s+(\d+)\.?$", text, re.M)
        if m:
            out[key] = int(m.group(1))
    return out


def vm_delta_mb(before: dict[str, int], after: dict[str, int]) -> dict[str, float]:
    page = after.get("page_size") or before.get("page_size") or 16384
    return {k: round((after[k] - before[k]) * page / 2**20, 1) for k in ("pageins", "pageouts", "swapins", "swapouts")
            if k in before and k in after}


def pressure_summary(samples: list[int]) -> dict:
    """Pressure levels sampled during a run -> start, worst, and seconds per level."""
    known = [s for s in samples if s in PRESSURE_NAMES]
    counts = {name: sum(1 for s in known if PRESSURE_NAMES[s] == name) for name in PRESSURE_NAMES.values()}
    return {"start": PRESSURE_NAMES.get(samples[0], "unknown") if samples else "unknown",
            "worst": PRESSURE_NAMES[max(known)] if known else "unknown",
            "best": PRESSURE_NAMES[min(known)] if known else "unknown",
            "samples": counts}


def condition(summary: dict) -> str:
    """Run label: "normal" only when pressure stayed normal the whole time, else the worst level seen."""
    return summary["worst"]


def mic_labels(turns: list[dict]) -> list[str]:
    return sorted({t["speaker"] for t in turns if t["track"] == "mic"})


def median_report(rows: list[dict]) -> list[dict]:
    """One row per (label, fixture): medians over repeats plus the conditions they ran under."""
    groups: dict[tuple[str, str], list[dict]] = {}
    for row in rows:
        groups.setdefault((row["label"], row["fixture"]), []).append(row)

    def med(values):
        values = [v for v in values if v is not None]
        return round(statistics.median(values), 3) if values else None

    out = []
    for (label, fixture), runs in groups.items():
        out.append({
            "label": label, "fixture": fixture, "runs": len(runs),
            "conditions": sorted({r["condition"] for r in runs}),
            "wall_sec": med([r["wall_sec"] for r in runs]),
            "diarize_sec": med([r["stages"].get("diarize") for r in runs]),
            "transcribe_sec": med([r["stages"].get("transcribe") for r in runs]),
            "peak_rss_gb": med([r["peak_rss_gb"] for r in runs]),
            "swap_delta_mb": med([r["swap_delta_mb"] for r in runs]),
            "wer_all": med([r["quality"]["wer"].get("all") for r in runs]),
            "der": med([r["quality"]["der"]["der"] for r in runs]),
            "der_c25": med([r["quality"]["der_collar"]["der"] for r in runs]),
            "mic_path": sorted({r["mic_path"] for r in runs}),
        })
    return out
