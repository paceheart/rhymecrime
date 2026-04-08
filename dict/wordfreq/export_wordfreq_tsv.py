#!/usr/bin/env python3
# Export wordfreq Zipf scores to a TSV (word<TAB>zipf), one row per token.
# Uses the full language wordlist (iter_wordlist); no row cap.
# Requires: pip install wordfreq
# Default output: dict/generated/wordfreq.tsv (same path dict_lib.rb loads).

import argparse
import sys
from pathlib import Path


def main() -> None:
    here = Path(__file__).resolve().parent
    default_tsv = here.parent / "generated" / "wordfreq.tsv"
    parser = argparse.ArgumentParser(description="Write wordfreq zipf TSV for dict_lib.rb / analysis.")
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=default_tsv,
        help=f"Output path (default: {default_tsv})",
    )
    parser.add_argument("-l", "--lang", default="en", help="wordfreq language code (default: en)")
    args = parser.parse_args()
    try:
        import wordfreq
    except ImportError:
        print("Missing package. Install with: pip install wordfreq", file=sys.stderr)
        sys.exit(1)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    n = 0
    with args.output.open("w", encoding="utf-8") as f:
        for w in wordfreq.iter_wordlist(args.lang):
            z = wordfreq.zipf_frequency(w, args.lang)
            f.write(f"{w}\t{z}\n")
            n += 1
    print(f"Wrote {n} lines to {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()
