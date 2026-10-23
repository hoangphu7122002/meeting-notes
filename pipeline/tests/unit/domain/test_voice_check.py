import numpy as np
import pytest

from meeting_notes.domain.voice_check import MAX_WINDOWS, MIN_WINDOWS, SHORT_SPEECH_SEC, check_windows, precheck, single_voice


def voice(direction, n, seed=0, noise=0.05):
    rng = np.random.default_rng(seed)
    return np.asarray(direction, float) + rng.normal(0, noise, (n, len(direction)))


def test_windows_skip_excluded_remote_speech_and_short_pieces():
    windows = check_windows([(0.0, 10.0), (20.0, 21.0)], exclude=[(4.0, 5.0)])
    assert windows == [(0.0, 3.0), (5.0, 8.0), (8.0, 10.0)]  # (3, 4) and (20, 21) are shorter than 1.5 s


def test_windows_are_capped_and_spread_over_the_meeting():
    windows = check_windows([(0.0, 3600.0)])
    assert len(windows) == MAX_WINDOWS
    assert windows[0][0] == 0.0 and windows[-1][1] == 3600.0


def test_short_mic_speech_is_single_without_embeddings():
    assert precheck(SHORT_SPEECH_SEC - 1, 0)[0] is True
    assert single_voice(np.zeros((0, 4)), 12.0)[0] is True


def test_too_few_windows_is_unsure():
    assert precheck(300.0, MIN_WINDOWS - 1)[0] is None
    assert precheck(300.0, MIN_WINDOWS) is None  # embeddings decide


def test_one_voice_is_single():
    assert single_voice(voice([1, 0, 0, 0], 30), 600.0)[0] is True


def test_two_voices_are_several_even_when_one_is_rare():
    emb = np.vstack([voice([1, 0, 0, 0], 40), voice([0, 1, 0, 0], 4, seed=1)])
    verdict, reason = single_voice(emb, 600.0)
    assert verdict is False and "2 voices" in reason


def test_balanced_two_voices_are_several():
    emb = np.vstack([voice([1, 0, 0, 0], 20), voice([0.3, 1, 0, 0], 20, seed=1)])
    assert single_voice(emb, 600.0)[0] is False


def test_scattered_windows_are_unsure():
    one = voice([1, 0, 0, 0], 20)
    strays = np.eye(4)[1:].repeat(1, axis=0) * 1.0
    strays = np.vstack([strays, -np.eye(4)[1:]])  # 6 windows unlike anything else
    assert single_voice(np.vstack([one, strays]), 600.0)[0] is None


def test_one_stray_window_is_tolerated():
    emb = np.vstack([voice([1, 0, 0, 0], 20), [[0, 0, 0, 1.0]]])
    assert single_voice(emb, 600.0)[0] is True


@pytest.mark.parametrize("bad", [np.full((10, 4), np.nan), np.zeros((10, 4))])
def test_invalid_embeddings_are_unsure(bad):
    assert single_voice(bad, 600.0)[0] is None
