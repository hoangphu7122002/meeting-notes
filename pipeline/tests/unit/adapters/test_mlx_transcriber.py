from meeting_notes.adapters.outbound.mlx_transcriber import Transcriber
from meeting_notes.config import Config


def test_transcriber_caps_mlx_cache(monkeypatch):
    import sys
    import types

    calls = []
    mx = types.SimpleNamespace(float16="f16", set_cache_limit=calls.append)
    holder = types.SimpleNamespace(get_model=lambda name, dtype: "model")
    mlx = types.ModuleType("mlx")
    mlx.core = mx
    monkeypatch.setitem(sys.modules, "mlx", mlx)
    monkeypatch.setitem(sys.modules, "mlx.core", mx)
    monkeypatch.setitem(sys.modules, "mlx_whisper.transcribe", types.SimpleNamespace(ModelHolder=holder))
    monkeypatch.setitem(sys.modules, "mlx_whisper", types.ModuleType("mlx_whisper"))

    assert Transcriber(Config())._load() == "model"
    assert calls == [256 * 2**20]
    calls.clear()
    Transcriber(Config(mlx_cache_limit_mb=-1))._load()
    assert calls == []
