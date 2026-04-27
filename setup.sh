#!/usr/bin/env bash
#
# Bootstrap a clean RhymeCrime checkout end-to-end: install gems, fetch
# corpora, and run +bin/dict-build+ to populate +generated/+. Composed of
# three idempotent steps so each can be re-run in isolation when needed:
#
#   bundle install         # gems pinned in Gemfile / Gemfile.lock
#   ./bin/setup-corpora    # external corpora + small pre-aggregations
#   ./bin/dict-build       # compile the rhyming dictionary into generated/
#
# Run from the repo root after a fresh clone:
#
#   ./setup.sh             # everything above, in order
#   bundle exec rspec      # sanity check
#
# Prereqs on the host: ruby (matching +template.yaml+'s Lambda runtime),
# bundler, python3, curl, gunzip.

set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO"

bundle install
./bin/setup-corpora
./bin/dict-build

echo
echo "setup.sh done. Next: bundle exec rspec"
