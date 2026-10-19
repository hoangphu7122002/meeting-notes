"""Speaker turn logic: naming clusters, mic/system resolution, transcription blocks. Pure functions."""

from __future__ import annotations

from collections import defaultdict
from dataclasses import asdict, dataclass, field

from .audio import Interval, dilate, subtract, total


@dataclass
class Turn:
    start: float
    end: float
    speaker: str
    track: str  # "mic" | "system" | "mixed"

    @property
    def duration(self) -> float:
        return self.end - self.start

    def to_dict(self) -> dict:
        return asdict(self)


@dataclass
class Block:
    """A stretch of one speaker's speech on one track, transcribed as a unit."""

    start: float
    end: float
    speaker: str
    track: str
    parts: list[tuple[float, float]] = field(default_factory=list)  # constituent turns

    @property
    def duration(self) -> float:
        return self.end - self.start


def rename_clusters(turns: list[tuple[float, float, str]], first_index: int = 1) -> dict[str, str]:
    """Map raw cluster ids to "Speaker N" in order of first appearance."""
    mapping: dict[str, str] = {}
    for _, _, cluster in sorted(turns):
        if cluster not in mapping:
            mapping[cluster] = f"Speaker {first_index + len(mapping)}"
    return mapping


def resolve_two_tracks(
    mic_turns: list[tuple[float, float, str]],
    system_turns: list[tuple[float, float, str]],
    bleed: bool,
    me_name: str = "Me",
    mic_speakers: str = "auto",
    others_label: str | None = None,
) -> list[Turn]:
    """Combine per-track diarization into labelled turns.

    System clusters become "Speaker N" (or `others_label` when clustering was unavailable).
    Mic speech overlapping remote speech is dropped when the mic hears the speakers (bleed).
    The mic is the user ("Me") unless `mic_speakers == "auto"` and several voices with
    substantial speaking time are found (in-person meeting); those get their own labels.
    """
    out: list[Turn] = []
    sys_map = rename_clusters(system_turns)
    for s, e, c in system_turns:
        out.append(Turn(s, e, others_label or sys_map[c], "system"))

    remote_speech = [(s, e) for s, e, _ in system_turns]
    guard = dilate(remote_speech, 0.05, 0.35) if bleed else []
    cleaned: list[tuple[float, float, str]] = []
    for s, e, c in mic_turns:
        for ps, pe in subtract([(s, e)], guard):
            if pe - ps >= 0.25:
                cleaned.append((ps, pe, c))

    by_cluster: dict[str, float] = defaultdict(float)
    for s, e, c in cleaned:
        by_cluster[c] += e - s
    mic_total = sum(by_cluster.values())
    if not by_cluster:
        return sorted(out, key=lambda t: t.start)
    largest = max(by_cluster, key=by_cluster.get)
    real = {c for c, t in by_cluster.items() if c == largest or (t >= 20.0 and t >= 0.15 * mic_total)}

    if mic_speakers == "me" or len(real) == 1:
        names = {c: me_name for c in by_cluster}
    else:
        first = len(set(sys_map.values())) + 1 if not others_label else 1
        ordered = rename_clusters([t for t in cleaned if t[2] in real], first_index=first)
        names = {c: ordered.get(c, ordered[largest]) for c in by_cluster}
    for s, e, c in cleaned:
        out.append(Turn(s, e, names[c], "mic"))
    return sorted(out, key=lambda t: t.start)


def resolve_single_track(turns: list[tuple[float, float, str]], track: str = "mixed", single_label: str | None = None) -> list[Turn]:
    mapping = rename_clusters(turns)
    return [Turn(s, e, single_label or mapping[c], track) for s, e, c in sorted(turns)]


def build_blocks(turns: list[Turn], max_gap: float = 1.0, max_len: float = 40.0, interrupt_min: float = 1.0) -> list[Block]:
    """Merge consecutive turns of the same speaker into transcription blocks.

    A block closes when another speaker talks for at least `interrupt_min` seconds,
    when the pause exceeds `max_gap`, or when it would exceed `max_len`.
    """
    blocks: list[Block] = []
    open_blocks: dict[tuple[str, str], Block] = {}
    for t in sorted(turns, key=lambda t: (t.start, t.end)):
        key = (t.speaker, t.track)
        if t.duration >= interrupt_min:
            for other in [k for k in open_blocks if k != key]:
                blocks.append(open_blocks.pop(other))
        cur = open_blocks.get(key)
        if cur and t.start - cur.end <= max_gap and max(cur.end, t.end) - cur.start <= max_len:
            cur.end = max(cur.end, t.end)
            cur.parts.append((t.start, t.end))
            continue
        if cur:
            blocks.append(open_blocks.pop(key))
        open_blocks[key] = Block(t.start, t.end, t.speaker, t.track, [(t.start, t.end)])
    blocks.extend(open_blocks.values())
    return sorted(blocks, key=lambda b: (b.start, b.end))


def speaker_order(turns: list[Turn], me_name: str = "Me") -> list[str]:
    seen: list[str] = []
    for t in sorted(turns, key=lambda t: t.start):
        if t.speaker not in seen:
            seen.append(t.speaker)
    if me_name in seen:
        seen.remove(me_name)
        seen.insert(0, me_name)
    return seen


def speech_total(turns: list[Turn]) -> float:
    return total([(t.start, t.end) for t in turns])


def as_intervals(turns: list[tuple[float, float, str]]) -> list[Interval]:
    return [(s, e) for s, e, _ in turns]
