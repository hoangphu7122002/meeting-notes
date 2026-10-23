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


class FakeWhisper:
    """Records encoder passes and which features each decode got."""

    dims = "dims"

    def __init__(self):
        self.encoded, self.decoded = [], []

    def encoder(self, batch):
        self.encoded.append(batch[0].copy())
        return batch * 10

    def decode(self, features, options):
        self.decoded.append((features.copy(), options))
        return options


def fake_mx(monkeypatch):
    import sys
    import types

    import numpy as np

    mx = types.SimpleNamespace(array_equal=lambda a, b: np.bool_(np.array_equal(a, b)))
    mlx = types.ModuleType("mlx")
    mlx.core = mx
    monkeypatch.setitem(sys.modules, "mlx", mlx)
    monkeypatch.setitem(sys.modules, "mlx.core", mx)


def test_encode_once_reuses_features_across_fallbacks_and_first_window(monkeypatch):
    import numpy as np

    from meeting_notes.adapters.outbound.mlx_transcriber import _EncodeOnce

    fake_mx(monkeypatch)
    model = FakeWhisper()
    w1, w2 = np.ones((4, 2)), np.full((4, 2), 2.0)
    proxy = _EncodeOnce(model, first=(w1.copy(), w1 * 10))
    assert proxy.dims == "dims"  # attributes fall through to the model
    for t in (0.0, 0.2, 0.4):  # temperature fallback: same window object, decoded three times
        proxy.decode(w1, t)
    proxy.decode(w2, 0.0)
    proxy.decode(w2, 0.2)
    assert proxy.encodes == 1 and len(model.encoded) == 1  # only w2 hit the encoder
    assert np.array_equal(model.encoded[0], w2)
    assert [o for _, o in model.decoded] == [0.0, 0.2, 0.4, 0.0, 0.2]
    assert all(np.array_equal(f, w1 * 10) for f, _ in model.decoded[:3])
    assert all(np.array_equal(f, w2 * 10) for f, _ in model.decoded[3:])


def test_encode_once_ignores_precomputed_features_for_another_window(monkeypatch):
    import numpy as np

    from meeting_notes.adapters.outbound.mlx_transcriber import _EncodeOnce

    fake_mx(monkeypatch)
    model = FakeWhisper()
    proxy = _EncodeOnce(model, first=(np.zeros((4, 2)), np.full((4, 2), -1.0)))
    proxy.decode(np.ones((4, 2)), 0.0)
    assert proxy.encodes == 1 and np.array_equal(model.decoded[0][0], np.full((4, 2), 10.0))
