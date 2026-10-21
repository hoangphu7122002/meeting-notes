"""Errors raised by use cases and the adapters behind their ports."""

from __future__ import annotations


class PipelineError(RuntimeError):
    """A meeting folder cannot be processed (no audio, already being processed)."""


class Cancelled(Exception):
    """Processing was cancelled; every progress report is a cancellation point."""


class OllamaError(RuntimeError):
    """The local summary model is unreachable or returned an unusable answer."""
