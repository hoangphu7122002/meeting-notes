"""Command line: meeting-notes process|live|import|doctor|setup|worker|ctl. Parses arguments and dispatches."""

from __future__ import annotations

import argparse
import os
import sys

os.environ.setdefault("PYANNOTE_METRICS_ENABLED", "false")
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

from ..config import REPO_ROOT, apply_shared_env  # noqa: E402

apply_shared_env(REPO_ROOT)  # shared install: HF cache = shared model store (offline if not writable); before any HF import

from ..adapters.inbound.commands import (  # noqa: E402
    CTL_COMMANDS, cmd_ctl, cmd_doctor, cmd_import, cmd_live, cmd_process, cmd_setup, cmd_worker,
)
from ..config import Config  # noqa: E402
from ..domain.stages import STAGES  # noqa: E402


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="meeting-notes", description="Local meeting transcription, diarization and summary.")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("process", help="process (or resume) a meeting folder")
    p.add_argument("folder")
    p.add_argument("--json", action="store_true", help="JSON progress lines on stdout (used by the app)")
    p.add_argument("--from", dest="from_stage", choices=STAGES, help="re-run this stage and everything after it")
    p.add_argument("--force", action="store_true", help="re-run every stage")
    p.set_defaults(func=cmd_process)

    p = sub.add_parser("live", help="live transcription of a meeting being recorded (or --simulate a finished one)")
    p.add_argument("folder")
    p.add_argument("--simulate", type=float, metavar="SPEED", help="replay a finished recording at SPEED x real time")
    p.add_argument("--json", action="store_true", help="JSON event lines on stdout")
    p.set_defaults(func=cmd_live)

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

    p = sub.add_parser("setup", help="download whisper, embedding, FluidAudio and Ollama models")
    p.add_argument("--only", metavar="STEPS", help="comma list of speech,diarization,summary (default: all)")
    p.add_argument("--json", action="store_true", help="JSON progress lines on stdout (used by the app's setup)")
    p.set_defaults(func=cmd_setup)

    p = sub.add_parser("worker", help="long-lived worker for the app (JSON commands on stdin)")
    p.set_defaults(func=cmd_worker)

    p = sub.add_parser("ctl", help="control the MeetingNotes app: " + "|".join(CTL_COMMANDS))
    p.add_argument("action", choices=CTL_COMMANDS)
    p.set_defaults(func=cmd_ctl)

    args = parser.parse_args(argv)
    cfg = Config.load()
    if args.command in ("process", "import", "worker", "live"):
        from ..adapters.outbound.system_resources import apply_priority, limit_threads

        limit_threads(cfg.cpu_threads)
        apply_priority(os.environ.get("MEETING_NOTES_PRIORITY") or cfg.priority)
    from . import wiring

    return args.func(args, cfg, wiring.command_deps())


if __name__ == "__main__":
    sys.exit(main())
