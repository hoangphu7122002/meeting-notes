"""Dependency factories: the only place where use cases and inbound adapters meet the outbound adapters.

Every factory imports its adapters when called, so importing this module (and the CLI) stays cheap and
numpy/soundfile/torch/mlx are loaded only by the commands that need them.
"""

from __future__ import annotations

from collections.abc import Callable
from pathlib import Path
from typing import TYPE_CHECKING

from ..adapters.inbound.commands import CommandDeps
from ..adapters.inbound.worker import Worker
from ..config import Config

if TYPE_CHECKING:
    from ..application.ports import ManagedModels, ProgressReporter
    from ..application.process_meeting import Processor
    from ..application.processor_deps import ProcessorDeps


def make_reporter(**kwargs) -> ProgressReporter:
    from ..adapters.outbound.progress_reporter import Reporter

    return Reporter(**kwargs)


def make_models(cfg: Config, keep: bool = False, log: Callable[[str], None] = print) -> ManagedModels:
    from ..adapters.outbound.model_cache import Models

    return Models(cfg, keep=keep, log=log)


def make_llm(cfg: Config):
    from ..adapters.outbound.ollama_client import Ollama

    return Ollama(cfg)


def summarize(lines: list[str], language: str, cfg: Config, progress=None, template: str | None = None) -> dict:
    from ..application.summarize_meeting import summarize as summarize_meeting

    return summarize_meeting(lines, language, cfg, progress, template=template, llm=make_llm(cfg))


def preload_llm(cfg: Config):
    from ..adapters.outbound.ollama_client import preload

    return preload(cfg)


def processor_deps() -> ProcessorDeps:
    from ..adapters.outbound.audio_files import AudioFiles
    from ..adapters.outbound.meeting_folder import MeetingStore
    from ..application.processor_deps import ProcessorDeps

    return ProcessorDeps(store=MeetingStore(), audio=AudioFiles(), make_models=make_models,
                         summarize=summarize, preload=preload_llm)


def make_processor(folder: Path, cfg: Config, reporter: ProgressReporter, models: ManagedModels | None = None) -> Processor:
    from ..application.process_meeting import Processor

    return Processor(folder, cfg, reporter, processor_deps(), models)


def make_worker() -> Worker:
    return Worker(make_models=make_models, make_reporter=make_reporter, make_processor=make_processor)


def import_audio(src: Path, notes_dir: Path, title: str | None = None) -> Path:
    from ..adapters.outbound.meeting_folder import MeetingStore
    from ..application.import_audio import import_audio as import_meeting_audio

    return import_meeting_audio(src, notes_dir, title, store=MeetingStore())


def warm_diarizer(cfg: Config) -> None:
    from ..adapters.outbound.pyannote_diarizer import Diarizer

    Diarizer(cfg).pipeline()


def check_hf_access(models: list[str]) -> dict[str, str]:
    from ..adapters.outbound.hf_hub import check_hf_access as check

    return check(models)


def cached_status(repo: str) -> bool | None:
    from ..adapters.outbound.hf_hub import cached_status as status

    return status(repo)


def download_model(repo: str) -> None:
    from ..adapters.outbound.hf_hub import download_model as download

    download(repo)


def find_ffmpeg() -> str:
    from ..adapters.outbound.ffmpeg_audio import find_ffmpeg as find

    return find()


def read_app_state():
    from ..adapters.outbound.app_control import read_app_state as read

    return read()


def send_app_command(action: str) -> int:
    from ..adapters.outbound.app_control import send_app_command as send

    return send(action)


def command_deps() -> CommandDeps:
    return CommandDeps(
        make_reporter=make_reporter, make_processor=make_processor, import_audio=import_audio, make_llm=make_llm,
        make_worker=make_worker, check_hf_access=check_hf_access, cached_status=cached_status,
        download_model=download_model, warm_diarizer=warm_diarizer, find_ffmpeg=find_ffmpeg,
        read_app_state=read_app_state, send_app_command=send_app_command,
    )
