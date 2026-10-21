"""Convert a Hugging Face transformers Whisper checkpoint (e.g. vinai/PhoWhisper-large) to the mlx-whisper format.

  uv run python scripts/convert_phowhisper.py vinai/PhoWhisper-large ../models/phowhisper-large-mlx
  uv run python scripts/convert_phowhisper.py vinai/PhoWhisper-large ../models/phowhisper-large-mlx-q4 --bits 4
  uv run python scripts/convert_phowhisper.py mlx-community/whisper-large-v3-turbo ../models/turbo-q8 --bits 8

A source that is already in mlx-whisper format (config.json with n_mels) is only quantized.

Output: <out>/config.json (mlx_whisper ModelDimensions, plus "quantization" when --bits is set) and
<out>/weights.safetensors, loadable with `mlx_whisper.transcribe(..., path_or_hf_repo=<out>)` or
`whisper_model = "<out>"` in config.toml.

The checkpoint is read tensor by tensor from a memory-mapped pytorch_model.bin (or model.safetensors), so peak RAM
stays near the fp16 model size (~3 GB for large). Quantization mirrors mlx-examples convert.py `-q`
(nn.quantize on Linear + Embedding, group size 64). PhoWhisper uses the stock multilingual Whisper vocabulary, so
mlx-whisper's bundled tokenizer applies unchanged. Word-timestamp alignment heads fall back to mlx-whisper's
default (last half of the decoder layers).
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

import mlx.core as mx
import numpy as np

# HF transformers name fragment -> openai/mlx-whisper name fragment, applied in order.
RENAMES = [
    (r"^model\.", ""),
    (r"^encoder\.layers\.", "encoder.blocks."),
    (r"^decoder\.layers\.", "decoder.blocks."),
    (r"^encoder\.layer_norm\.", "encoder.ln_post."),
    (r"^decoder\.layer_norm\.", "decoder.ln."),
    (r"^decoder\.embed_tokens\.weight$", "decoder.token_embedding.weight"),
    (r"^decoder\.embed_positions\.weight$", "decoder.positional_embedding"),
    (r"\.self_attn_layer_norm\.", ".attn_ln."),
    (r"\.encoder_attn_layer_norm\.", ".cross_attn_ln."),
    (r"\.final_layer_norm\.", ".mlp_ln."),
    (r"\.self_attn\.", ".attn."),
    (r"\.encoder_attn\.", ".cross_attn."),
    (r"\.q_proj\.", ".query."),
    (r"\.k_proj\.", ".key."),
    (r"\.v_proj\.", ".value."),
    (r"\.out_proj\.", ".out."),
    (r"\.fc1\.", ".mlp1."),
    (r"\.fc2\.", ".mlp2."),
]
# Not stored by mlx-whisper: sinusoidal encoder positions are recomputed, the output projection is tied.
DROP = [r"^model\.encoder\.embed_positions\.weight$", r"^proj_out\.weight$"]


def rename(key: str) -> str | None:
    if any(re.search(p, key) for p in DROP):
        return None
    for pat, rep in RENAMES:
        key = re.sub(pat, rep, key)
    return key


def dims(cfg: dict) -> dict:
    return {
        "n_mels": cfg["num_mel_bins"],
        "n_audio_ctx": cfg["max_source_positions"],
        "n_audio_state": cfg["d_model"],
        "n_audio_head": cfg["encoder_attention_heads"],
        "n_audio_layer": cfg["encoder_layers"],
        "n_vocab": cfg["vocab_size"],
        "n_text_ctx": cfg["max_target_positions"],
        "n_text_state": cfg["d_model"],
        "n_text_head": cfg["decoder_attention_heads"],
        "n_text_layer": cfg["decoder_layers"],
    }


def hf_tensors(src: Path):
    """Yield (name, float32 numpy array) one at a time without loading the whole checkpoint."""
    st = src / "model.safetensors"
    if st.exists():
        from safetensors import safe_open

        with safe_open(str(st), framework="np") as f:
            for k in f.keys():
                yield k, f.get_tensor(k).astype(np.float32)
        return
    import torch

    sd = torch.load(str(src / "pytorch_model.bin"), map_location="cpu", mmap=True, weights_only=True)
    for k in list(sd):
        yield k, sd.pop(k).float().numpy()


def convert(repo: str, out: Path, bits: int | None, group_size: int = 64) -> None:
    from mlx.utils import tree_flatten, tree_unflatten
    from mlx_whisper.whisper import ModelDimensions, Whisper

    src = Path(repo)
    if not src.exists():
        from huggingface_hub import snapshot_download

        src = Path(snapshot_download(repo, allow_patterns=["config.json", "pytorch_model.bin", "model.safetensors",
                                                           "weights.safetensors", "weights.npz"]))
    raw = json.loads((src / "config.json").read_text())
    if "n_mels" in raw:  # already mlx-whisper (e.g. mlx-community/whisper-large-v3-turbo): only quantize
        from mlx_whisper.load_models import load_model

        if raw.get("quantization"):
            raise SystemExit("source is already quantized")
        model = load_model(str(src), mx.float16)
        cfg = {k: v for k, v in raw.items() if k != "model_type"}
        return save(model, cfg, out, bits, group_size)
    cfg = dims(raw)

    weights: dict[str, mx.array] = {}
    for key, arr in hf_tensors(src):
        name = rename(key)
        if name is None:
            continue
        if name.endswith(("conv1.weight", "conv2.weight")):
            arr = arr.transpose(0, 2, 1)  # torch Conv1d (out, in, k) -> MLX (out, k, in)
        weights[name] = mx.array(arr.astype(np.float16))
        mx.eval(weights[name])

    model = Whisper(ModelDimensions(**cfg), mx.float16)
    expected = {k for k, _ in tree_flatten(model.parameters())} - {"alignment_heads"}
    missing, extra = expected - set(weights), set(weights) - expected
    if missing or extra:
        raise SystemExit(f"key mismatch: missing {sorted(missing)[:8]} extra {sorted(extra)[:8]}")
    model.update(tree_unflatten(list(weights.items())))
    del weights
    save(model, cfg, out, bits, group_size)


def save(model, cfg: dict, out: Path, bits: int | None, group_size: int) -> None:
    import mlx.nn as nn
    from mlx.utils import tree_flatten

    if bits:
        nn.quantize(model, group_size=group_size, bits=bits,
                    class_predicate=lambda _, m: isinstance(m, (nn.Linear, nn.Embedding)))
        cfg["quantization"] = {"group_size": group_size, "bits": bits}
    out.mkdir(parents=True, exist_ok=True)
    params = {k: v for k, v in tree_flatten(model.parameters()) if k != "alignment_heads"}
    mx.save_safetensors(str(out / "weights.safetensors"), params)
    (out / "config.json").write_text(json.dumps({**cfg, "model_type": "whisper"}, indent=2))
    size = (out / "weights.safetensors").stat().st_size / 2**30
    print(f"{out}: {size:.2f} GB, {cfg['n_audio_layer']}+{cfg['n_text_layer']} layers, bits={bits or 16}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("repo", help="HF repo id (vinai/PhoWhisper-large) or local checkpoint dir")
    ap.add_argument("out", type=Path)
    ap.add_argument("--bits", type=int, choices=[4, 8], help="quantize Linear/Embedding weights")
    ap.add_argument("--group-size", type=int, default=64)
    a = ap.parse_args()
    convert(a.repo, a.out, a.bits, a.group_size)


if __name__ == "__main__":
    main()
