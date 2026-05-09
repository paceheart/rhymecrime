#!/usr/bin/env bash
#
# Bootstrap a clean RhymeCrime checkout end-to-end. Four idempotent steps;
# each can be re-run in isolation and self-detects already-done state:
#
#   bundle install              # Ruby gems pinned in Gemfile / Gemfile.lock
#   ./bin/setup-corpora         # external corpora + stable corpus mirrors
#   ./bin/setup-python-venv     # .venv/ for MPNet encoding (sentence-transformers + msgpack)
#   ./bin/build                 # full pipeline (see bin/build header): rarity dump,
#                               # rarity classifier, MPNet sense vectors,
#                               # relatedness classifier, dictionary final compile
#
# Run from the repo root after a fresh clone:
#
#   ./setup.sh             # everything above, in order — fully turnkey
#   bundle exec rspec      # validate against the trained classifiers
#
# Prereqs on the host: ruby (matching template.yaml's Lambda runtime),
# bundler, curl, gunzip. Python 3 is *not* a prereq — bin/setup-python-venv
# uses uv (https://astral.sh/uv) to provision a managed CPython 3.12 when no
# GIL-enabled Python is found on PATH.
#
# End-to-end runtime is ~60 min on a fresh clone, dominated by Build Stage
# setup-corpora (Numberbatch + ConceptNet mirror I/O) and Build Stage 3/4
# (MPNet encoding on CPU, ~20 min). Re-runs are much cheaper since each step
# short-circuits when its outputs are already on disk and current.

set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO"

bundle install
./bin/setup-corpora
./bin/setup-python-venv
./bin/build

echo
echo "setup.sh done. Validate with:"
echo "  bundle exec rspec"
