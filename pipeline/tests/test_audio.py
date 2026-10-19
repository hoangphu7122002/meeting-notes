import numpy as np

from meeting_notes import audio as A


def tone(sec, amp=0.3, sr=A.SR, freq=220.0):
    t = np.arange(int(sec * sr)) / sr
    return (amp * np.sin(2 * np.pi * freq * t)).astype(np.float32)


def test_interval_ops():
    assert A.merge_gaps([(0, 1), (1.2, 2), (5, 6)], 0.3) == [(0, 2), (5, 6)]
    assert A.subtract([(0, 10)], [(2, 3), (5, 6)]) == [(0, 2), (3, 5), (6, 10)]
    assert A.subtract([(0, 1)], [(0, 2)]) == []
    assert A.total([(0, 1), (2, 4)]) == 3
    assert A.overlap((0, 2), (1, 5)) == 1


def test_place_and_mix():
    x = np.ones(10, dtype=np.float32)
    placed = A.place(x, 5 / A.SR, 12)
    assert placed[:5].sum() == 0 and placed[5:].sum() == 7
    mixed = A.mix([np.full(4, 0.8, np.float32), np.full(4, 0.8, np.float32)])
    assert np.max(np.abs(mixed)) <= 0.99 + 1e-6


def test_energy_vad_finds_speech_regions():
    rng = np.random.default_rng(0)
    noise = lambda sec: (rng.normal(0, 0.001, int(sec * A.SR))).astype(np.float32)
    x = np.concatenate([noise(1), tone(2), noise(2), tone(1.5), noise(1)])
    regions = A.energy_vad(x)
    assert len(regions) == 2
    (s1, e1), (s2, e2) = regions
    assert abs(s1 - 1) < 0.15 and abs(e1 - 3) < 0.15
    assert abs(s2 - 5) < 0.15 and abs(e2 - 6.5) < 0.15


def test_energy_vad_silence():
    assert A.energy_vad(np.zeros(A.SR * 2, dtype=np.float32)) == []


def test_bleed_ratio_detects_echo():
    rng = np.random.default_rng(1)
    env = np.repeat(rng.uniform(0.0, 0.5, 200), 800).astype(np.float32)
    system = env * rng.normal(0, 1, env.size).astype(np.float32)
    echo = 0.2 * np.roll(system, 320) + rng.normal(0, 0.001, env.size).astype(np.float32)
    quiet = rng.normal(0, 0.001, env.size).astype(np.float32)
    speech = [(0.0, env.size / A.SR)]
    assert A.bleed_ratio(echo, system, speech) > 0.5
    assert A.bleed_ratio(quiet, system, speech) < 0.35


def test_encode_and_decode_roundtrip(tmp_path):
    src = tmp_path / "a.wav"
    A.write_wav(src, tone(1.0))
    A.encode_m4a([(src, 0.5)], tmp_path / "a.m4a")
    y = A.decode(tmp_path / "a.m4a")
    assert abs(len(y) / A.SR - 1.5) < 0.1
    assert np.abs(y[: int(0.4 * A.SR)]).max() < 0.02  # leading delay is silent
