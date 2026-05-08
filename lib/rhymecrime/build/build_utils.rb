# frozen_string_literal: true

# Build pipeline entry: shared runtime utils plus anything build-only in the future.
# Prefer require "rhymecrime/utils" from app/runtime code; use this from dict.rb, bins, and chdir-based loaders.

require_relative "../utils"
require_relative "hyphen_variant_map"
require_relative "corpus_caches"
require_relative "lexicon_write"
