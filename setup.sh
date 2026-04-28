#!/usr/bin/env bash
#
# Bootstrap a clean RhymeCrime checkout end-to-end so that +./bin/build+ can
# then run unattended. Four idempotent steps; each can be re-run in isolation
# and self-detects already-done state:
#
#   bundle install              # Ruby gems pinned in Gemfile / Gemfile.lock
#   ./bin/setup-corpora         # external corpora + small pre-aggregations
#   ./bin/setup-python-venv     # .venv/ for MPNet encoding (sentence-transformers + msgpack)
#   ./bin/dict-build            # slim rhyme-dict compile (no CN+NB, no rarity rescore)
#
# Run from the repo root after a fresh clone:
#
#   ./setup.sh             # everything above, in order
#   ./bin/build            # full pipeline: CN+NB exports, rarity classifier,
#                          # MPNet sense vectors, relatedness classifier
#   bundle exec rspec      # passes only AFTER bin/build; specs assert against
#                          # the trained classifiers, which the slim setup
#                          # dict-build does not produce.
#
# Prereqs on the host: ruby (matching +template.yaml+'s Lambda runtime),
# bundler, curl, gunzip. Python 3 is *not* a prereq — +bin/setup-python-venv+
# uses uv (https://astral.sh/uv) to provision a managed CPython 3.12 when no
# GIL-enabled Python is found on PATH.
#
# RHYMECRIME_RARITY_CLASSIFIER=off below: dict-build hard-fails when the
# rarity classifier is absent (no silent rule-based fallback), but a clean
# checkout can't have one yet — the trainer reads a feature dump that the
# very first dict-build pass produces. The =off flag is the documented
# bootstrap escape; the same chicken-and-egg is what +bin/build+ resolves
# end-to-end after setup.sh completes.

set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO"

bundle install
./bin/setup-corpora
./bin/setup-python-venv
RHYMECRIME_RARITY_CLASSIFIER=off ./bin/dict-build

echo
echo "setup.sh done. Next:"
echo "  ./bin/build          # train classifiers + build full generated artifacts"
echo "  bundle exec rspec    # full spec sweep (asserts on trained classifiers)"
