#!/usr/bin/env python3
"""Encode the JSONL dumped by bin/dump-sense-glosses with a sentence-transformer
and write generated/model_sense_vectors.msgpack.

Input JSONL (one object per line): {"word": str, "sense_idx": int, "text": str}
  sense_idx == -1  -> headword embedding (text is usually just the word)
  sense_idx >= 0   -> per-sense embedding (text is "{word}: {gloss}")

Output msgpack:
  {
    "model":    str,              # e.g. "sentence-transformers/all-mpnet-base-v2"
    "dim":      int,
    "headword": {word: [float,...]},
    "senses":   {word: [[float,...], [float,...], ...]},  # ordered by sense_idx
  }

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
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DEFAULT_INPUT = REPO / "generated" / "sense_glosses.jsonl"
DEFAULT_OUTPUT = REPO / "generated" / "model_sense_vectors.msgpack"
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

    headword: dict[str, list[float]] = {}
    senses_raw: dict[str, dict[int, list[float]]] = {}
    for item, vec in zip(items, embeddings):
        word = item["word"]
        idx = int(item["sense_idx"])
        vf = [float(x) for x in vec.tolist()]
        if idx < 0:
            headword[word] = vf
        else:
            senses_raw.setdefault(word, {})[idx] = vf

    senses: dict[str, list[list[float]]] = {}
    for word, by_idx in senses_raw.items():
        senses[word] = [by_idx[k] for k in sorted(by_idx)]

    out = {
        "model": args.model,
        "dim": dim,
        "headword": headword,
        "senses": senses,
    }

    import msgpack

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with open(args.output, "wb") as f:
        msgpack.pack(out, f)

    size_mb = args.output.stat().st_size / 1024.0 / 1024.0
    print(
        f"wrote {args.output} ({size_mb:.1f} MB): "
        f"{len(headword)} headwords, {sum(len(v) for v in senses.values())} sense vectors",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
