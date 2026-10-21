"""On-device transcription with mlx-whisper (Transcriber port); mlx is imported lazily on first use."""

from __future__ import annotations

import numpy as np

from ...application.transcribe_blocks import whisper_prompt
from ...config import Config


class Transcriber:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        self._model = None

    def _load(self):
        if self._model is None:
            import mlx.core as mx
            from mlx_whisper.transcribe import ModelHolder

            if self.cfg.mlx_cache_limit_mb >= 0:
                # MLX keeps freed Metal buffers in a cache that grows with every new block shape
                # (~2.5 GB extra on a 1 h meeting); capping it keeps the footprint near the model size.
                mx.set_cache_limit(int(self.cfg.mlx_cache_limit_mb) * 2**20)
            self._model = ModelHolder.get_model(self.cfg.whisper_model, mx.float16)
        return self._model

    def detect_language(self, audio: np.ndarray) -> dict[str, float]:
        import mlx.core as mx
        from mlx_whisper.audio import N_FRAMES, N_SAMPLES, log_mel_spectrogram, pad_or_trim

        model = self._load()
        mel = log_mel_spectrogram(audio, n_mels=model.dims.n_mels, padding=N_SAMPLES)
        segment = pad_or_trim(mel, N_FRAMES, axis=-2).astype(mx.float16)
        _, probs = model.detect_language(segment)
        return dict(probs)

    def transcribe(self, audio: np.ndarray, language: str) -> list[dict]:
        import mlx_whisper

        temperature = (0.0, 0.2, 0.4, 0.6, 0.8, 1.0) if self.cfg.whisper_temperature_fallback else 0.0
        result = mlx_whisper.transcribe(
            audio,
            path_or_hf_repo=self.cfg.whisper_model,
            language=language,
            temperature=temperature,
            condition_on_previous_text=self.cfg.whisper_condition_on_previous_text,
            initial_prompt=whisper_prompt(self.cfg, language),
            verbose=None,
        )
        return result.get("segments", [])

    def release(self) -> None:
        try:
            import gc

            import mlx.core as mx
            from mlx_whisper.transcribe import ModelHolder

            ModelHolder.model = None
            ModelHolder.model_path = None
            self._model = None
            gc.collect()
            mx.clear_cache()
        except Exception:
            pass
