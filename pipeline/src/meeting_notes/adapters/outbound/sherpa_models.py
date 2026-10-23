"""sherpa-onnx diarization weights: ungated GitHub release assets, sha256-pinned, downloaded on first use.

Files land in `<repo>/models/sherpa-onnx/` (the gitignored model dir). Licenses and attribution:
docs/research/diarization-alternatives.md section 6.
  segmentation: pyannote segmentation-3.0 (MIT, (c) 2022 CNRS), ONNX export by k2-fsa (Apache-2.0 tooling)
  embeddings:   3D-Speaker CAM++ (Apache-2.0, ModelScope iic/*); WeSpeaker VoxCeleb models are CC-BY-4.0
"""

from __future__ import annotations

import hashlib
import shutil
import tarfile
import tempfile
import urllib.request
from collections.abc import Callable
from pathlib import Path

from ...config import REPO_ROOT

MODELS_DIR = REPO_ROOT / "models" / "sherpa-onnx"
RELEASES = "https://github.com/k2-fsa/sherpa-onnx/releases/download"
SEGMENTATION = {
    "name": "sherpa-onnx-pyannote-segmentation-3-0",
    "url": f"{RELEASES}/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2",
    "sha256": "24615ee884c897d9d2ba09bb4d30da6bb1b15e685065962db5b02e76e4996488",
    "keep": ("model.onnx", "LICENSE", "README.md"),
}
# Embedding models (release "speaker-recongition-models", sic) -> sha256 from the release's checksum.txt.
EMBEDDINGS = {
    "3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced":
        "aa3cfc16963a10586a9393f5035d6d6b57e98d358b347f80c2a30bf4f00ceba2",
    "3dspeaker_speech_campplus_sv_en_voxceleb_16k": "357a834f702b80161e5b981182c038e18553c1f2ca752ed6cec2052365d4129b",
    "3dspeaker_speech_eres2net_sv_en_voxceleb_16k": "c59158379255ad66e161679cca6af8d52d51e389e3224ab7d7a7baae295c2db5",
    "wespeaker_en_voxceleb_resnet34_LM": "e9848563da86f263117134dfd7ad63c92355b37de492b55e325400c9d9c39012",  # CC-BY-4.0
}


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def _download(url: str, expected: str, dest: Path, log: Callable[[str], None]) -> None:
    """Download to a temp file next to `dest`, check sha256, then rename (no half-written models)."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    log(f"downloading {url.rsplit('/', 1)[-1]} (first use)")
    with tempfile.NamedTemporaryFile(dir=dest.parent, suffix=".part", delete=False) as tmp:
        part = Path(tmp.name)
        try:
            with urllib.request.urlopen(url, timeout=60) as resp:
                shutil.copyfileobj(resp, tmp)
        except BaseException:
            part.unlink(missing_ok=True)
            raise
    got = sha256(part)
    if got != expected:
        part.unlink(missing_ok=True)
        raise RuntimeError(f"checksum mismatch for {url.rsplit('/', 1)[-1]}: {got[:12]} != {expected[:12]}")
    part.chmod(0o644)
    part.replace(dest)


def segmentation_model(root: Path = MODELS_DIR, log: Callable[[str], None] = print,
                       fetch: Callable[..., None] = _download) -> Path:
    folder = root / SEGMENTATION["name"]
    model = folder / "model.onnx"
    if model.exists():
        return model
    archive = root / f"{SEGMENTATION['name']}.tar.bz2"
    fetch(SEGMENTATION["url"], SEGMENTATION["sha256"], archive, log)
    try:
        with tarfile.open(archive, "r:bz2") as tar:
            members = [m for m in tar.getmembers() if m.isfile() and Path(m.name).name in SEGMENTATION["keep"]
                       and Path(m.name).parent.name == SEGMENTATION["name"]]
            tar.extractall(root, members=members, filter="data")
    finally:
        archive.unlink(missing_ok=True)
    if not model.exists():
        raise RuntimeError(f"{SEGMENTATION['name']}: model.onnx missing from the archive")
    return model


def embedding_model(name: str, root: Path = MODELS_DIR, log: Callable[[str], None] = print,
                    fetch: Callable[..., None] = _download) -> Path:
    if name not in EMBEDDINGS:
        raise ValueError(f"unknown sherpa embedding model {name!r}; known: {', '.join(sorted(EMBEDDINGS))}")
    path = root / f"{name}.onnx"
    if not path.exists():
        fetch(f"{RELEASES}/speaker-recongition-models/{name}.onnx", EMBEDDINGS[name], path, log)
    return path
