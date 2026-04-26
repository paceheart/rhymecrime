#!/usr/bin/env python3
"""Merge the +definition+ map from a freshly-encoded subset msgpack
(produced by +bin/build-sense-vectors.py+ on a CSV-limited dump) into the
production +generated/model_sense_vectors.msgpack+.

Only the +definition+ key is overwritten/extended; +headword+ and +senses+
in the production file are preserved verbatim. Used during incremental
development of the +def_cos+ classifier feature so we can retrain on the
~2k CSV-referenced lemmas without re-encoding the full ~65k vocab (~30 min
on Apple Silicon MPS).

Usage:
    .venv/bin/python bin/merge-definition-vectors.py \\
        --subset /tmp/related_subset.msgpack \\
        --target generated/model_sense_vectors.msgpack
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import msgpack


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--subset", type=Path, required=True)
    p.add_argument("--target", type=Path, required=True)
    args = p.parse_args()

    with open(args.subset, "rb") as f:
        subset = msgpack.unpack(f, raw=False)
    sub_def = subset.get("definition") or {}
    if not sub_def:
        print(f"subset has no 'definition' map; nothing to merge", file=sys.stderr)
        sys.exit(2)

    with open(args.target, "rb") as f:
        target = msgpack.unpack(f, raw=False)

    if target.get("dim") and subset.get("dim") and target["dim"] != subset["dim"]:
        print(
            f"dim mismatch: target={target['dim']} subset={subset['dim']}",
            file=sys.stderr,
        )
        sys.exit(2)

    existing = target.get("definition") or {}
    before = len(existing)
    existing.update(sub_def)
    target["definition"] = existing
    after = len(existing)

    with open(args.target, "wb") as f:
        msgpack.pack(target, f)

    size_mb = args.target.stat().st_size / 1024.0 / 1024.0
    print(
        f"merged {len(sub_def)} subset definitions into {args.target} "
        f"(definition: {before} -> {after}; file {size_mb:.1f} MB)",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
