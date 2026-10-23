"""Whole-pipeline benchmark: stage timings, peak memory, swap and memory pressure, WER and DER per run.

  uv run python bench/pipeline_bench.py make <dir> [--minutes 12] [--remote 2] [--local 1] [--bleed] [--seed 0]
  uv run python bench/pipeline_bench.py run <dir> [--label NAME] [--set key=value ...] [--repeat 3]
                                        [--with-summary] [--wait-normal 600] [--allow-warn] [--keep] [--jobs 1]
  uv run python bench/pipeline_bench.py report <dir>

`make` writes a synthetic fixture (bench/meeting_fixture.py). `run` copies <dir>/meeting to a scratch folder and
processes the copy in a fresh process (`meeting-notes process`, priority "low" = nice 10 + utility QoS, under
`taskpolicy -c utility`), one run at a time. Config = defaults + `--set` overrides (your config.toml is not
read; rename_folder is off). Summaries are skipped unless --with-summary (they need local Ollama).
Each run appends one JSON line to <dir>/results.jsonl: stage timings, wall time, peak RSS, MLX peak, swap
used before/after, vm_stat page-ins/outs delta, memory pressure sampled every second (start / best / worst,
seconds per level), Ollama models resident, AC/battery, diarization methods and WER / DER vs reference.json.

--jobs N processes N copies one after another in one process with one shared model cache, as the app's worker does
for queued meetings, so `--set keep_models_warm=auto|false|true` can be compared (per-job wall in "job_walls").

Memory pressure: a run waits up to --wait-normal seconds for "normal"; then it fails, or with --allow-warn runs
anyway and is labelled with the worst level seen ("condition"). Never point it at ~/MeetingNotes.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import threading
import time
import urllib.request
from datetime import datetime
from pathlib import Path

from bench_metrics import (condition, der, median_report, mic_labels, parse_swap_used_mb, parse_vm_stat,
                           pressure_summary, track_wer, vm_delta_mb)

USER_NOTES = Path("~/MeetingNotes").expanduser()
STUB_SUMMARY = {"title": "", "summary": [], "decisions": [], "action_items": [], "open_questions": []}


def ensure_outside_user_notes(*paths: Path) -> None:
    """Refuse to read or write anything inside ~/MeetingNotes (the user's real recordings)."""
    for p in paths:
        resolved = Path(p).expanduser().resolve()
        if resolved == USER_NOTES.resolve() or USER_NOTES.resolve() in resolved.parents:
            raise SystemExit(f"refusing to use {resolved}: inside {USER_NOTES} (user recordings)")


def parse_sets(items: list[str]) -> dict:
    """["mic_voice_check=false", "cpu_threads=4"] -> TOML-typed values."""
    import tomllib

    out = {}
    for item in items:
        key, _, value = item.partition("=")
        if not key or not _:
            raise SystemExit(f"--set expects key=value, got {item!r}")
        try:
            out[key] = tomllib.loads(f"v = {value}")["v"]
        except tomllib.TOMLDecodeError:
            out[key] = value
    return out


def toml_text(values: dict) -> str:
    return "".join(f"{k} = {json.dumps(v)}\n" for k, v in values.items())


# ------------------------------------------------------------ system counters


def sh(*cmd: str) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def pressure_level() -> int:
    from meeting_notes.adapters.outbound.load_probe import memory_pressure_level

    return memory_pressure_level()


def snapshot() -> dict:
    from meeting_notes.adapters.outbound.load_probe import on_battery

    return {"swap_used_mb": parse_swap_used_mb(sh("sysctl", "-n", "vm.swapusage")), "vm": parse_vm_stat(sh("vm_stat")),
            "on_battery": on_battery()}


def ollama_models(url: str = "http://127.0.0.1:11434") -> list[str] | None:
    try:
        with urllib.request.urlopen(f"{url}/api/ps", timeout=2) as r:
            return [m.get("name", "") for m in json.loads(r.read()).get("models", [])]
    except Exception:
        return None  # Ollama not running


class PressureSampler(threading.Thread):
    def __init__(self, every: float = 1.0):
        super().__init__(daemon=True)
        self.every, self.samples, self._stop_event = every, [], threading.Event()

    def run(self) -> None:
        while not self._stop_event.is_set():
            self.samples.append(pressure_level())
            self._stop_event.wait(self.every)

    def stop(self) -> list[int]:
        self._stop_event.set()
        self.join(timeout=5)
        return self.samples


def wait_for_normal(timeout: float) -> int:
    deadline = time.monotonic() + timeout
    level = pressure_level()
    while level not in (0, 1) and time.monotonic() < deadline:
        time.sleep(5)
        level = pressure_level()
    return level


# ------------------------------------------------------------ one run


def child(folder: str, jobs: int = 1) -> None:
    """Fresh process: run the pipeline on `folder`, print one JSON line (exit, wall, peak RSS, MLX peak).

    jobs > 1: process `folder` and its copies `folder-2..N` one after another in this process with one shared
    model cache built from `keep_models_warm`, as the app's worker does for queued meetings."""
    import contextlib
    import resource

    from meeting_notes.entrypoints.cli import main

    t0 = time.monotonic()
    walls = []
    with open(Path(folder) / "bench.stdout.log", "w") as log, contextlib.redirect_stdout(log):
        if jobs == 1:
            code = main(["process", folder])
        else:
            code = queued_jobs([folder] + [f"{folder}-{i}" for i in range(2, jobs + 1)], walls)
    wall = time.monotonic() - t0
    mlx_peak = None
    if "mlx.core" in sys.modules:
        mlx_peak = round(sys.modules["mlx.core"].get_peak_memory() / 2**30, 3)
    print(json.dumps({"exit": code, "wall_sec": round(wall, 1), "mlx_peak_gb": mlx_peak, "job_walls": walls,
                      "peak_rss_gb": round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 2**30, 3)}))


def queued_jobs(folders: list[str], walls: list[float]) -> int:
    """Worker-style queue: one Models(keep=keep_models_warm) shared by every job; per-job wall time into `walls`."""
    from meeting_notes.adapters.outbound.system_resources import apply_priority, limit_threads
    from meeting_notes.config import Config
    from meeting_notes.entrypoints.wiring import make_models, make_processor, make_reporter

    cfg = Config.load()
    limit_threads(cfg.cpu_threads)
    apply_priority(cfg.priority)
    models = make_models(cfg, cfg.keep_models_warm)
    for folder in folders:
        t = time.monotonic()
        make_processor(Path(folder), cfg, make_reporter(), models).run(None)
        walls.append(round(time.monotonic() - t, 1))
    models.release()
    return 0


def quality(folder: Path, reference: dict) -> dict:
    diar = json.loads((folder / ".work" / "diarization.json").read_text())
    transcript = json.loads((folder / "transcript.json").read_text())
    ref_turns = [(s["start"], s["end"], s["speaker"]) for s in reference["segments"]]
    hyp_turns = [(t["start"], t["end"], t["speaker"]) for t in diar["turns"]]
    return {"wer": track_wer(reference["segments"], transcript["segments"]),
            "der": der(ref_turns, hyp_turns), "der_collar": der(ref_turns, hyp_turns, collar=0.25),
            "speakers": {"ref": len({t[2] for t in ref_turns}), "hyp": len({t[2] for t in hyp_turns})},
            "mic_labels": mic_labels(diar["turns"]), "methods": diar.get("methods", [])}


def run_once(fixture: Path, label: str, settings: dict, index: int, args) -> dict:
    reference = json.loads((fixture / "reference.json").read_text())
    scratch = fixture / "runs" / f"{label}-{index}"
    shutil.rmtree(scratch, ignore_errors=True)
    folder = scratch / "meeting"
    shutil.copytree(fixture / "meeting", folder)
    for i in range(2, args.jobs + 1):
        shutil.copytree(fixture / "meeting", scratch / f"meeting-{i}")
    config = {"notes_dir": str(scratch), "rename_folder": False, **settings}
    (scratch / "config.toml").write_text(toml_text(config))
    if not args.with_summary:
        for f in [folder] + [scratch / f"meeting-{i}" for i in range(2, args.jobs + 1)]:
            (f / ".work").mkdir(exist_ok=True)
            (f / ".work" / "summary.json").write_text(json.dumps(STUB_SUMMARY))

    level = wait_for_normal(args.wait_normal)
    if level not in (0, 1) and not args.allow_warn:
        raise SystemExit(f"memory pressure is {level} (not normal) after {args.wait_normal:.0f} s; use --allow-warn")
    before, models = snapshot(), ollama_models()
    sampler = PressureSampler()
    sampler.start()
    env = {**os.environ, "MEETING_NOTES_CONFIG": str(scratch / "config.toml")}
    proc = subprocess.run(["taskpolicy", "-c", "utility", sys.executable, __file__, "child", str(folder),
                           "--jobs", str(args.jobs)],
                          capture_output=True, text=True, env=env)
    pressure = pressure_summary(sampler.stop())
    after = snapshot()
    if proc.returncode or not proc.stdout.strip():
        (scratch / "bench.stderr.log").write_text(proc.stderr)
        raise SystemExit(f"run failed ({proc.returncode}); see {scratch / 'bench.stderr.log'}")
    result = json.loads(proc.stdout.strip().splitlines()[-1])
    status = json.loads((folder / "status.json").read_text())
    q = quality(folder, reference)
    mic_method = next((m.split("=", 1)[1] for m in q["methods"] if m.startswith("mic=")), "")
    swap = (after["swap_used_mb"] - before["swap_used_mb"]) if None not in (after["swap_used_mb"], before["swap_used_mb"]) else None
    row = {
        "label": label, "fixture": fixture.name, "run": index, "settings": settings,
        "started_at": datetime.now().isoformat(timespec="seconds"), "state": status.get("state"),
        "exit": result["exit"], "wall_sec": result["wall_sec"], "jobs": args.jobs, "job_walls": result.get("job_walls"),
        "job_stages": [{k: round(v, 1) for k, v in (json.loads((f / "status.json").read_text()).get("timings") or {}).items()}
                       for f in [scratch / f"meeting-{i}" for i in range(2, args.jobs + 1)]],
        "stages": {k: round(v, 1) for k, v in (status.get("timings") or {}).items()},
        "audio_min": round(reference["duration_sec"] / 60, 1),
        "peak_rss_gb": result["peak_rss_gb"], "peak_mlx_gb": result["mlx_peak_gb"],
        "swap_before_mb": before["swap_used_mb"], "swap_delta_mb": round(swap, 1) if swap is not None else None,
        "vm_delta_mb": vm_delta_mb(before["vm"], after["vm"]),
        "pressure": pressure, "condition": condition(pressure),
        "ollama_models": models, "on_battery": before["on_battery"],
        "mic_path": "skip" if mic_method == "single-voice" else "full",
        "quality": q,
    }
    with (fixture / "results.jsonl").open("a") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")
    if not args.keep:
        shutil.rmtree(scratch, ignore_errors=True)
    return row


def print_row(row: dict) -> None:
    st, q = row["stages"], row["quality"]
    print(f"{row['label']}#{row['run']} [{row['condition']}] wall {row['wall_sec']}s diarize {st.get('diarize')}s "
          f"transcribe {st.get('transcribe')}s | rss {row['peak_rss_gb']} GB mlx {row['peak_mlx_gb']} GB "
          f"swap {row['swap_delta_mb']} MB | mic {row['mic_path']} {q['mic_labels']} | WER {q['wer']} "
          f"DER {q['der']['der']} (c0.25 {q['der_collar']['der']})", flush=True)


def report(fixture: Path) -> None:
    rows = [json.loads(line) for line in (fixture / "results.jsonl").read_text().splitlines() if line.strip()]
    cols = ["label", "fixture", "runs", "conditions", "wall_sec", "diarize_sec", "transcribe_sec", "peak_rss_gb",
            "swap_delta_mb", "wer_all", "der", "der_c25", "mic_path"]
    print("| " + " | ".join(cols) + " |\n|" + "---|" * len(cols))
    for r in median_report(rows):
        print("| " + " | ".join(str(r[c]) for c in cols) + " |")


def main() -> None:
    ap = argparse.ArgumentParser(usage=__doc__)
    ap.add_argument("cmd", choices=["make", "run", "report", "child"])
    ap.add_argument("dir")
    ap.add_argument("--minutes", type=float, default=12.0)
    ap.add_argument("--remote", type=int, default=2)
    ap.add_argument("--local", type=int, default=1)
    ap.add_argument("--bleed", action="store_true")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--label")
    ap.add_argument("--set", dest="sets", action="append", default=[])
    ap.add_argument("--repeat", type=int, default=1)
    ap.add_argument("--jobs", type=int, default=1, help="queued jobs in one process sharing models (keep_models_warm)")
    ap.add_argument("--with-summary", action="store_true")
    ap.add_argument("--wait-normal", type=float, default=600.0)
    ap.add_argument("--allow-warn", action="store_true")
    ap.add_argument("--keep", action="store_true", help="keep the processed copy (audio) under <dir>/runs")
    args = ap.parse_args()
    path = Path(args.dir).expanduser()
    ensure_outside_user_notes(path)
    if args.cmd == "child":
        child(str(path), args.jobs)
    elif args.cmd == "make":
        from meeting_fixture import make_fixture

        print(make_fixture(path, args.minutes, args.remote, args.local, args.bleed, args.seed))
    elif args.cmd == "report":
        report(path)
    else:
        settings = parse_sets(args.sets)
        label = args.label or ("default" if not settings else ",".join(f"{k}={v}" for k, v in settings.items()))
        for i in range(args.repeat):
            print_row(run_once(path, label, settings, i, args))


if __name__ == "__main__":
    main()
