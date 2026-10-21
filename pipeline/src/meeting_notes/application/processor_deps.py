"""What a Processor needs from the outside world, bundled so entrypoints and tests can swap any part."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from ..config import Config
from .ports import AudioIO, MeetingStore, ModelProvider, PartialTranscriptStore, Summarizer
from .transcribe_blocks import transcribe_blocks


@dataclass
class ProcessorDeps:
    """Everything a Processor needs from the outside; entrypoints/wiring.py builds the real set."""

    store: MeetingStore
    audio: AudioIO
    make_models: Callable[[Config, bool, Callable[[str], None]], ModelProvider]  # (cfg, keep, log)
    summarize: Summarizer
    preload: Callable[[Config], object]  # start loading the summary model in the background
    transcribe_blocks: Callable[..., list] = transcribe_blocks
    partials: Callable[[Path], PartialTranscriptStore] | None = None  # live partials file -> store; None = no reuse
