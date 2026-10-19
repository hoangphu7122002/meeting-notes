import numpy as np

from meeting_notes.audio import SR
from meeting_notes.diarize import absorb_small_clusters, agglomerative, cluster_speakers


def test_agglomerative_separates_directions():
    rng = np.random.default_rng(0)
    a = np.array([1.0, 0, 0]) + rng.normal(0, 0.05, (5, 3))
    b = np.array([0, 1.0, 0]) + rng.normal(0, 0.05, (5, 3))
    labels = agglomerative(np.vstack([a, b]), 0.5)
    assert len(set(labels[:5])) == 1 and len(set(labels[5:])) == 1 and labels[0] != labels[5]


def test_absorb_small_clusters():
    emb = np.array([[1, 0], [1, 0.1], [0, 1]], dtype=float)
    labels = absorb_small_clusters(emb, np.array([0, 0, 1]), [30.0, 30.0, 1.0])
    assert set(labels) == {0}


def test_cluster_speakers_with_fake_embeddings():
    # Speaker identity is encoded in the sign of the audio: positive DC = A, negative DC = B.
    audio = np.concatenate([np.full(SR * 4, 0.5), np.zeros(SR), np.full(SR * 6, -0.5), np.zeros(SR), np.full(SR * 2, 0.5)]).astype(np.float32)
    regions = [(0.0, 4.0), (5.0, 11.0), (12.0, 14.0)]

    def embed(chunk):
        return np.array([1.0, 0.0]) if chunk.mean() > 0 else np.array([0.0, 1.0])

    turns = cluster_speakers(audio, regions, embed, threshold=0.5)
    labels = [label for _, _, label in turns]
    assert labels[0] == labels[-1] != labels[1]
    assert turns[0][:2] == (0.0, 4.0)
