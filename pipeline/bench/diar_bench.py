"""Diarization-only benchmark (plan 0.3 / 3.5): DER, speaker-count error, time, peak RSS, swap, memory pressure.

  uv run python bench/diar_bench.py make <dir> [--minutes 12] [--remote 2] [--local 1] [--bleed] [--seed 0]
  uv run python bench/diar_bench.py run <dir> [--engine pyannote|sherpa-onnx] [--label NAME] [--set key=value ...]
                                    [--repeat 2] [--wait-normal 600] [--allow-warn]
  uv run python bench/diar_bench.py report <dir> [<dir> ...]

Fixtures are the pipeline_bench ones (bench/meeting_fixture.py: <dir>/meeting + reference.json). `run` executes
only the diarize stage (`application.diarize_tracks`: system track, mic voice check / full mic pass, two-track
merge) in a fresh process at low priority (nice 10 + utility QoS under `taskpolicy -c utility`), one run at a
time, with config = defaults + `diarization_engine` + `--set` (your config.toml is not read). Audio decoding is not
timed. Each run appends one JSON line to <dir>/diar_results.jsonl: model load and diarize seconds, peak RSS,
whether torch was imported, swap delta, vm_stat delta, memory pressure (start / worst / seconds per level), AC or
battery, DER (collar 0 and 0.25, overall and per track) and speaker-count error vs reference.json.

Memory pressure: as pipeline_bench, a run waits up to --wait-normal seconds for "normal", then fails, or with
--allow-warn runs anyway and is labelled with the worst level seen. Never point it at ~/MeetingNotes.
"""

from __future__ import annotations

import argparse
import json
import os
import statistics
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

from bench_metrics import condition, der, pressure_summary, vm_delta_mb
from pipeline_bench import (PressureSampler, ensure_outside_user_notes, parse_sets, snapshot, toml_text,
                            wait_for_normal)

RESULTS = "diar_results.jsonl"
Turn = tuple[float, float, str]


# ------------------------------------------------------------ scoring (pure)


def speaker_counts(ref: list[dict], hyp: list[dict]) -> dict:
    """Distinct speakers in reference vs hypothesis, overall and per track; error = hyp - ref."""
    out = {}
    for scope in ("all", "mic", "system"):
        r = {s["speaker"] for s in ref if scope == "all" or s["track"] == scope}
        h = {t["speaker"] for t in hyp if scope == "all" or t["track"] == scope}
        out[scope] = {"ref": len(r), "hyp": len(h), "error": len(h) - len(r)}
    return out


def score(reference: dict, turns: list[dict]) -> dict:
    """DER (collar 0 / 0.25) over both tracks and per track, plus speaker counts."""
    def pick(items, track):
        return [(x["start"], x["end"], x["speaker"]) for x in items if track is None or x["track"] == track]

    ref = reference["segments"]
    out = {"der": der(pick(ref, None), pick(turns, None)),
           "der_collar": der(pick(ref, None), pick(turns, None), collar=0.25),
           "speakers": speaker_counts(ref, turns)}
    for track in ("mic", "system"):
        out[f"der_{track}"] = der(pick(ref, track), pick(turns, track))["der"]
    return out


def summarize(rows: list[dict]) -> list[dict]:
    """One row per (label, fixture): medians over repeats, the conditions seen, speaker-count errors."""
    groups: dict[tuple[str, str], list[dict]] = {}
    for row in rows:
        groups.setdefault((row["label"], row["fixture"]), []).append(row)

    def med(values):
        values = [v for v in values if v is not None]
        return round(statistics.median(values), 3) if values else None

    out = []
    for (label, fixture), runs in groups.items():
        q = [r["quality"] for r in runs]
        out.append({
            "label": label, "fixture": fixture, "runs": len(runs),
            "conditions": sorted({r["condition"] for r in runs}),
            "total_sec": med([r["load_sec"] + r["diarize_sec"] for r in runs]),
            "load_sec": med([r["load_sec"] for r in runs]), "diarize_sec": med([r["diarize_sec"] for r in runs]),
            "rtf": med([r["diarize_sec"] / max(r["audio_sec"], 1e-9) for r in runs]),
            "peak_rss_gb": med([r["peak_rss_gb"] for r in runs]),
            "swap_delta_mb": med([r["swap_delta_mb"] for r in runs]),
            "der": med([x["der"]["der"] for x in q]), "der_c25": med([x["der_collar"]["der"] for x in q]),
            "der_system": med([x["der_system"] for x in q]), "der_mic": med([x["der_mic"] for x in q]),
            "spk_err": sorted({x["speakers"]["all"]["error"] for x in q}),
            "methods": sorted({m for r in runs for m in r["methods"]}),
        })
    return out


# ------------------------------------------------------------ child process


class QuietReporter:
    def progress(self, fraction: float, message: str = "") -> None:
        pass

    def log(self, message: str) -> None:
        print(message, file=sys.stderr)


def load_tracks(meeting: Path) -> tuple[dict, float]:
    """Decode and align tracks exactly as the prepare stage does -> ({name: audio}, seconds)."""
    from meeting_notes.adapters.outbound.audio_files import AudioFiles
    from meeting_notes.domain.signal import SR, place

    info = json.loads((meeting / "meeting.json").read_text())["tracks"]
    decoded = {n: (AudioFiles().decode(meeting / t["file"]), float(t.get("start_offset_sec", 0.0))) for n, t in info.items()}
    length = max(int(round(off * SR)) + len(x) for x, off in decoded.values())
    return {n: place(x, off, length) for n, (x, off) in decoded.items()}, length / SR


def child(fixture: Path) -> None:
    """Fresh process: load the diarizer, run the diarize stage, print one JSON line."""
    import resource

    from meeting_notes.adapters.outbound.system_resources import apply_priority, limit_threads
    from meeting_notes.config import Config

    cfg = Config.load(Path(os.environ["MEETING_NOTES_CONFIG"]))
    limit_threads(cfg.cpu_threads)
    apply_priority(cfg.priority)
    tracks, audio_sec = load_tracks(fixture / "meeting")
    from meeting_notes.adapters.outbound.model_cache import make_diarizer
    from meeting_notes.application.diarize_tracks import diarize_tracks

    t0 = time.monotonic()
    diarizer = make_diarizer(cfg, log=QuietReporter().log)
    diarizer.engine() if hasattr(diarizer, "engine") else diarizer.pipeline()
    t1 = time.monotonic()
    turns, methods, notes = diarize_tracks(tracks, diarizer, cfg, QuietReporter())
    t2 = time.monotonic()
    print(json.dumps({"load_sec": round(t1 - t0, 2), "diarize_sec": round(t2 - t1, 2), "audio_sec": round(audio_sec, 1),
                      "peak_rss_gb": round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 2**30, 3),
                      "torch_loaded": "torch" in sys.modules, "methods": methods, "notes": notes,
                      "turns": [t.to_dict() for t in turns]}))


# ------------------------------------------------------------ one run


def run_once(fixture: Path, label: str, settings: dict, index: int, args) -> dict:
    reference = json.loads((fixture / "reference.json").read_text())
    scratch = fixture / "diar_runs"
    scratch.mkdir(exist_ok=True)
    config_path = scratch / f"{label}.toml"
    config_path.write_text(toml_text({"notes_dir": str(scratch), **settings}))
    level = wait_for_normal(args.wait_normal)
    if level not in (0, 1) and not args.allow_warn:
        raise SystemExit(f"memory pressure is {level} (not normal) after {args.wait_normal:.0f} s; use --allow-warn")
    before = snapshot()
    sampler = PressureSampler()
    sampler.start()
    env = {**os.environ, "MEETING_NOTES_CONFIG": str(config_path)}
    proc = subprocess.run(["taskpolicy", "-c", "utility", sys.executable, __file__, "child", str(fixture)],
                          capture_output=True, text=True, env=env)
    pressure = pressure_summary(sampler.stop())
    after = snapshot()
    if proc.returncode or not proc.stdout.strip():
        (scratch / f"{label}-{index}.stderr.log").write_text(proc.stderr)
        raise SystemExit(f"run failed ({proc.returncode}); see {scratch / f'{label}-{index}.stderr.log'}")
    result = json.loads(proc.stdout.strip().splitlines()[-1])
    swap = None
    if None not in (after["swap_used_mb"], before["swap_used_mb"]):
        swap = round(after["swap_used_mb"] - before["swap_used_mb"], 1)
    row = {
        "label": label, "fixture": fixture.name, "run": index, "settings": settings,
        "started_at": datetime.now().isoformat(timespec="seconds"),
        **{k: result[k] for k in ("load_sec", "diarize_sec", "audio_sec", "peak_rss_gb", "torch_loaded", "methods", "notes")},
        "swap_before_mb": before["swap_used_mb"], "swap_delta_mb": swap,
        "vm_delta_mb": vm_delta_mb(before["vm"], after["vm"]),
        "pressure": pressure, "condition": condition(pressure), "on_battery": before["on_battery"],
        "quality": score(reference, result["turns"]),
    }
    with (fixture / RESULTS).open("a") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")
    return row


def print_row(row: dict) -> None:
    q = row["quality"]
    print(f"{row['label']}#{row['run']} {row['fixture']} [{row['condition']}] load {row['load_sec']}s diarize "
          f"{row['diarize_sec']}s | rss {row['peak_rss_gb']} GB torch {row['torch_loaded']} swap {row['swap_delta_mb']} MB"
          f" | DER {q['der']['der']} (c0.25 {q['der_collar']['der']}, system {q['der_system']}, mic {q['der_mic']})"
          f" spk {q['speakers']['all']['hyp']}/{q['speakers']['all']['ref']} | {', '.join(row['methods'])}", flush=True)


def report(fixtures: list[Path]) -> None:
    rows = []
    for fixture in fixtures:
        path = fixture / RESULTS
        if path.exists():
            rows += [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    cols = ["label", "fixture", "runs", "conditions", "total_sec", "load_sec", "diarize_sec", "rtf", "peak_rss_gb",
            "swap_delta_mb", "der", "der_c25", "der_system", "der_mic", "spk_err"]
    print("| " + " | ".join(cols) + " |\n|" + "---|" * len(cols))
    for r in summarize(rows):
        print("| " + " | ".join(str(r[c]) for c in cols) + " |")


def main() -> None:
    ap = argparse.ArgumentParser(usage=__doc__)
    ap.add_argument("cmd", choices=["make", "run", "report", "child"])
    ap.add_argument("dirs", nargs="+")
    ap.add_argument("--engine", default="pyannote")
    ap.add_argument("--minutes", type=float, default=12.0)
    ap.add_argument("--remote", type=int, default=2)
    ap.add_argument("--local", type=int, default=1)
    ap.add_argument("--bleed", action="store_true")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--label")
    ap.add_argument("--set", dest="sets", action="append", default=[])
    ap.add_argument("--repeat", type=int, default=2)
    ap.add_argument("--wait-normal", type=float, default=600.0)
    ap.add_argument("--allow-warn", action="store_true")
    args = ap.parse_args()
    paths = [Path(d).expanduser() for d in args.dirs]
    ensure_outside_user_notes(*paths)
    if args.cmd == "child":
        child(paths[0])
    elif args.cmd == "report":
        report(paths)
    elif args.cmd == "make":
        from meeting_fixture import make_fixture

        print(make_fixture(paths[0], args.minutes, args.remote, args.local, args.bleed, args.seed))
    else:
        settings = {"diarization_engine": args.engine, **parse_sets(args.sets)}
        label = args.label or ",".join(f"{k}={v}" for k, v in settings.items())
        for fixture in paths:
            for i in range(args.repeat):
                print_row(run_once(fixture, label, settings, i, args))


if __name__ == "__main__":
    main()
