import numpy as np
from helpers import speechlike as _speechlike, tone

from meeting_notes.domain.intervals import merge_gaps, overlap, subtract, total
from meeting_notes.domain.signal import SR, bleed_ratio, energy_vad, mix, place, speech_spans, speech_threshold_db


def test_interval_ops():
    assert merge_gaps([(0, 1), (1.2, 2), (5, 6)], 0.3) == [(0, 2), (5, 6)]
    assert subtract([(0, 10)], [(2, 3), (5, 6)]) == [(0, 2), (3, 5), (6, 10)]
    assert subtract([(0, 1)], [(0, 2)]) == []
    assert total([(0, 1), (2, 4)]) == 3
    assert overlap((0, 2), (1, 5)) == 1


def test_place_and_mix():
    x = np.ones(10, dtype=np.float32)
    placed = place(x, 5 / SR, 12)
    assert placed[:5].sum() == 0 and placed[5:].sum() == 7
    mixed = mix([np.full(4, 0.8, np.float32), np.full(4, 0.8, np.float32)])
    assert np.max(np.abs(mixed)) <= 0.99 + 1e-6


def test_energy_vad_finds_speech_regions():
    rng = np.random.default_rng(0)
    noise = lambda sec: (rng.normal(0, 0.001, int(sec * SR))).astype(np.float32)
    x = np.concatenate([noise(1), tone(2), noise(2), tone(1.5), noise(1)])
    regions = energy_vad(x)
    assert len(regions) == 2
    (s1, e1), (s2, e2) = regions
    assert abs(s1 - 1) < 0.15 and abs(e1 - 3) < 0.15
    assert abs(s2 - 5) < 0.15 and abs(e2 - 6.5) < 0.15


def test_energy_vad_silence():
    assert energy_vad(np.zeros(SR * 2, dtype=np.float32)) == []


def test_bleed_ratio_detects_echo():
    rng = np.random.default_rng(1)
    env = np.repeat(rng.uniform(0.0, 0.5, 200), 800).astype(np.float32)
    system = env * rng.normal(0, 1, env.size).astype(np.float32)
    echo = 0.2 * np.roll(system, 320) + rng.normal(0, 0.001, env.size).astype(np.float32)
    quiet = rng.normal(0, 0.001, env.size).astype(np.float32)
    speech = [(0.0, env.size / SR)]
    assert bleed_ratio(echo, system, speech) > 0.5
    assert bleed_ratio(quiet, system, speech) < 0.35


def test_speech_spans_skip_noise_and_split_long_pauses():
    rng = np.random.default_rng(0)
    room = rng.normal(0, 0.002, SR * 20).astype(np.float32)
    clicks = room.copy()
    for k in range(0, len(clicks) - 200, int(0.18 * SR)):
        clicks[k:k + 192] += rng.normal(0, 0.05, 192).astype(np.float32)
    speech = room.copy()
    speech[SR:SR * 3] += _speechlike(2)
    speech[SR * 9:SR * 11] += _speechlike(2, 180)
    th = speech_threshold_db(np.concatenate([speech, room]))
    assert speech_spans(room, th, 2.0) == []
    assert speech_spans(clicks, th, 2.0) == []  # keyboard: loud but not voiced
    spans = speech_spans(speech, th, 2.0)
    assert len(spans) == 2  # 6 s pause splits the block, silence around is trimmed
    assert abs(spans[0][0] / SR - 0.7) < 0.15 and abs(spans[1][1] / SR - 11.3) < 0.15
    assert len(speech_spans(speech, th, 10.0)) == 1
