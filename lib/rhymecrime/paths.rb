# frozen_string_literal: true

require "fileutils"
require "json"
require "msgpack"
require "set"
require_relative "build_io_utils"
require_relative "env"
require_relative "phoneme.rb"
require_relative "pace_utils"

# Rhyming utilities for RhymeCrime
# Used both in preprocessing and at runtime

RIME_DICT_FILENAME = "rime_dict.txt"
WORD_DICT_FILENAME = "word_dict.txt"
# MessagePack mirrors of the .txt artifacts above. Same shape semantics —
# word_dict.msgpack is {word => [freq, prons, lemma_or_nil]} where prons
# is an Array of space-joined ARPABET strings (split on load to feed
# Pronunciation.new); rime_dict.msgpack is {rime => [w1, w2, ...]}. Self-
# lemmas are stored as nil (matching save_word_lemma_map!'s policy) and
# materialized back to the headword on load.
#
# These are the runtime-canonical artifacts: word_dict() / rime_dict() in
# query.rb load these in BOTH local-dev and Lambda mode (the DDB word# /
# rime# partitions were retired — see bin/upload-to-dynamodb and
# bin/stage-lambda). The .txt files are kept on disk for human inspection
# and for tools like bin/audit-word that grep them, but the runtime never
# reads them when the .msgpack is present.
#
# Built by rebuild_rhymecrime_dictionaries alongside the .txt saves so a
# single ./bin/dict-build refreshes both surfaces; see bin/build and
# bin/dict-build for the full pipeline.
WORD_DICT_MSGPACK_FILENAME = "word_dict.msgpack"
RIME_DICT_MSGPACK_FILENAME = "rime_dict.msgpack"
# Flat {word => canonical_lemma} table, emitted by dict-build right after
# save_word_dict and read into $word_to_lemma at runtime. Exists so the
# hot lemma(w) path (hit thousands of times per page render while coloring
# set_related tuples) is a single Hash lookup, instead of walking through
# lexicon_word_entry → DataSource.dynamodb? → word_dict[w] → entry[2]
# on every call. Shipping this msgpack in the Lambda deploy bundle also lets
# DDB mode answer lemma(w) without a per-word GetItem.
WORD_LEMMA_MAP_FILENAME = "word_lemma_map.msgpack"
# Derivational-base map used by the relatedness pipeline only (R3). Composes
# on top of lemma(w) at runtime: semantic_base(w) = derivation_map[lemma(w)]
# || lemma(w). Built from WordNet derivation pointers + a curated suffix
# allowlist in compute_semantic_base_map. Keys are inflectional-base headwords
# (i.e. self-lemmas — artistic, criminality); values are the derivational
# root (artist, criminal). Inflected surfaces aren't keys here because
# they compose through lemma(w) first. Loaded lazily into
# $word_to_semantic_base on the first semantic_base(w) call.
WORD_SEMANTIC_BASE_MAP_FILENAME = "word_semantic_base_map.msgpack"
# Sorted "word\\tbase\\ttransform" dump emitted alongside the msgpack so the
# map is auditable by eye. Not loaded at runtime.
WORD_SEMANTIC_BASE_MAP_TXT_FILENAME = "word_semantic_base_map.txt"
# Local-dev key/value store that mirrors the DynamoDB schema used in Lambda:
# the related table is keyed by "related#<lemma>" with parallel words and
# scores JSON arrays. Single SQLite file, no daemon; boot is O(open file) and
# per-lemma lookups are a single indexed SELECT. Built by bin/compute-relatedness
# and consumed by Rhymecrime::LocalStore (runtime shim) and by bin/upload-to-dynamodb
# (when streaming rows up to prod DDB). In Lambda this file is absent and
# Rhymecrime::DataSource.dynamodb? routes everything to DynamoRuntime instead.
LOCAL_STORE_FILENAME = "rhymecrime_local.sqlite3"
PART_OF_SPEECH_FILENAME = "part_of_speech.json"
# Multi-spelling hyphen folds (in-laws/inlaws, …); built in dict.rb, loaded at runtime.
HYPHEN_VARIANT_MAP_FILENAME = "hyphen_variant_map.json"
# ConceptNet-derived edge weights for topical relatedness; corpus mirror at
# generated/conceptnet_edges.msgpack — built once by ensure_conceptnet_edges_cache!
# from corpora/conceptnet/conceptnet-assertions-*.csv.gz, then loaded with
# load_conceptnet_edges_streaming + a build-time / runtime-time word_dict filter
# (mirrors the numberbatch_vectors.msgpack pattern: stable corpus-derived
# artifact, filtered + canonicalized at load). Records are raw (w1, w2, weight)
# triples on kept relations with w1 < w2; canonicalization to dict spellings
# happens at load time via relatedness_canonical_spelling_for_conceptnet_lemma.
CONCEPTNET_EDGES_FILENAME = "conceptnet_edges.msgpack"
CONCEPTNET_EDGES_STREAM_FORMAT = "cnedges_stream_v1"
# English vocab on kept ConceptNet relations; built by bin/preprocess-conceptnet -> generated/.
CONCEPTNET_VOCAB_CACHE_FILENAME = "conceptnet_assertions.txt.gz"
# Numberbatch word vectors pre-filtered to dictionary *base* headwords only; built in dict.rb.
NUMBERBATCH_VECTORS_FILENAME = "numberbatch_vectors.msgpack"
# USF cue→target association strengths (FSG); place under generated/ for runtime (e.g. built from corpora/usf/).
USF_ASSOCIATIONS_FILENAME = "usf_associations.json"
# Auto-detected lexical spelling variant pairs (e.g. -oes/-os), emitted by dict-build from corpus
# frequency data. Whitespace-separated preferred alt pairs (legacy format kept for the auto
# file; the hand-edited list lives at curated/spelling.csv in CSV form). Both are loaded at
# runtime via load_variants_raw so no corpus I/O leaks into the runtime path.
SPELLING_VARIANTS_AUTO_FILENAME = "spelling_variants_auto.txt"
# Learned relatedness score-combiner (logistic regression over PairSignals features);
# built by bin/train-relatedness-classifier, consumed in related.rb.
RELATEDNESS_CLASSIFIER_FILENAME = "relatedness_classifier.json"
# Contextualized sentence-transformer embeddings of dictionary-lemma headwords and their
# WordNet/Wiktionary gloss-per-sense. Built by bin/dump-sense-glosses ->
# bin/build-sense-vectors.py into the active timestamped build directory.
# MessagePack: { model:, dim:, headword: {lemma=>vec}, senses: {lemma=>[vec,…]} }.
# Provides the modern-embedding signals in PairSignals that supplement Numberbatch.
MODEL_SENSE_VECTORS_FILENAME = "model_sense_vectors.msgpack"
# Wiktionary (Kaikki) per-headword definitional glosses, parallel to (and merged with) the
# WordNet synset glosses consulted by the gloss-token, gloss-citation, and per-sense embedding
# code paths. Built by load_wiktionary at dict-build time from the same filtered Kaikki dump
# the rest of wiktionary.rb already loads, then serialized as MessagePack
# { headword => [gloss_text_1, gloss_text_2, ...] } where each entry is one Kaikki sense's
# first gloss (alt-of / form-of pointer senses are filtered out so only definitional text
# survives — the alt-of pointers already feed corpus_variants).
#
# Loaded lazily into $wiktionary_glosses on first call to wiktionary_glosses_for, with the
# usual nil-loader / false-sentinel pattern so a missing file (fresh checkout pre-dict-build,
# or Lambda runtime where corpora aren't shipped) collapses to "no glosses" instead of raising.
# Same conservative-on-no-signal contract as gloss_tokens_for_word in query.rb and
# gloss_word_token_set in signals.rb: callers default to the WordNet-only behavior when
# this map is empty.
WIKTIONARY_GLOSSES_FILENAME = "wiktionary_glosses.msgpack"
# Word-frequency rare ceiling: treat as rare when frequency is at or below this (see rare? in query.rb).
RARE_FREQ_MAX = 4

# Rime dict build: when false (default), drop buckets where every pair of common headwords (freq>RARE_FREQ_MAX)
# rhymes only as rich rhymes for this rime. Set INCLUDE_RICH_RHYMES=1 to keep those buckets.
INCLUDE_RICH_RHYMES = Rhymecrime::Env.strict_truthy?(ENV["INCLUDE_RICH_RHYMES"])

# debug comes from runtime (e.g. pace_utils via crime); dict-build loads this file alone.
# Do not use respond_to?(:debug) — it can be true without a callable debug on main in some loads.
def dict_utils_debug(msg)
  return unless defined?(debug) == "method"

  debug(msg)
end

# Outputs of dict.rb (dictionary compiler); not hand-edited.
# GENERATED_ROOT_DIR — flat tree at <repo>/generated/ for stable corpus caches (ConceptNet
# gz caches, numberbatch_vectors.msgpack, wordfreq.tsv).
# GENERATED_DIR — <repo>/generated/current/ (symlink → latest build's runtime/); all
# runtime lexicon artifacts dict-build emits and query.rb loads live here.
REPO_ROOT = File.expand_path("../..", __dir__)
WORDNET_3_1_PATH = File.join(REPO_ROOT, "corpora", "wordnet", "3.1").freeze
GENERATED_ROOT_DIR = File.join(REPO_ROOT, "generated")
GENERATED_DIR = File.join(GENERATED_ROOT_DIR, "current")

# Hand-curated inputs (lemma/spelling/related/rarity CSVs, common/rare/forbid/stop word
# lists, authoritative pronunciation overrides, neol supplement). All ten files live
# under <repo>/curated/ — see curated/README.md.
CURATED_DIR = File.join(REPO_ROOT, "curated")

def rhymecrime_build_dir
  d = ENV["RHYMECRIME_BUILD_DIR"]
  return nil if d.nil? || d.to_s.empty?

  # dict-build chdirs to lib/rhymecrime/build before loading dict.rb; relative
  # RHYMECRIME_BUILD_DIR must anchor to repo root or File.join(bd, ...) and
  # File.exist? resolve under build/ and miss e.g. runtime/rarity_classifier.json.
  File.expand_path(d, REPO_ROOT)
end

# Read-only override: point at any runtime/-shaped dir (e.g. generated/current
# or generated/last-known-good) and dictionary loaders read from there instead
# of generated/current. Use case: run two rspec jobs in parallel against
# different runtimes (e.g. compare current vs. last-known-good). Anchored to
# REPO_ROOT for the same reason rhymecrime_build_dir is.
def rhymecrime_runtime_dir
  d = ENV["RHYMECRIME_RUNTIME_DIR"]
  return nil if d.nil? || d.to_s.empty?

  File.expand_path(d, REPO_ROOT)
end

def bootstrap_mode?
  ENV["RHYMECRIME_BUILD_MODE"].to_s == "bootstrap"
end

def final_mode?
  ENV["RHYMECRIME_BUILD_MODE"].to_s == "final"
end

# Stable inputs / large vectors at generated/ root (not under generated/current/).
def generated_root_path(basename)
  File.join(GENERATED_ROOT_DIR, basename)
end

def generated_bootstrap_path(basename)
  bd = rhymecrime_build_dir
  raise "RHYMECRIME_BUILD_DIR is required for generated_bootstrap_path(#{basename.inspect})" unless bd

  File.join(bd, "bootstrap", basename)
end

def generated_runtime_path(basename)
  bd = rhymecrime_build_dir
  raise "RHYMECRIME_BUILD_DIR is required for generated_runtime_path(#{basename.inspect})" unless bd

  File.join(bd, "runtime", basename)
end

# Training / pedigree files at generated/<timestamp>/ when RHYMECRIME_BUILD_DIR is set;
# otherwise generated/ root (solo scripts).
def generated_stamp_path(basename)
  bd = rhymecrime_build_dir
  return generated_root_path(basename) unless bd

  File.join(bd, basename)
end

# Build-scoped training artifacts live at generated/<timestamp>/, not in the
# stable generated/ root. When no active build dir is exported, solo tools can
# still find the latest completed build through generated/current -> <stamp>/runtime
# (or, when comparing runtimes, through whatever RHYMECRIME_RUNTIME_DIR points at).
def generated_build_artifact_path(basename)
  bd = rhymecrime_build_dir
  return File.join(bd, basename) if bd

  resolve_via = rhymecrime_runtime_dir || GENERATED_DIR
  begin
    runtime_dir = File.realpath(resolve_via)
    stamp_dir = File.dirname(runtime_dir)
    candidate = File.join(stamp_dir, basename)
    return candidate if File.exist?(candidate)
  rescue SystemCallError
    # generated/current (or RHYMECRIME_RUNTIME_DIR) may not exist in a fresh checkout.
  end

  generated_root_path(basename)
end

# Resolves runtime lexicon artifacts:
#   * RHYMECRIME_RUNTIME_DIR set -> $RHYMECRIME_RUNTIME_DIR/<basename>     (read-only override; e.g. compare runs against last-known-good)
#   * RHYMECRIME_BUILD_DIR set   -> $RHYMECRIME_BUILD_DIR/runtime/<basename>
#   * otherwise                  -> generated/current/<basename>
# This lets every in-build subprocess (dict-build bootstrap+final, train-rarity-classifier,
# retrain-relatedness, dump-sense-glosses, ...) read in-flight runtime artifacts directly
# from the active timestamped build dir, while solo tools and the deployed runtime keep
# reading the symlinked generated/current/. The build orchestrator therefore only needs
# to flip generated/current/ once, on success — no mid-build checkpoint swap.
# Do not gate on RHYMECRIME_BUILD_MODE: bin/build only prefixes bootstrap/final for the
# dict-build invocations, so MODE is often unset while BUILD_DIR still points at the
# active stamp.
# RUNTIME_DIR wins over BUILD_DIR when both are set: it's the more specific "I want to
# read from exactly this directory" override, and tests that set it shouldn't accidentally
# pick up a half-built tree from a still-running build process.
def generated_dict_path(basename)
  rd = rhymecrime_runtime_dir
  return File.join(rd, basename) if rd

  bd = rhymecrime_build_dir
  return File.join(bd, "runtime", basename) if bd

  File.join(GENERATED_DIR, basename)
end

# Historical alias from when only a subset of dict-build call sites honored
# RHYMECRIME_BUILD_DIR. generated_dict_path now does the same fallback itself,
# so this is a thin wrapper kept for backward compatibility — new code should
# call generated_dict_path directly.
def generated_dict_path_under_dict_dir(basename)
  generated_dict_path(basename)
end

def ensure_generated_dict_dir!
  FileUtils.mkdir_p(GENERATED_DIR)
  bd = rhymecrime_build_dir
  return unless bd

  FileUtils.mkdir_p(File.join(bd, "bootstrap"))
  FileUtils.mkdir_p(File.join(bd, "runtime"))
end

# Symlink runtime copies of spelling + hyphen maps to ../bootstrap/ (Pass 2).
def link_runtime_spelling_hyphen_symlinks!
  return unless rhymecrime_build_dir && final_mode?

  %w[spelling_variants_auto.txt hyphen_variant_map.json].each do |fn|
    dest = generated_runtime_path(fn)
    FileUtils.rm_f(dest)
    FileUtils.ln_sf(File.join("..", "bootstrap", fn), dest)
  end
end
