"""CLI command handlers (process, import, doctor, setup, worker, ctl). Everything they touch comes in via CommandDeps."""

from __future__ import annotations

import json
import os
import sys
import threading
import traceback
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING

from ...application.errors import Cancelled, OllamaError
from ...config import CONFIG_PATH, REPO_ROOT, Config, hf_token, redact, shared_install
from ...domain.glossary import glossary_entries
from ...domain.notes_schema import template_name

if TYPE_CHECKING:
    from ...application.ports import LlmClient, MeetingProcessor, ProgressReporter, WorkerServer

CTL_COMMANDS = ["start", "stop", "pause", "resume", "toggle", "show", "status"]


@dataclass
class CommandDeps:
    """Outbound capabilities for the commands; entrypoints/wiring.py builds the real set."""

    make_reporter: Callable[..., ProgressReporter]  # (json_mode=...)
    make_processor: Callable[[Path, Config, ProgressReporter], MeetingProcessor]
    import_audio: Callable[[Path, Path, str | None], Path]  # (audio, notes_dir, title) -> meeting folder
    make_llm: Callable[[Config], LlmClient]
    make_worker: Callable[[], WorkerServer]
    check_hf_access: Callable[[list[str]], dict[str, str]]
    cached_status: Callable[[str], bool | None]
    download_model: Callable[[str], None]
    warm_diarizer: Callable[[Config], None]
    find_ffmpeg: Callable[[], str]
    read_app_state: Callable[[], object]  # raises OSError/ValueError when unavailable
    send_app_command: Callable[[str], int]
    make_live: Callable[..., object] | None = None  # (folder, cfg, reporter, models=None, simulate=None) -> run(stop)
    prepare_fluidaudio: Callable[[Config, Callable[[str], None]], object] | None = None  # (cfg, log) -> helper path
    fluidaudio_status: Callable[[Config], str] | None = None


def uses_fluidaudio(cfg: Config) -> bool:
    """FluidAudio is the default engine (also for unknown values); "pyannote" and "sherpa-onnx" opt out."""
    return str(cfg.diarization_engine).strip().lower() not in ("pyannote", "sherpa-onnx", "sherpa")


def _report_failure() -> None:
    """Exit-code-only failures still leave the traceback on stderr (secrets redacted)."""
    print(redact(traceback.format_exc()), file=sys.stderr)


def cmd_process(args, cfg: Config, deps: CommandDeps) -> int:
    folder = Path(args.folder).expanduser()
    if not folder.is_dir():
        print(f"Not a folder: {folder}", file=sys.stderr)
        return 2
    reporter = deps.make_reporter(json_mode=args.json)
    try:
        deps.make_processor(folder, cfg, reporter).run("prepare" if args.force else args.from_stage)
    except Cancelled:
        return 3
    except Exception:
        _report_failure()
        return 1
    return 0


def cmd_live(args, cfg: Config, deps: CommandDeps) -> int:
    """Live transcription of a meeting folder: tails the WAVs being recorded (Ctrl-C stops), or with
    --simulate replays a finished recording at that speed. Writes only .work/transcript.partial.jsonl."""
    folder = Path(args.folder).expanduser()
    if not folder.is_dir() or deps.make_live is None:
        print(f"Not a folder: {folder}", file=sys.stderr)
        return 2
    stop = threading.Event()
    reporter = deps.make_reporter(json_mode=args.json)
    try:
        stats = deps.make_live(folder, cfg, reporter, simulate=args.simulate).run(stop)
    except KeyboardInterrupt:
        stop.set()
        return 0
    except Exception:
        _report_failure()
        return 1
    print(json.dumps({"live": stats}), file=sys.stderr)
    return 0


def cmd_worker(args, cfg: Config, deps: CommandDeps) -> int:
    return deps.make_worker().serve()


def cmd_ctl(args, cfg: Config, deps: CommandDeps) -> int:
    """Control the running app without the menu bar (URL scheme meetingnotes://<command>)."""
    if args.action == "status":
        try:
            state = deps.read_app_state()
        except (OSError, ValueError):
            print("MeetingNotes app state unknown (app not running?)")
            return 1
        print(json.dumps(state, ensure_ascii=False, indent=2))
        return 0
    return deps.send_app_command(args.action)


def cmd_import(args, cfg: Config, deps: CommandDeps) -> int:
    folder = deps.import_audio(Path(args.audio).expanduser(), Path(args.notes_dir).expanduser() if args.notes_dir else cfg.notes_path, args.title)
    print(f"Created {folder}", file=sys.stderr)
    if args.no_process:
        print(folder)
        return 0
    try:
        deps.make_processor(folder, cfg, deps.make_reporter(json_mode=args.json)).run()
    except Exception:
        _report_failure()
        return 1
    return 0


def cmd_doctor(args, cfg: Config, deps: CommandDeps) -> int:
    report: dict[str, object] = {"config_file": str(CONFIG_PATH) + ("" if CONFIG_PATH.exists() else " (not present, using defaults)")}
    report["notes_dir"] = str(cfg.notes_path)
    report["install"] = install_mode()
    report["ffmpeg"] = deps.find_ffmpeg()
    report["diarization_engine"] = cfg.diarization_engine
    if uses_fluidaudio(cfg) and deps.fluidaudio_status:
        report["fluidaudio"] = deps.fluidaudio_status(cfg)
    missing = "optional: only the pyannote fallback uses it" if uses_fluidaudio(cfg) else "diarization falls back to clustering"
    report["hf_token"] = "present" if hf_token() else f"missing ({missing})"
    cached = deps.cached_status(cfg.whisper_model)
    if cached is None:
        report["whisper_model"] = cfg.whisper_model
    else:
        report["whisper_model"] = f"{cfg.whisper_model} ({'cached' if cached else 'will download on first use'})"
    report["glossary"] = f"{len(glossary_entries(cfg.glossary))} term(s)"
    report["summary_template"] = template_name(cfg.summary_template)
    report["asr"] = (f"vad={'on' if cfg.whisper_vad else 'off'}, temperature fallback="
                     f"{'on' if cfg.whisper_temperature_fallback else 'off'}, chunk {cfg.whisper_max_chunk_sec:g}s")
    if hf_token() and not args.offline:
        report["diarization_access"] = deps.check_hf_access(cfg.diarization_models)
    client = deps.make_llm(cfg)
    try:
        names = client.list_models()
        has = cfg.ollama_model in names or f"{cfg.ollama_model}:latest" in names
        report["ollama"] = f"running; model {cfg.ollama_model} {'present' if has else 'MISSING (meeting-notes setup)'}"
    except OllamaError as exc:
        report["ollama"] = str(exc)
    for key, value in report.items():
        if isinstance(value, dict):
            print(f"{key}:")
            for k, v in value.items():
                print(f"  {k}: {v}")
        else:
            print(f"{key}: {value}")
    return 0


def install_mode() -> str:
    """`doctor` line: dev/per-user install, the packaged app's runtime, or the shared install's root and how this
    account uses its models."""
    marker = shared_install(REPO_ROOT)
    if marker is None:
        return f"per-user ({REPO_ROOT})"
    hub = os.environ.get("HF_HUB_CACHE") or os.environ.get("HF_HOME") or "default"
    if marker.get("mode") == "packaged":
        return f"packaged app runtime ({REPO_ROOT}); models {hub}"
    mode = "read-only, offline" if os.environ.get("HF_HUB_OFFLINE") == "1" else "writable"
    return f"shared ({REPO_ROOT}); models {hub} ({mode})"


SETUP_STEPS = ("speech", "diarization", "summary")


class SetupOutput:
    """Setup progress: human lines on stderr, or with --json one `{"event":"setup","step","status",...}` line per
    update on stdout (status start|progress|done|error; optional message, fraction 0-1). The app's first-run
    wizard reads the JSON form."""

    def __init__(self, json_mode: bool):
        self.json_mode = json_mode

    def __call__(self, step: str, status: str, message: str = "", fraction: float | None = None) -> None:
        if self.json_mode:
            event: dict[str, object] = {"event": "setup", "step": step, "status": status}
            if message:
                event["message"] = redact(message)[:300]
            if fraction is not None:
                event["fraction"] = round(min(max(fraction, 0.0), 1.0), 4)
            print(json.dumps(event, ensure_ascii=False), flush=True)
        elif status == "progress" and fraction is not None:
            print(f"\r{message} {fraction * 100:5.1f}%", end="", file=sys.stderr)
        elif status != "error" and message:
            print(message, file=sys.stderr)


def cmd_setup(args, cfg: Config, deps: CommandDeps) -> int:
    """Download all models ahead of the first meeting; `--only` runs some steps (speech = whisper + embeddings,
    diarization = FluidAudio, summary = Ollama model), `--json` prints machine-readable progress."""
    only = str(getattr(args, "only", None) or "")
    steps = [s.strip() for s in only.split(",") if s.strip()] or list(SETUP_STEPS)
    unknown = [s for s in steps if s not in SETUP_STEPS]
    if unknown:
        print(f"unknown setup step(s): {', '.join(unknown)} (choose from {', '.join(SETUP_STEPS)})", file=sys.stderr)
        return 2
    out = SetupOutput(bool(getattr(args, "json", False)))
    for step in steps:
        out(step, "start")
        try:
            SETUP_RUNNERS[step](cfg, deps, out)
        except Exception as exc:
            if not out.json_mode:
                raise
            out(step, "error", " ".join(f"{type(exc).__name__}: {exc}".split()))
            return 1
        out(step, "done")
    if not out.json_mode:
        print("\nSetup complete.", file=sys.stderr)
    return 0


def _setup_speech(cfg: Config, deps: CommandDeps, out: SetupOutput) -> None:
    for repo in (cfg.whisper_model, cfg.embedding_model):
        out("speech", "progress", f"Downloading {repo} ...")
        deps.download_model(repo)


def _setup_diarization(cfg: Config, deps: CommandDeps, out: SetupOutput) -> None:
    if uses_fluidaudio(cfg) and deps.prepare_fluidaudio:
        out("diarization", "progress", "Preparing FluidAudio diarization models (~21 MB, no login) ...")
        try:
            path = deps.prepare_fluidaudio(cfg, lambda m: out("diarization", "progress", m))
            out("diarization", "progress", f"FluidAudio ready: {path}")
        except Exception as exc:  # full setup goes on: diarization then falls back to pyannote / clustering
            if out.json_mode:
                raise
            print(f"FluidAudio not ready ({redact(str(exc))[:200]}); diarization will fall back to pyannote", file=sys.stderr)
    access = deps.check_hf_access(cfg.diarization_models) if hf_token() else {}
    for model, state in access.items():
        out("diarization", "progress", f"{model}: {state}")
        if state == "ok":
            deps.warm_diarizer(cfg)
            break


def _setup_summary(cfg: Config, deps: CommandDeps, out: SetupOutput) -> None:
    out("summary", "progress", f"Ensuring Ollama model {cfg.ollama_model} ...")
    deps.make_llm(cfg).ensure_model(lambda f, msg: out("summary", "progress", msg, f))


SETUP_RUNNERS: dict[str, Callable[[Config, CommandDeps, SetupOutput], None]] = {
    "speech": _setup_speech, "diarization": _setup_diarization, "summary": _setup_summary,
}
