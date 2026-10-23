from meeting_notes.adapters.outbound.model_cache import Models
from meeting_notes.config import Config


class Fake:
    def __init__(self, cfg, log=None):
        self.released = self.trimmed = 0

    def release(self):
        self.released += 1

    def trim(self):
        self.trimmed += 1


def models(monkeypatch, keep, level):
    import meeting_notes.adapters.outbound.mlx_transcriber as T
    import meeting_notes.adapters.outbound.pyannote_diarizer as D

    monkeypatch.setattr(D, "Diarizer", Fake)
    monkeypatch.setattr(T, "Transcriber", lambda cfg: Fake(cfg))
    return Models(Config(), keep=keep, log=lambda m: None, pressure=lambda: level["now"])


def test_auto_keeps_and_trims_under_normal_pressure(monkeypatch):
    level = {"now": 1}
    m = models(monkeypatch, "auto", level)
    d = m.diarizer()
    m.done_with_diarizer()
    assert m.loaded and d.trimmed == 1 and d.released == 0
    t = m.transcriber()  # normal: both may stay
    m.done_with_transcriber()
    assert m._diarizer is d and m._transcriber is t and t.trimmed == 1


def test_auto_releases_after_stage_under_warn(monkeypatch):
    m = models(monkeypatch, "auto", {"now": 2})
    d = m.diarizer()
    m.done_with_diarizer()
    assert not m.loaded and d.released == 1


def test_loading_the_other_model_drops_the_idle_one_under_pressure(monkeypatch):
    level = {"now": 1}
    m = models(monkeypatch, "auto", level)
    t = m.transcriber()
    m.done_with_transcriber()
    level["now"] = 2
    m.diarizer()
    assert t.released == 1 and m._transcriber is None  # at most one heavy model under "warn"


def test_release_if_pressure(monkeypatch):
    level = {"now": 1}
    m = models(monkeypatch, "auto", level)
    m.transcriber()
    assert not m.release_if_pressure() and m.loaded
    level["now"] = 4
    assert m.release_if_pressure() and not m.loaded
    assert not m.release_if_pressure()  # nothing loaded


def test_probe_error_counts_as_pressure(monkeypatch):
    m = models(monkeypatch, "auto", {"now": 1})
    m._pressure = lambda: 1 / 0
    m.transcriber()
    m.done_with_transcriber()
    assert not m.loaded


def test_off_always_releases_and_on_keeps_until_critical(monkeypatch):
    m = models(monkeypatch, False, {"now": 1})
    m.diarizer()
    m.done_with_diarizer()
    assert not m.loaded
    level = {"now": 2}
    m = models(monkeypatch, True, level)
    m.diarizer()
    m.done_with_diarizer()
    assert m.loaded
    level["now"] = 4
    assert m.release_if_pressure() and not m.loaded
