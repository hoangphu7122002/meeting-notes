"""On-device transcription with mlx-whisper (Transcriber port); mlx is imported lazily on first use.

Encoder reuse: `mlx_whisper.transcribe` encodes every 30 s window again for each temperature fallback, and a
separate language detection would encode the same audio once more. `_EncodeOnce` sits in front of the model
for one call: each window is encoded once, and the first window can come pre-encoded from `transcribe_auto`,
which detects the language on those same features. Decoding is mlx-whisper's own code on identical features,
so the text is the same as a plain `transcribe` with that language.
"""

from __future__ import annotations

from collections.abc import Callable

import numpy as np

from ...application.transcribe_blocks import whisper_prompt
from ...config import Config


class _EncodeOnce:
    """Whisper model proxy for one transcribe call: encodes each distinct window once (temperature fallbacks
    reuse it) and serves `first` = (mel window, features) for the first window without encoding."""

    def __init__(self, model, first=None):
        self._model = model
        self._first = first
        self._last = (None, None)
        self.encodes = 0

    def __getattr__(self, name):
        return getattr(self._model, name)

    def decode(self, mel, options):
        import mlx.core as mx

        if mel is not self._last[0]:
            features = None
            if self._first is not None:
                first_mel, first_features = self._first
                self._first = None
                if first_mel.shape == mel.shape and mx.array_equal(first_mel, mel).item():
                    features = first_features
            if features is None:
                features = self._model.encoder(mel[None])[0]
                self.encodes += 1
            self._last = (mel, features)
        return self._model.decode(self._last[1], options)


class Transcriber:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        self._model = None
        self.encodes = 0  # encoder passes so far (benches and tests)

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

    def _current(self):
        """The model mlx_whisper.transcribe will use (benches may swap ModelHolder.model per call)."""
        import mlx.core as mx
        from mlx_whisper.transcribe import ModelHolder

        self._load()
        return ModelHolder.get_model(self.cfg.whisper_model, mx.float16)

    def detect_language(self, audio: np.ndarray) -> dict[str, float]:
        import mlx.core as mx
        from mlx_whisper.audio import N_FRAMES, N_SAMPLES, log_mel_spectrogram, pad_or_trim

        model = self._load()
        mel = log_mel_spectrogram(audio, n_mels=model.dims.n_mels, padding=N_SAMPLES)
        segment = pad_or_trim(mel, N_FRAMES, axis=-2).astype(mx.float16)
        self.encodes += 1
        _, probs = model.detect_language(segment)
        return dict(probs)

    def transcribe(self, audio: np.ndarray, language: str) -> list[dict]:
        return self._transcribe(audio, language, _EncodeOnce(self._current()))

    def transcribe_auto(self, audio: np.ndarray, choose: Callable[[dict[str, float]], str]) -> tuple[str, list[dict]]:
        """One encoder pass for detection + first decode window: encode the window `transcribe` decodes first,
        detect the language on those features, let `choose` pick, then decode reusing them."""
        import mlx.core as mx
        from mlx_whisper.audio import N_FRAMES, N_SAMPLES, log_mel_spectrogram, pad_or_trim

        model = self._current()
        # Same first window as mlx_whisper.transcribe: content frames, zero-padded in mel space to 30 s.
        mel = log_mel_spectrogram(audio, n_mels=model.dims.n_mels, padding=N_SAMPLES)
        size = min(N_FRAMES, mel.shape[-2] - N_FRAMES)
        first = pad_or_trim(mel[:size], N_FRAMES, axis=-2).astype(mx.float16)
        features = model.encoder(first[None])[0]
        self.encodes += 1
        _, probs = model.detect_language(features)
        language = choose(dict(probs))
        return language, self._transcribe(audio, language, _EncodeOnce(model, (first, features)))

    def _transcribe(self, audio: np.ndarray, language: str, proxy: _EncodeOnce) -> list[dict]:
        import mlx_whisper
        from mlx_whisper.transcribe import ModelHolder

        temperature = (0.0, 0.2, 0.4, 0.6, 0.8, 1.0) if self.cfg.whisper_temperature_fallback else 0.0
        saved = ModelHolder.model
        ModelHolder.model = proxy  # get_model hands the proxy to this call (same model path)
        try:
            result = mlx_whisper.transcribe(
                audio,
                path_or_hf_repo=self.cfg.whisper_model,
                language=language,
                temperature=temperature,
                condition_on_previous_text=self.cfg.whisper_condition_on_previous_text,
                initial_prompt=whisper_prompt(self.cfg, language),
                verbose=None,
            )
        finally:
            ModelHolder.model = saved
            self.encodes += proxy.encodes
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
