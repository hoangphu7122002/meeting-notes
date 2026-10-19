"""Command line: meeting-notes process|import|doctor|setup."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from pathlib import Path

os.environ.setdefault("PYANNOTE_METRICS_ENABLED", "false")
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

from .config import CONFIG_PATH, Config, hf_token  # noqa: E402
from .events import STAGES, Reporter  # noqa: E402


def cmd_process(args, cfg: Config) -> int:
    from .events import Cancelled
    from .pipeline import Processor

    folder = Path(args.folder).expanduser()
    if not folder.is_dir():
        print(f"Not a folder: {folder}", file=sys.stderr)
        return 2
    reporter = Reporter(json_mode=args.json)
    try:
        Processor(folder, cfg, reporter).run("prepare" if args.force else args.from_stage)
    except Cancelled:
        return 3
    except Exception:
        return 1
    return 0


def cmd_worker(args, cfg: Config) -> int:
    from .worker import Worker

    return Worker().serve()


APP_STATE = Path("~/Library/Application Support/MeetingNotes/state.json").expanduser()
CTL_COMMANDS = ["start", "stop", "pause", "resume", "toggle", "show", "status"]


def cmd_ctl(args, cfg: Config) -> int:
    """Control the running app without the menu bar (URL scheme meetingnotes://<command>)."""
    import subprocess

    if args.action == "status":
        try:
            state = json.loads(APP_STATE.read_text())
        except (OSError, ValueError):
            print("MeetingNotes app state unknown (app not running?)")
            return 1
        print(json.dumps(state, ensure_ascii=False, indent=2))
        return 0
    flags = [] if args.action in ("show", "start") else ["-g"]
    return subprocess.run(["open", *flags, f"meetingnotes://{args.action}"], check=False).returncode


def cmd_import(args, cfg: Config) -> int:
    from .pipeline import Processor, import_audio

    folder = import_audio(Path(args.audio).expanduser(), Path(args.notes_dir).expanduser() if args.notes_dir else cfg.notes_path, args.title)
    print(f"Created {folder}", file=sys.stderr)
    if args.no_process:
        print(folder)
        return 0
    try:
        Processor(folder, cfg, Reporter(json_mode=args.json)).run()
    except Exception:
        return 1
    return 0


def check_hf_access(models: list[str]) -> dict[str, str]:
    from huggingface_hub import auth_check
    from huggingface_hub.utils import GatedRepoError, HfHubHTTPError

    token = hf_token()
    out = {}
    for model in models:
        try:
            auth_check(model, token=token)
            out[model] = "ok"
        except GatedRepoError:
            out[model] = f"gated: accept the terms at https://huggingface.co/{model}"
        except HfHubHTTPError as exc:
            out[model] = f"error: HTTP {getattr(exc.response, 'status_code', '?')}"
        except Exception as exc:
            out[model] = f"error: {type(exc).__name__}"
    return out


def cmd_doctor(args, cfg: Config) -> int:
    from .summarize import Ollama, OllamaError

    report: dict[str, object] = {"config_file": str(CONFIG_PATH) + ("" if CONFIG_PATH.exists() else " (not present, using defaults)")}
    report["notes_dir"] = str(cfg.notes_path)
    report["ffmpeg"] = shutil.which("ffmpeg") or ("/opt/homebrew/bin/ffmpeg" if Path("/opt/homebrew/bin/ffmpeg").exists() else "MISSING")
    report["hf_token"] = "present" if hf_token() else "missing (diarization falls back to clustering)"
    try:
        from huggingface_hub import try_to_load_from_cache

        cached = try_to_load_from_cache(cfg.whisper_model, "config.json")
        report["whisper_model"] = f"{cfg.whisper_model} ({'cached' if isinstance(cached, str) else 'will download on first use'})"
    except Exception:
        report["whisper_model"] = cfg.whisper_model
    if hf_token() and not args.offline:
        report["diarization_access"] = check_hf_access(cfg.diarization_models)
    client = Ollama(cfg)
    try:
        with client._request("/api/tags") as resp:
            names = {m["name"] for m in json.load(resp).get("models", [])}
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


def cmd_setup(args, cfg: Config) -> int:
    """Download all models ahead of the first meeting."""
    from huggingface_hub import snapshot_download

    from .summarize import Ollama

    for repo in (cfg.whisper_model, cfg.embedding_model):
        print(f"Downloading {repo} ...", file=sys.stderr)
        snapshot_download(repo, token=hf_token())
    access = check_hf_access(cfg.diarization_models) if hf_token() else {}
    for model, state in access.items():
        print(f"{model}: {state}", file=sys.stderr)
        if state == "ok":
            from .diarize import Diarizer

            Diarizer(cfg).pipeline()
            break
    print(f"Ensuring Ollama model {cfg.ollama_model} ...", file=sys.stderr)
    Ollama(cfg).ensure_model(lambda f, msg: print(f"\r{msg} {f * 100:5.1f}%", end="", file=sys.stderr))
    print("\nSetup complete.", file=sys.stderr)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="meeting-notes", description="Local meeting transcription, diarization and summary.")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("process", help="process (or resume) a meeting folder")
    p.add_argument("folder")
    p.add_argument("--json", action="store_true", help="JSON progress lines on stdout (used by the app)")
    p.add_argument("--from", dest="from_stage", choices=STAGES, help="re-run this stage and everything after it")
    p.add_argument("--force", action="store_true", help="re-run every stage")
    p.set_defaults(func=cmd_process)

    p = sub.add_parser("import", help="create a meeting folder from an audio/video file and process it")
    p.add_argument("audio")
    p.add_argument("--title")
    p.add_argument("--notes-dir")
    p.add_argument("--json", action="store_true")
    p.add_argument("--no-process", action="store_true")
    p.set_defaults(func=cmd_import)

    p = sub.add_parser("doctor", help="check dependencies, models and access")
    p.add_argument("--offline", action="store_true", help="skip Hugging Face access checks")
    p.set_defaults(func=cmd_doctor)

    p = sub.add_parser("setup", help="download whisper, embedding and Ollama models")
    p.set_defaults(func=cmd_setup)

    p = sub.add_parser("worker", help="long-lived worker for the app (JSON commands on stdin)")
    p.set_defaults(func=cmd_worker)

    p = sub.add_parser("ctl", help="control the MeetingNotes app: " + "|".join(CTL_COMMANDS))
    p.add_argument("action", choices=CTL_COMMANDS)
    p.set_defaults(func=cmd_ctl)

    args = parser.parse_args(argv)
    cfg = Config.load()
    if args.command in ("process", "import", "worker"):
        from .resources import apply_priority, limit_threads

        limit_threads(cfg.cpu_threads)
        apply_priority(os.environ.get("MEETING_NOTES_PRIORITY") or cfg.priority)
    return args.func(args, cfg)


if __name__ == "__main__":
    sys.exit(main())
