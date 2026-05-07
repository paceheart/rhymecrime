#!/usr/bin/env python3
"""Encode the JSONL dumped by bin/dump-sense-glosses with a sentence-transformer
and write model_sense_vectors.msgpack.

Input JSONL (one object per line): {"word": str, "sense_idx": int, "text": str}
  sense_idx == -1  -> headword embedding (text is usually just the word)
  sense_idx == -2  -> pooled-definition embedding ("{word}. {gloss1}. {gloss2}...")
  sense_idx >=  0  -> per-sense embedding (text is "{word}: {gloss}")

Output msgpack (format = "flat-fp32-v1"):
  {
    "model":      str,                  # e.g. "sentence-transformers/all-mpnet-base-v2"
    "dim":        int,
    "format":     "flat-fp32-v1",
    "headword":   {"keys": [word,...], "values": <bytes>},
    "definition": {"keys": [word,...], "values": <bytes>},   # pooled-gloss embedding, fallback = headword text
    "senses":     {"keys": [word,...], "counts": [int,...], "values": <bytes>},
  }

  - "values" is a contiguous little-endian fp32 buffer in row-major order: for headword/
    definition, len(keys) rows of `dim` floats; for senses, sum(counts) rows of `dim`
    floats with rows for keys[0] first (counts[0] rows), then keys[1] (counts[1] rows),
    etc. — sense rows for each word are ordered by sense_idx.
  - The Ruby loader (lib/rhymecrime/relatedness/signals.rb model_sense_vectors_table)
    parses each "values" blob with Numo::SFloat.from_binary in one shot, then takes
    zero-copy per-word views — so load time is dominated by the msgpack bin reads
    rather than by 370k+ Ruby-array-to-Numo casts. fp32 host-endian on the writer
    (numpy default on x86/arm64) and reader (Numo::SFloat.from_binary is host-endian)
    matches our macOS/Linux-LE deployment.

Vectors are L2-normalized, so Ruby can treat cosine-similarity as a dot product.

Setup (from repo root):
    python3 -m venv .venv
    .venv/bin/pip install -U pip
    .venv/bin/pip install sentence-transformers msgpack

Usage:
    .venv/bin/python bin/build-sense-vectors.py
    .venv/bin/python bin/build-sense-vectors.py --input /tmp/glosses.jsonl --model sentence-transformers/all-MiniLM-L6-v2
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def _default_io_paths():
    bd = os.environ.get("RHYMECRIME_BUILD_DIR")
    if bd:
        root = Path(bd)
        return root / "sense_glosses.jsonl", root / "model_sense_vectors.msgpack"
    g = REPO / "generated"
    return g / "sense_glosses.jsonl", g / "model_sense_vectors.msgpack"


DEFAULT_INPUT, DEFAULT_OUTPUT = _default_io_paths()
DEFAULT_MODEL = "sentence-transformers/all-mpnet-base-v2"


def parse_args():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--input", type=Path, default=DEFAULT_INPUT)
    p.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    p.add_argument("--model", default=DEFAULT_MODEL)
    p.add_argument("--batch-size", type=int, default=64)
    p.add_argument(
        "--device",
        default=None,
        help="torch device (cpu/cuda/mps). Auto-select if omitted.",
    )
    p.add_argument("--limit", type=int, default=None, help="stop after N items (debug)")
    return p.parse_args()


def autodetect_device():
    try:
        import torch

        if torch.backends.mps.is_available():
            return "mps"
        if torch.cuda.is_available():
            return "cuda"
    except ImportError:
        pass
    return "cpu"


def main():
    args = parse_args()
    device = args.device or autodetect_device()
    print(f"device: {device}", file=sys.stderr)

    try:
        import msgpack  # noqa: F401
        import torch
        from sentence_transformers import SentenceTransformer
    except ImportError as e:
        print(
            "missing dep. from repo root:\n"
            "  python3 -m venv .venv\n"
            "  .venv/bin/pip install -U pip\n"
            "  .venv/bin/pip install sentence-transformers msgpack\n"
            f"underlying: {e}",
            file=sys.stderr,
        )
        sys.exit(2)

    # Determinism. MPS in particular schedules kernels non-deterministically by
    # default; without this, two back-to-back encodes of the same JSONL produce
    # bit-different embeddings and the downstream GBT classifier varies by ~50
    # composite points across reruns. Seeded RNG + deterministic-cudnn covers the
    # CUDA path too, and the MPS-specific env var disables the float-fallback
    # paths that don't carry deterministic guarantees.
    import os

    torch.manual_seed(0)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(0)
        torch.backends.cudnn.deterministic = True
        torch.backends.cudnn.benchmark = False
    os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "0")

    items = []
    with open(args.input, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            items.append(json.loads(line))
            if args.limit and len(items) >= args.limit:
                break
    print(f"loaded {len(items)} items from {args.input}", file=sys.stderr)

    print(f"loading model {args.model}...", file=sys.stderr)
    model = SentenceTransformer(args.model, device=device)

    texts = [it["text"] for it in items]
    t0 = time.time()
    embeddings = model.encode(
        texts,
        batch_size=args.batch_size,
        show_progress_bar=True,
        normalize_embeddings=True,
        convert_to_numpy=True,
    )
    dt = time.time() - t0
    rate = len(texts) / dt if dt > 0 else 0.0
    dim = int(embeddings.shape[1])
    print(
        f"encoded {len(texts)} items in {dt:.1f}s ({rate:.0f}/s) dim={dim}",
        file=sys.stderr,
    )

    # Bucket embedding row indices by output kind/word, so we can materialize each
    # section as a single np.float32 buffer (no per-vector Python-list round-trips).
    import numpy as np

    embeddings = np.ascontiguousarray(embeddings, dtype=np.float32)

    hw_row: dict[str, int] = {}
    df_row: dict[str, int] = {}
    sn_rows_by_word: dict[str, dict[int, int]] = {}
    for row, item in enumerate(items):
        word = item["word"]
        idx = int(item["sense_idx"])
        if idx == -1:
            hw_row[word] = row
        elif idx == -2:
            df_row[word] = row
        else:
            sn_rows_by_word.setdefault(word, {})[idx] = row

    def _flatten(rows: list[int]) -> bytes:
        if not rows:
            return b""
        # Fancy-indexing returns a copy; ascontiguousarray is then a no-op but keeps
        # the contract explicit. Both numpy and Numo::SFloat.from_binary use host
        # endianness; we deploy on LE-only platforms (macOS x86/arm64, Linux x86/arm64)
        # so this is portable in practice.
        sub = np.ascontiguousarray(embeddings[rows, :], dtype=np.float32)
        return sub.tobytes(order="C")

    hw_keys = list(hw_row.keys())
    hw_bytes = _flatten([hw_row[k] for k in hw_keys])

    df_keys = list(df_row.keys())
    df_bytes = _flatten([df_row[k] for k in df_keys])

    sn_keys = list(sn_rows_by_word.keys())
    sn_counts: list[int] = []
    sn_row_indices: list[int] = []
    for k in sn_keys:
        by_idx = sn_rows_by_word[k]
        ordered_idxs = sorted(by_idx)
        sn_counts.append(len(ordered_idxs))
        sn_row_indices.extend(by_idx[s] for s in ordered_idxs)
    sn_bytes = _flatten(sn_row_indices)

    out = {
        "model": args.model,
        "dim": dim,
        "format": "flat-fp32-v1",
        "headword": {"keys": hw_keys, "values": hw_bytes},
        "definition": {"keys": df_keys, "values": df_bytes},
        "senses": {"keys": sn_keys, "counts": sn_counts, "values": sn_bytes},
    }

    import msgpack

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with open(args.output, "wb") as f:
        msgpack.pack(out, f, use_bin_type=True)

    size_mb = args.output.stat().st_size / 1024.0 / 1024.0
    print(
        f"wrote {args.output} ({size_mb:.1f} MB) format=flat-fp32-v1: "
        f"{len(hw_keys)} headwords, {len(df_keys)} definitions, "
        f"{sum(sn_counts)} sense vectors across {len(sn_keys)} words",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
