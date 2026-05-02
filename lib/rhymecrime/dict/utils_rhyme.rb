#!/usr/bin/env ruby

require "fileutils"
require "json"
require "msgpack"
require "set"
require_relative "phoneme.rb"
require_relative "../pace_utils"

# Rhyming utilities for RhymeCrime
# Used both in preprocessing and at runtime

RIME_DICT_FILENAME = "rime_dict.txt"
WORD_DICT_FILENAME = "word_dict.txt"
# MessagePack mirrors of the +.txt+ artifacts above. Same shape semantics —
# +word_dict.msgpack+ is +{word => [freq, prons, lemma_or_nil]}+ where +prons+
# is an Array of space-joined ARPABET strings (split on load to feed
# +Pronunciation.new+); +rime_dict.msgpack+ is +{rime => [w1, w2, ...]}+. Self-
# lemmas are stored as +nil+ (matching +save_word_lemma_map!+'s policy) and
# materialized back to the headword on load.
#
# These are the runtime-canonical artifacts: +word_dict()+ / +rdict()+ in
# +crime.rb+ load these in BOTH local-dev and Lambda mode (the DDB +word#+ /
# +rime#+ partitions were retired — see +bin/upload-to-dynamodb+ and
# +bin/stage-lambda+). The +.txt+ files are kept on disk for human inspection
# and for tools like +bin/audit-word+ that grep them, but the runtime never
# reads them when the +.msgpack+ is present.
#
# Built by +rebuild_rhymecrime_dictionaries+ alongside the +.txt+ saves so a
# single +./bin/dict-build+ refreshes both surfaces; see +bin/build+ and
# +bin/dict-build+ for the full pipeline.
WORD_DICT_MSGPACK_FILENAME = "word_dict.msgpack"
RIME_DICT_MSGPACK_FILENAME = "rime_dict.msgpack"
# Flat +{word => canonical_lemma}+ table, emitted by dict-build right after
# +save_word_dict+ and read into +$word_to_lemma+ at runtime. Exists so the
# hot +lemma(w)+ path (hit thousands of times per page render while coloring
# +set_related+ tuples) is a single Hash lookup, instead of walking through
# +lexicon_word_entry+ → +DataSource.dynamodb?+ → +word_dict[w]+ → +entry[2]+
# on every call. Shipping this msgpack in the Lambda deploy bundle also lets
# DDB mode answer +lemma(w)+ without a per-word +GetItem+.
WORD_LEMMA_MAP_FILENAME = "word_lemma_map.msgpack"
# Derivational-base map used by the relatedness pipeline only (R3). Composes
# on top of +lemma(w)+ at runtime: +semantic_base(w) = derivation_map[lemma(w)]
# || lemma(w)+. Built from WordNet derivation pointers + a curated suffix
# allowlist in +compute_semantic_base_map+. Keys are inflectional-base headwords
# (i.e. self-lemmas — +artistic+, +criminality+); values are the derivational
# root (+artist+, +criminal+). Inflected surfaces aren't keys here because
# they compose through +lemma(w)+ first. Loaded lazily into
# +$word_to_semantic_base+ on the first +semantic_base(w)+ call.
WORD_SEMANTIC_BASE_MAP_FILENAME = "word_semantic_base_map.msgpack"
# Sorted +"word\\tbase\\ttransform"+ dump emitted alongside the msgpack so the
# map is auditable by eye. Not loaded at runtime.
WORD_SEMANTIC_BASE_MAP_TXT_FILENAME = "word_semantic_base_map.txt"
# Local-dev key/value store that mirrors the DynamoDB schema used in Lambda:
# the +related+ table is keyed by +"related#<lemma>"+ with parallel +words+ and
# +scores+ JSON arrays. Single SQLite file, no daemon; boot is O(open file) and
# per-lemma lookups are a single indexed SELECT. Built by bin/compute-relatedness
# and consumed by +Rhymecrime::LocalStore+ (runtime shim) and by bin/upload-to-dynamodb
# (when streaming rows up to prod DDB). In Lambda this file is absent and
# +Rhymecrime::DataSource.dynamodb?+ routes everything to +DynamoRuntime+ instead.
LOCAL_STORE_FILENAME = "rhymecrime_local.sqlite3"
PART_OF_SPEECH_FILENAME = "part_of_speech.json"
# Multi-spelling hyphen folds (in-laws/inlaws, …); built in dict.rb, loaded at runtime.
HYPHEN_VARIANT_MAP_FILENAME = "hyphen_variant_map.json"
# ConceptNet-derived edge weights for topical relatedness; built in dict.rb, loaded at runtime.
# Keys are underscore-normalized dictionary *base* lemmas (inflected headwords are folded at export).
CONCEPTNET_EDGES_FILENAME = "conceptnet_edges.json"
# English lemmas on kept ConceptNet relations; built by bin/preprocess-conceptnet-lemma-cache → generated/.
CONCEPTNET_LEMMA_CACHE_SUFFIX = ".en-kept-lemmas.txt.gz"
# Pre-canonicalization English edge triples (w1, w2, weight) on kept relations; a pure function of
# the assertions .csv.gz, so it can be reused across +dict-build+ runs whose +word_dict+ differs.
# Saves ~15% of total build time by skipping the full gzip-decompress + line-parse pass of
# +save_conceptnet_edge_map!+ when the cache is fresh.
CONCEPTNET_EDGES_CACHE_SUFFIX = ".en-kept-edges.msgpack.gz"
# Numberbatch word vectors pre-filtered to dictionary *base* headwords only; built in dict.rb.
NUMBERBATCH_VECTORS_FILENAME = "numberbatch_vectors.msgpack"
# USF cue→target association strengths (FSG); place under generated/ for runtime (e.g. built from corpora/usf/).
USF_ASSOCIATIONS_FILENAME = "usf_associations.json"
# Auto-detected lexical spelling variant pairs (e.g. -oes/-os), emitted by dict-build from corpus
# frequency data. Whitespace-separated +preferred alt+ pairs (legacy format kept for the auto
# file; the hand-edited list lives at +curated/spelling.csv+ in CSV form). Both are loaded at
# runtime via +load_variants_raw+ so no corpus I/O leaks into the runtime path.
SPELLING_VARIANTS_AUTO_FILENAME = "spelling_variants_auto.txt"
# Learned relatedness score-combiner (logistic regression over +PairSignals+ features);
# built by bin/train-relatedness-classifier, consumed in related.rb.
RELATEDNESS_CLASSIFIER_FILENAME = "relatedness_classifier.json"
# Contextualized sentence-transformer embeddings of dictionary-lemma headwords and their
# WordNet gloss-per-sense (built by bin/dump-sense-glosses → bin/build-sense-vectors.py).
# MessagePack: { model:, dim:, headword: {lemma=>vec}, senses: {lemma=>[vec,…]} }.
# Provides the modern-embedding signals in +PairSignals+ that supplement Numberbatch.
MODEL_SENSE_VECTORS_FILENAME = "model_sense_vectors.msgpack"
# Word-frequency rare ceiling: treat as rare when frequency is at or below this (see rare? in crime.rb).
RARE_FREQ_MAX = 4

# Rime dict build: when false (default), drop buckets where every pair of common headwords (freq>RARE_FREQ_MAX)
# rhymes only in the identical sense for this rime. Set INCLUDE_IDENTICAL_RHYMES=1 to keep those buckets.
INCLUDE_IDENTICAL_RHYMES = begin
  v = ENV["INCLUDE_IDENTICAL_RHYMES"]
  v && !v.empty? && %w[1 true yes on].include?(v.downcase)
end

# +debug+ comes from runtime (e.g. pace_utils via crime); dict-build loads this file alone.
# Do not use +respond_to?(:debug)+ — it can be true without a callable +debug+ on +main+ in some loads.
def dict_utils_debug(msg)
  return unless defined?(debug) == "method"

  debug(msg)
end

# Outputs of dict.rb (dictionary compiler); not hand-edited. Absolute paths under <repo>/generated/.
REPO_ROOT = File.expand_path("../../..", __dir__)
GENERATED_DIR = File.join(REPO_ROOT, "generated")

# Hand-curated inputs (lemma/spelling/related/rarity CSVs, common/rare/forbid/stop word
# lists, authoritative pronunciation overrides, neol supplement). All ten files live
# under <repo>/curated/ — see curated/README.md.
CURATED_DIR = File.join(REPO_ROOT, "curated")

def generated_dict_path(basename)
  File.join(GENERATED_DIR, basename)
end

def generated_dict_path_under_dict_dir(basename)
  File.join(GENERATED_DIR, basename)
end

def ensure_generated_dict_dir!
  FileUtils.mkdir_p(GENERATED_DIR)
end

#
# stop words — split by purpose into two disjoint-in-spirit curated lists.
#
#   semantically_promiscuous.txt — content-empty words that "relate to
#       everything" ("could", "perhaps", "henceforth", "thereby"). Kept in
#       +word_dict+ at sentinel-high frequency; relatedness predicates short-
#       circuit them in scoring / display. Predicate: +semantically_promiscuous?+.
#   unrhymable_stop_words.txt    — function words and contractions ("the",
#       "a", "you'll", "they're", "huh", "uh") that are valid English but
#       make poor rhyme targets. Deleted from +word_dict+ entirely at dict-
#       build time (see +delete_unrhymable_stop_words_from_hash+ in
#       +phonology.rb+), alongside the +forbidden+/+forbidden_ish+ rows in
#       +curated/rarity.csv+ (see +rarity_csv_forbidden_words+). Predicate:
#       +unrhymable_stop_word?+.
#
# Every runtime call site uses +semantically_promiscuous?+ — unrhymable
# entries are deleted from the dictionary, so they can never appear as a
# headword the relatedness / UI / pruning code might consult. There is no
# +stop_word?+ shim: any leftover call site is a bug we want to find at
# load time, not silently route through a union.
#
# A small overlap (seven entries: "eh", "mhm", "mm", "thees", "thou'd",
# "thou'll", "ye") between the two files is intentional — deletion wins
# (the unrhymable scrub runs before any +semantically_promiscuous?+ check
# the runtime can reach), so they leave the dict and the runtime never
# sees them.
#
# +#+ comment lines and blank lines are skipped; trailing whitespace on each
# entry is stripped (so +"hey "+ in the file matches +"hey"+).

UNRHYMABLE_STOP_WORDS_FILENAME = "unrhymable_stop_words.txt"
SEMANTICALLY_PROMISCUOUS_FILENAME = "semantically_promiscuous.txt"

$unrhymable_stop_words = nil
$semantically_promiscuous_words = nil

# Shared loader for newline-delimited curated word lists. +#+ comment lines
# and blank lines are skipped; trailing whitespace is stripped.
def load_curated_word_set(filename)
  set = Set.new
  path = File.join(CURATED_DIR, filename)
  File.foreach(path, chomp: true, encoding: "UTF-8") do |line|
    w = line.strip
    next if w.empty? || w.start_with?("#")
    set << w
  end
  set
end

def unrhymable_stop_words
  $unrhymable_stop_words ||= load_curated_word_set(UNRHYMABLE_STOP_WORDS_FILENAME)
end

def unrhymable_stop_word?(word)
  unrhymable_stop_words.include?(word)
end

def semantically_promiscuous_words
  $semantically_promiscuous_words ||= load_curated_word_set(SEMANTICALLY_PROMISCUOUS_FILENAME)
end

# Direct membership in +semantically_promiscuous.txt+, OR the word's +lemma+
# is in the list. The lemma fallback lets derived/inflected forms ("abouts",
# "having", "puts") inherit promiscuity from their base ("about", "have",
# "put") without us enumerating every inflection in the curated file.
#
# Safe to call before the lemma map exists on disk (dict-build seed loops in
# +frequency.rb+ / +phonology.rb+): +lemma+ falls back to +lexicon_word_entry+
# and ultimately to the word itself, so a missing map just collapses the
# fallback into the direct check we already did.
def semantically_promiscuous?(word)
  return true if semantically_promiscuous_words.include?(word)
  base = lemma(word)
  base != word && semantically_promiscuous_words.include?(base)
end

#
# rarity-list-driven word sets — common / rare / forbidden — read from
# +curated/rarity.csv+ (a single CSV is the source of truth, replacing the
# retired +common_words.txt+, +rare_words.txt+, and +forbid_list.txt+).
#
# Per-kind dispatch (matches the spec sweep in +spec/rarity_spec.rb+ and the
# eval scoring buckets):
#   +common+ / +common_ish+        -> rarity_csv_common_words
#   +rare+   / +rare_ish+          -> rarity_csv_rare_words
#   +forbidden+ / +forbidden_ish+  -> rarity_csv_forbidden_words
# Other kinds (+uncommon+, +common_no_rhymes+, +rare_no_rhymes+,
# +have_rhymes+) are eval-only labels and contribute nothing to these sets.
#
# Loaded lazily on first access (Set/Array memoized in process-globals) and
# the file is only opened once per process. CSV is parsed with the stdlib
# +CSV+ module — encoding is UTF-8 (matches +curated/rarity.csv+ on disk).
#

RARITY_CSV_PATH = File.join(CURATED_DIR, "rarity.csv")

RARITY_CSV_COMMON_KINDS = %w[common common_ish].freeze
RARITY_CSV_RARE_KINDS = %w[rare rare_ish].freeze
RARITY_CSV_FORBIDDEN_KINDS = %w[forbidden forbidden_ish].freeze

$rarity_csv_common_words = nil
$rarity_csv_rare_words = nil
$rarity_csv_forbidden_words_array = nil
$rarity_csv_forbidden_words_set = nil

def rarity_csv_common_words
  load_rarity_csv_word_sets! if $rarity_csv_common_words.nil?
  $rarity_csv_common_words
end

def rarity_csv_rare_words
  load_rarity_csv_word_sets! if $rarity_csv_rare_words.nil?
  $rarity_csv_rare_words
end

# Forbidden as an Array (insertion order = file order). Old +forbid_list+
# call sites used Array#include? semantics; preserved here so anything that
# expected an Array surface (e.g. iterations, +length+) keeps working.
def rarity_csv_forbidden_words
  load_rarity_csv_word_sets! if $rarity_csv_forbidden_words_array.nil?
  $rarity_csv_forbidden_words_array
end

def load_rarity_csv_word_sets!
  require "csv"
  common = Set.new
  rare = Set.new
  forbidden = []
  forbidden_seen = Set.new
  CSV.foreach(RARITY_CSV_PATH, headers: true, encoding: "UTF-8") do |row|
    word = row["word"].to_s.strip
    next if word.empty?
    kind = row["kind"].to_s.strip
    if RARITY_CSV_COMMON_KINDS.include?(kind)
      common << word
    elsif RARITY_CSV_RARE_KINDS.include?(kind)
      rare << word
    elsif RARITY_CSV_FORBIDDEN_KINDS.include?(kind)
      unless forbidden_seen.include?(word)
        forbidden << word
        forbidden_seen << word
      end
    end
  end
  $rarity_csv_common_words = common.freeze
  $rarity_csv_rare_words = rare.freeze
  $rarity_csv_forbidden_words_array = forbidden.freeze
  $rarity_csv_forbidden_words_set = forbidden_seen.freeze
end

#
# forbid_list — facade over +rarity_csv_forbidden_words+. Kept under the same
# name so legacy call sites (+explicitly_forbidden?+, +audit_word+,
# +delete_explicitly_forbidden_keys_from_hash+, …) don't have to learn about
# the rarity.csv plumbing.
#

def forbid_list
  rarity_csv_forbidden_words
end

# Word consists entirely of non-ASCII bytes (e.g. emoji like '🍇', '🌮', '🧢').
# UTF-8 ASCII chars occupy bytes < 0x80, so a word with no byte < 0x80 has zero
# ASCII characters. Mixed-script borrowings like +café+ / +résumé+ are NOT
# matched (they contain ASCII letters too) — only fully non-ASCII surfaces.
# Empty strings are not considered non-ASCII-only (no characters at all).
def non_ascii_only?(word)
  return false if word.nil? || word.empty?
  word.bytes.all? { |b| b >= 0x80 }
end

# +explicitly_forbidden?+ unifies two policy sources:
#   1. +forbidden+/+forbidden_ish+ rows in +curated/rarity.csv+
#      (the curated, hand-maintained block list)
#   2. +non_ascii_only?+ — any word with zero ASCII characters
#      (catches emoji and other purely-pictographic surfaces that leak in via
#      Wiktionary/Kaikki; we don't want them as headwords or as rhyme outputs).
# The build-time +forbidden_scrub+ pass in +frequency.rb+ iterates +word_dict+
# keys against this predicate, so the policy-2 inputs are also pruned from the
# generated dict on the next rebuild — no separate scrub needed.
def explicitly_forbidden?(word)
  return true if non_ascii_only?(word)
  load_rarity_csv_word_sets! if $rarity_csv_forbidden_words_set.nil?
  $rarity_csv_forbidden_words_set.include?(word)
end

#
# spelling variants
#

$variants = nil

# Cleared when spelling-variant file is reloaded or word_dict is re-read.
def clear_spelling_variant_hyphen_caches!
  @hyphen_multi_fold = nil
end

def variants()
  # hash: word -> [preferred_form alternate_form1 alternate_form2 ...]
  if $variants.nil?
    clear_spelling_variant_hyphen_caches!
    $variants = load_variants
  end
  return $variants
end

# US/UK -ize ↔ -ise (and -yze ↔ -yse) morphology: generate UK (s) from US (z) only.
# UK spellings map back to US as preferred only when that US headword exists in +$word_dict+
# (e.g. compromise has no valid *compromize*, so it is left alone—no blocklist needed).
US_UK_YZE_SUFFIXES = [
  ["yzing", "ysing"],
  ["yzes", "yses"],
  ["yzed", "ysed"],
  ["yze", "yse"],
].freeze

US_UK_IZE_SUFFIXES = [
  ["ization", "isation"],
  ["izations", "isations"],
  ["izable", "isable"],
  ["izer", "iser"],
  ["izers", "isers"],
  ["izing", "ising"],
  ["izes", "ises"],
  ["ized", "ised"],
  ["ize", "ise"],
].freeze

# Real -ize words that are not US verb morphology (avoid analyze→analyse style false path for "size", etc.).
US_UK_IZE_ZONLY_EXCEPTIONS = %w[size seize capsize prize maize].freeze

def word_dict_includes_headword?(w)
  defined?($word_dict) && $word_dict.is_a?(Hash) && !$word_dict.empty? && $word_dict.key?(w)
end

# Like +word_dict_includes_headword?+ but also requires that the entry carries at least one
# pronunciation. Used by US/UK variant-pair detection to avoid anointing frequency-only ghost
# entries (+expertize+, +favorize+, +criticize+/+criticise+ mispairings, etc.) as the
# preferred form of a well-pronounced counterpart: a prefix-less entry with empty prons
# can't rhyme, so making it the canonical surface strands the real word in no cohort.
def word_dict_includes_pronounced_headword?(w)
  return false unless defined?($word_dict) && $word_dict.is_a?(Hash) && !$word_dict.empty?
  entry = $word_dict[w]
  return false unless entry
  prons = entry[1]
  prons.is_a?(Array) && !prons.empty?
end

# Lexicon headwords (+ optional +WORDS_NEEDED_FOR_TESTING+). When +include_rhymeless+ is false,
# keep only words for which +has_rhyming_word?+ is true. When +common_only+ is true, drop +rare?+
# headwords (+frequency+ at or below +RARE_FREQ_MAX+). Both predicates need +crime.rb+ loaded.
#
# Memoized per +(include_rhymeless, common_only)+ flag combination (4 possible
# keys total) because the hot path in +bin/compute-relatedness+ calls
# +words_we_care_about(false, true)+ once per cue (~4000x per worker), and
# rebuilding the ~20k-element filtered list — which includes a
# +has_rhyming_word?+ pronunciations / rdict probe per candidate — dominated
# the per-cue overhead. +word_dict+ is loaded once and treated as immutable
# at runtime, so the memo is safe; dict-build scripts that mutate
# +word_dict+ do not call this function.
#
# The parent in +bin/compute-relatedness+ primes this memo before +fork+
# so all worker processes inherit the filled entry via copy-on-write instead
# of each rebuilding it from scratch.
$words_we_care_about_memo = {}
def words_we_care_about(include_rhymeless = true, common_only = false)
  cache_key = [include_rhymeless, common_only]
  cached = $words_we_care_about_memo[cache_key]
  return cached if cached

  keys = word_dict.keys
  keys |= WORDS_NEEDED_FOR_TESTING if defined?(WORDS_NEEDED_FOR_TESTING)
  keys = keys.uniq
  keys = keys.select { |w| has_rhyming_word?(w) } unless include_rhymeless
  keys = keys.reject { |w| rare?(w) } if common_only
  $words_we_care_about_memo[cache_key] = keys.freeze
end

# Returns UK spelling for a US (z) headword, or nil if not applicable.
def us_to_uk_ize_spelling(us_word)
  w = us_word.to_s
  return nil if w.empty?
  US_UK_YZE_SUFFIXES.each do |us_s, uk_s|
    next unless w.end_with?(us_s)
    return w[0...-us_s.length] + uk_s
  end
  return nil if US_UK_IZE_ZONLY_EXCEPTIONS.include?(w)
  US_UK_IZE_SUFFIXES.each do |us_s, uk_s|
    next unless w.end_with?(us_s)
    stem = w[0...-us_s.length]
    # Not *-isable (UK is "sizeable" with e, not "sisable").
    return "sizeable" if us_s == "izable" && stem == "siz"
    return stem + uk_s
  end
  nil
end

# Inverse of us_to_uk_ize_spelling (for matching a UK surface form); does not validate English.
def uk_to_us_ize_spelling(uk_word)
  w = uk_word.to_s
  return nil if w.empty?
  US_UK_YZE_SUFFIXES.each do |us_s, uk_s|
    next unless w.end_with?(uk_s)
    return w[0...-uk_s.length] + us_s
  end
  US_UK_IZE_SUFFIXES.each do |us_s, uk_s|
    next unless w.end_with?(uk_s)
    return w[0...-us_s.length] + us_s
  end
  nil
end

# [us_form, uk_form] with US first; nil if not an -ize/-ise pair we handle.
def us_uk_ize_pair(word)
  w = word.to_s
  return nil if w.empty?
  uk = us_to_uk_ize_spelling(w)
  if uk && uk != w
    return [w, uk]
  end
  us = uk_to_us_ize_spelling(w)
  # Require a pronounced US counterpart: rejects frequency-only ghosts like +expertize+ that
  # would otherwise be crowned the canonical form of a real word (+expertise+) and strand it
  # from every rime cohort.
  if us && us != w && word_dict_includes_pronounced_headword?(us) && us_to_uk_ize_spelling(us) == w
    return [us, w]
  end
  nil
end

# US/UK -or ↔ -our (behavior/behaviour, color/colour, …). Longest suffix first; both spellings
# must exist in +$word_dict+ (avoids tor/tour, for/four, contour, …).
US_UK_OR_SUFFIXES = [
  ["iors", "iours"],
  ["ior", "iour"],
  ["orites", "ourites"],
  ["oring", "ouring"],
  ["ored", "oured"],
  ["ors", "ours"],
  ["orite", "ourite"],
  ["orous", "ourous"],
  ["or", "our"],
].freeze

US_UK_OR_MIN_WORD_LENGTH = 5

def us_to_uk_or_spelling(us_word)
  w = us_word.to_s
  return nil if w.length < US_UK_OR_MIN_WORD_LENGTH
  US_UK_OR_SUFFIXES.sort_by { |us_s, _uk| [-us_s.length, us_s] }.each do |us_s, uk_s|
    next unless w.end_with?(us_s)
    return w[0...-us_s.length] + uk_s
  end
  nil
end

def uk_to_us_or_spelling(uk_word)
  w = uk_word.to_s
  return nil if w.length < US_UK_OR_MIN_WORD_LENGTH
  US_UK_OR_SUFFIXES.sort_by { |_us, uk_s| [-uk_s.length, uk_s] }.each do |us_s, uk_s|
    next unless w.end_with?(uk_s)
    return w[0...-uk_s.length] + us_s
  end
  nil
end

def us_uk_or_pair(word)
  w = word.to_s
  return nil if w.length < US_UK_OR_MIN_WORD_LENGTH
  uk = us_to_uk_or_spelling(w)
  if uk && uk != w && uk.length >= US_UK_OR_MIN_WORD_LENGTH && word_dict_includes_pronounced_headword?(w) && word_dict_includes_pronounced_headword?(uk) && uk_to_us_or_spelling(uk) == w
    return [w, uk]
  end
  us = uk_to_us_or_spelling(w)
  if us && us != w && us.length >= US_UK_OR_MIN_WORD_LENGTH && word_dict_includes_pronounced_headword?(w) && word_dict_includes_pronounced_headword?(us) && us_to_uk_or_spelling(us) == w
    return [us, w]
  end
  nil
end

# US/UK -er ↔ -re (center/centre, fiber/fibre, …). Longest suffix first; both spellings in +$word_dict+;
# stem before the matched suffix must end in a consonant and have length ≥ 3 (avoids acre/acer, etc.).
US_UK_ER_RE_SUFFIXES = [
  ["ering", "ring"],
  ["ered", "red"],
  ["ers", "res"],
  ["er", "re"],
].freeze

US_UK_ER_RE_MIN_WORD_LENGTH = 5

def us_to_uk_er_re_spelling(us_word)
  w = us_word.to_s
  return nil if w.length < US_UK_ER_RE_MIN_WORD_LENGTH
  US_UK_ER_RE_SUFFIXES.sort_by { |us_s, _uk| [-us_s.length, us_s] }.each do |us_s, uk_s|
    next unless w.end_with?(us_s)
    stem = w[0...-us_s.length]
    next unless stem.match?(/[bcdfghjklmnpqrstvwxyz]\z/i)
    next if stem.length < 3
    return stem + uk_s
  end
  nil
end

def uk_to_us_er_re_spelling(uk_word)
  w = uk_word.to_s
  return nil if w.length < US_UK_ER_RE_MIN_WORD_LENGTH
  US_UK_ER_RE_SUFFIXES.sort_by { |_us, uk_s| [-uk_s.length, uk_s] }.each do |us_s, uk_s|
    next unless w.end_with?(uk_s)
    stem = w[0...-uk_s.length]
    next unless stem.match?(/[bcdfghjklmnpqrstvwxyz]\z/i)
    next if stem.length < 3
    return stem + us_s
  end
  nil
end

def us_uk_er_re_pair(word)
  w = word.to_s
  return nil if w.length < US_UK_ER_RE_MIN_WORD_LENGTH
  uk = us_to_uk_er_re_spelling(w)
  if uk && uk != w && uk.length >= US_UK_ER_RE_MIN_WORD_LENGTH && word_dict_includes_pronounced_headword?(w) && word_dict_includes_pronounced_headword?(uk) && uk_to_us_er_re_spelling(uk) == w
    return [w, uk]
  end
  us = uk_to_us_er_re_spelling(w)
  if us && us != w && us.length >= US_UK_ER_RE_MIN_WORD_LENGTH && word_dict_includes_pronounced_headword?(w) && word_dict_includes_pronounced_headword?(us) && us_to_uk_er_re_spelling(us) == w
    return [us, w]
  end
  nil
end

# US/UK consonant-doubling before a vowel-initial suffix on verbs ending in -l
# (barreled/barrelled, traveling/travelling, modeler/modeller, marvelous/marvellous, counselor/
# counsellor, …). US keeps a single l; UK doubles it. The pseudo-base (word minus the vowel
# suffix, ending in a single l) must itself be a headword in +$word_dict+, which guards against
# silent-e collisions (filed/filled, tiled/tilled, smiled/smilled, …) and unrelated ll-words
# (called/caled, pulled/puled, boiled/boilled, …). As an extra safety belt the silent-e form
# (pseudo-base with the trailing l replaced by "e") must NOT be a headword; this rejects the
# rare cases where the naked pseudo-base happens to be in the dictionary but the "real" base
# is the silent-e verb (e.g. "til" exists but the derivation is from "tile").
US_UK_LL_VOWEL_SUFFIXES = %w[ing ers est ors ous ed er or].freeze

US_UK_LL_MIN_WORD_LENGTH = 6
US_UK_LL_MIN_PSEUDO_BASE_LENGTH = 3

# Parse +word+ as either the US or UK shape of an -l-/-ll- doubling pair. Returns
# [us_suffix_sliced_base_ending_in_single_l, matched_vowel_suffix] on match, nil otherwise.
# The returned base always ends in a single "l" (never "ll") and is at least
# +US_UK_LL_MIN_PSEUDO_BASE_LENGTH+ characters long.
def us_uk_ll_parse(word)
  w = word.to_s
  return nil if w.length < US_UK_LL_MIN_WORD_LENGTH
  US_UK_LL_VOWEL_SUFFIXES.sort_by { |s| [-s.length, s] }.each do |suf|
    next unless w.end_with?(suf)
    trunc = w[0...-suf.length]
    if trunc.end_with?("ll") && !trunc.end_with?("lll")
      pseudo_base = trunc[0...-1]
    elsif trunc.end_with?("l") && !trunc.end_with?("ll")
      pseudo_base = trunc
    else
      next
    end
    next if pseudo_base.length < US_UK_LL_MIN_PSEUDO_BASE_LENGTH
    return [pseudo_base, suf]
  end
  nil
end

# Reject (filed, filled)-style collisions where the "real" base is a silent-e verb rather than
# the naked pseudo-base ending in -l. See US_UK_LL_VOWEL_SUFFIXES comment for the full rationale.
def us_uk_ll_pseudo_base_acceptable?(pseudo_base)
  return false if pseudo_base.length < US_UK_LL_MIN_PSEUDO_BASE_LENGTH
  return false unless word_dict_includes_headword?(pseudo_base)
  return false if word_dict_includes_headword?(pseudo_base[0...-1] + "e")
  true
end

def us_uk_ll_pair(word)
  w = word.to_s
  return nil if w.length < US_UK_LL_MIN_WORD_LENGTH
  parsed = us_uk_ll_parse(w)
  return nil unless parsed
  pseudo_base, suf = parsed
  return nil unless us_uk_ll_pseudo_base_acceptable?(pseudo_base)

  us = pseudo_base + suf
  uk = pseudo_base + "l" + suf
  return nil if us == uk
  return nil unless word_dict_includes_pronounced_headword?(us) && word_dict_includes_pronounced_headword?(uk)

  [us, uk]
end

def us_uk_morphology_pair(word)
  us_uk_ize_pair(word) || us_uk_or_pair(word) || us_uk_er_re_pair(word) || us_uk_ll_pair(word)
end

def us_uk_morphology_variant_forms(word)
  pair = us_uk_morphology_pair(word)
  return nil unless pair
  u, k = pair
  k == u ? [u] : [u, k]
end

# Shape-only match of +word+ as the -oes or -os surface of an -o noun's plural. Returns
# [oes_form, os_form] when the pattern matches, nil otherwise. Used by the build-time
# corpus variant emitter (dict/corpus_variants.rb); runtime consumption of the resolved
# pairs goes through +variants()+ via the generated +spelling_variants_auto.txt+ so no
# corpus I/O leaks into the runtime path.
O_PLURAL_MIN_WORD_LENGTH = 4

def o_plural_candidate_pair(word)
  w = word.to_s
  return nil if w.length < O_PLURAL_MIN_WORD_LENGTH
  if w.end_with?("oes")
    os = w[0...-2] + "s" # "tomatoes" → "tomatos"
    return nil if os == w
    return [w, os]
  end
  if w.end_with?("os") && !w.end_with?("oos")
    oes = w[0...-1] + "es" # "tomatos" → "tomatoes"
    return nil if oes == w
    return [oes, w]
  end
  nil
end

# Fold for grouping hyphen-insensitive spellings (in-laws ↔ inlaws).
def spelling_variant_hyphen_fold(w)
  w.to_s.downcase.delete("-")
end

# Only folds with 2+ distinct surface forms (tiny hash vs. one entry per word).
VALID_HYPHEN_LEXEME_RE = /\A[[:alpha:]][[:alnum:]_'-]*\z/.freeze
NON_HYPHEN_PREF_RE = /\Anon-[[:alnum:]]/i.freeze

# First segment of phrasal-style hyphen compounds (in-laws, on-site, hand-out). Longest token first in the regex.
HYPHEN_COMPOUND_LEADING_PARTICLES = %w[down in off on out up].freeze
PARTICLE_HYPHEN_PREF_RE = Regexp.new(
  "\\A(?:#{HYPHEN_COMPOUND_LEADING_PARTICLES.sort_by { |t| [-t.length, t] }.join('|')})-[[:alpha:]]",
  Regexp::IGNORECASE
).freeze

# e.g. okey-dokey / low-key over okeydokey / lowkey when both are in the same hyphen fold.
REDUP_STYLE_SINGLE_HYPHEN_RE = /\A[[:alpha:]]{2,}-[[:alpha:]]{2,}\z/.freeze
# Second-segment matches here → prefer solid spelling (handout not hand-out). Omits +on+ (no common *-on tail).
HYPHEN_COMPOUND_TRAILING_PARTICLES_SOLID_PREF =
  (HYPHEN_COMPOUND_LEADING_PARTICLES - %w[on]).freeze

def hyphen_redup_prefers_hyphenated_form?(f)
  return false unless REDUP_STYLE_SINGLE_HYPHEN_RE.match?(f)
  left, right = f.split("-", 2)
  return false if COMMON_PREFIXES.include?(left.downcase)
  !HYPHEN_COMPOUND_TRAILING_PARTICLES_SOLID_PREF.include?(right.downcase)
end

def ingest_word_into_hyphen_fold_buckets!(buckets, w)
  return if w.nil? || w.empty?
  return unless w.match?(VALID_HYPHEN_LEXEME_RE)
  fold = w.downcase.delete("-")
  (buckets[fold] ||= Set.new) << w
end

# Build { fold => [form, ...] } only where multiple spellings share a fold.
# +explicit_word_keys+: enumerable of headwords (e.g. word_dict.keys) when building during dict.rb;
# otherwise uses +$word_dict+ or scans word_dict.txt (fallback when JSON cache is missing).
def build_hyphen_multi_fold_map(explicit_word_keys = nil)
  buckets = {}
  load_variants_raw.each do |forms|
    forms.each { |w| ingest_word_into_hyphen_fold_buckets!(buckets, w) }
  end
  if explicit_word_keys
    explicit_word_keys.each { |w| ingest_word_into_hyphen_fold_buckets!(buckets, w) }
  elsif defined?($word_dict) && $word_dict.is_a?(Hash) && !$word_dict.empty?
    $word_dict.each_key { |w| ingest_word_into_hyphen_fold_buckets!(buckets, w) }
  else
    path = generated_dict_path(WORD_DICT_FILENAME)
    if File.exist?(path)
      IO.foreach(path, encoding: "UTF-8") do |line|
        next if line =~ /\A;/ || line =~ /\A#/
        tok = line.split(",", 2).first
        next if tok.nil? || tok.empty?
        ingest_word_into_hyphen_fold_buckets!(buckets, tok.desanitize)
      end
    end
  end
  out = {}
  buckets.each do |fold, set|
    next if set.size < 2
    out[fold] = set.to_a.freeze
  end
  out.freeze
end

# +build_keys+: headwords used to discover fold groups (include rare spellings when pairing hyphen/solid variants).
# +exported_keys+: final lexicon; a fold is written only when at least one of its spellings remains exported.
def save_hyphen_variant_map!(build_keys, exported_keys: nil)
  exported_keys = build_keys if exported_keys.nil?
  map = build_hyphen_multi_fold_map(build_keys)
  in_export = exported_keys.to_set
  map = map.reject { |_fold, forms| forms.none? { |w| in_export.include?(w) } }
  ensure_generated_dict_dir!
  path = generated_dict_path_under_dict_dir(HYPHEN_VARIANT_MAP_FILENAME)
  sorted = {}
  map.keys.sort.each { |k| sorted[k] = map[k].sort }
  File.write(path, "#{JSON.generate(sorted)}\n", encoding: "UTF-8")
  puts "Wrote #{sorted.size} hyphen-variant folds to #{HYPHEN_VARIANT_MAP_FILENAME}"
end

# --- ConceptNet edge map build ---
# Source: conceptnet-assertions-5.7.0.csv.gz (CC-BY-SA 4.0). Resolved by conceptnet_assertions_gz_path:
#   CONCEPTNET_ASSERTIONS_GZ env (absolute path), then corpora/conceptnet/, corpora/, repo root,
#   then newest corpora/**/conceptnet-assertions*.csv.gz
# Kept relations: RelatedTo, Synonym, IsA, HasA, PartOf, UsedFor, CapableOf, AtLocation,
# Causes, HasProperty, HasSubevent, DerivedFrom, FormOf, SimilarTo, HasPrerequisite,
# HasContext, MannerOf, ReceivesAction, HasFirstSubevent, HasLastSubevent, DefinedAs
#
# Lemma list gzip when assertions exist: built by +ensure_conceptnet_lemma_cache_for_build!+ (dict-build) or
# setup.sh / bin/preprocess-conceptnet-lemma-cache. +conceptnet_headwords_intersecting+ aborts if cache still missing/stale.
# Path: CONCEPTNET_LEMMA_CACHE_GZ, else <repo>/generated/<assertions-basename>.en-kept-lemmas.txt.gz.
CONCEPTNET_ASSERTIONS_GZ = "conceptnet-assertions-5.7.0.csv.gz"
CONCEPTNET_KEEP_RELATIONS = %w[
  /r/RelatedTo /r/Synonym /r/IsA /r/HasA /r/PartOf /r/UsedFor /r/CapableOf
  /r/AtLocation /r/Causes /r/HasProperty /r/HasSubevent /r/DerivedFrom /r/FormOf
  /r/SimilarTo /r/HasPrerequisite /r/HasContext /r/MannerOf /r/ReceivesAction
  /r/HasFirstSubevent /r/HasLastSubevent /r/DefinedAs
].to_set.freeze
CONCEPTNET_KEEP_RELATION_INDEX = CONCEPTNET_KEEP_RELATIONS.each_with_object({}) { |r, h| h[r] = true }.freeze
CONCEPTNET_EN_NODE_RE = %r{\A/c/en/([a-z][a-z]*)\z}

# Fast /c/en/<ascii_lowercase_word> parse (same acceptance as +CONCEPTNET_EN_NODE_RE+); avoids MatchData in hot loops.
def conceptnet_en_lemma_from_uri(uri)
  return nil unless uri
  len = uri.bytesize
  return nil if len <= 6
  return nil unless uri.start_with?("/c/en/")
  w = uri.byteslice(6, len - 6)
  return nil if w.empty?
  w.each_byte.all? { |b| b >= 97 && b <= 122 } ? w : nil
end

# CMU-style compounds use hyphens; Numberbatch, ConceptNet /c/en/, etc. use underscores.
def hyphens_to_underscores(word)
  word.to_s.tr("-", "_")
end

# True if +dict_set+ contains this ConceptNet lemma spelling or the hyphenated CMU-style variant.
def conceptnet_dict_includes_lemma?(dict_set, cn_lemma)
  dict_set.include?(cn_lemma) || dict_set.include?(cn_lemma.tr("_", "-"))
end

# Headwords that are their own relatedness-export key: excludes inflected forms (keys of +lemma_map+).
def relatedness_export_base_headwords(all_headwords, lemma_map)
  all_headwords.reject { |w| lemma_map.key?(w) }
end

# Map a ConceptNet /c/en/ lemma to the spelling we store in relatedness artifacts when it matches
# our lexicon (otherwise returns +cn_lemma+ unchanged). Uses build-time +lemma_map+ like runtime +lemma+.
def relatedness_canonical_spelling_for_conceptnet_lemma(cn_lemma, dict_set, lemma_map)
  if dict_set.include?(cn_lemma)
    return lemma_map[cn_lemma] || cn_lemma
  end
  hy = cn_lemma.tr("_", "-")
  if dict_set.include?(hy)
    return lemma_map[hy] || hy
  end
  cn_lemma
end

def conceptnet_assertions_gz_path
  env = ENV["CONCEPTNET_ASSERTIONS_GZ"]
  return env if env && !env.empty? && File.file?(env)
  [
    File.join(REPO_ROOT, "corpora", "conceptnet", CONCEPTNET_ASSERTIONS_GZ),
    File.join(REPO_ROOT, "corpora", CONCEPTNET_ASSERTIONS_GZ),
    File.join(REPO_ROOT, CONCEPTNET_ASSERTIONS_GZ),
  ].each { |p| return p if File.file?(p) }
  [File.join(REPO_ROOT, "corpora", "conceptnet"), File.join(REPO_ROOT, "corpora"), REPO_ROOT].each do |dir|
    next unless Dir.exist?(dir)
    matches = Dir.glob(File.join(dir, "conceptnet-assertions*.csv.gz"))
    return matches.max_by { |p| File.mtime(p) } if matches.any?
  end
  nil
end

def conceptnet_lemma_cache_derived_gz_path(assertions_path)
  return nil unless assertions_path
  stem = File.basename(assertions_path).sub(/\.csv\.gz\z/i, "").sub(/\.gz\z/i, "")
  File.join(GENERATED_DIR, "#{stem}#{CONCEPTNET_LEMMA_CACHE_SUFFIX}")
end

# Canonical lemma-cache path (read + write): CONCEPTNET_LEMMA_CACHE_GZ if set, else under +GENERATED_DIR+.
def conceptnet_lemma_cache_output_gz_path(assertions_path = nil)
  assertions_path ||= conceptnet_assertions_gz_path
  return nil unless assertions_path
  env = ENV["CONCEPTNET_LEMMA_CACHE_GZ"]
  return env if env && !env.empty?
  conceptnet_lemma_cache_derived_gz_path(assertions_path)
end

def conceptnet_lemma_cache_usable?(assertions_gz, cache_gz)
  return false unless cache_gz && File.file?(cache_gz) && !File.zero?(cache_gz)
  return false unless assertions_gz && File.file?(assertions_gz)
  File.mtime(cache_gz) >= File.mtime(assertions_gz)
end

# Ensures generated lemma cache exists and is no older than assertions (dict-build entrypoint).
# setup.sh also runs bin/preprocess-conceptnet-lemma-cache after downloading assertions; this covers
# fresh clones and upgraded assertion files without a separate admin step.
def ensure_conceptnet_lemma_cache_for_build!
  gz = conceptnet_assertions_gz_path
  return unless gz

  cache = conceptnet_lemma_cache_output_gz_path(gz)
  abort "Could not derive ConceptNet lemma cache path for #{gz}" unless cache
  return if File.file?(cache) && conceptnet_lemma_cache_usable?(gz, cache)

  puts "ConceptNet lemma cache missing or stale; building #{cache} (long scan)…"
  build_conceptnet_lemma_cache!
end

# Loads lemma lines from a cache built by +build_conceptnet_lemma_cache!+ (skips # comments).
def conceptnet_lemma_vocab_load(cache_gz_path)
  require "zlib"
  s = Set.new
  Zlib::GzipReader.open(cache_gz_path, encoding: "UTF-8") do |gz|
    gz.each_line do |line|
      w = line.rstrip
      next if w.empty? || w.start_with?("#")
      s.add(w)
    end
  end
  s
end

def conceptnet_lemma_vocab_load_cached(cache_gz_path)
  mtime = File.mtime(cache_gz_path)
  memo = $conceptnet_lemma_vocab_memo
  if memo.is_a?(Hash) && memo[:path] == cache_gz_path && memo[:mtime] == mtime
    return memo[:set]
  end
  set = conceptnet_lemma_vocab_load(cache_gz_path)
  $conceptnet_lemma_vocab_memo = { path: cache_gz_path, mtime: mtime, set: set }
  set
end

# Yields each distinct English lemma pair (w1, w2), w1 != w2, on a kept relation (same rules as edge export).
def each_conceptnet_kept_en_en_lemma_pair(gz_path)
  return enum_for(:each_conceptnet_kept_en_en_lemma_pair, gz_path) unless block_given?

  keep = CONCEPTNET_KEEP_RELATION_INDEX
  require "zlib"
  Zlib::GzipReader.open(gz_path, encoding: "UTF-8") do |gz|
    gz.each_line do |line|
      next unless line.include?("/c/en/")
      parts = line.split("\t", 5)
      next if parts.length < 4
      next unless keep[parts[1]]
      w1 = conceptnet_en_lemma_from_uri(parts[2])
      w2 = conceptnet_en_lemma_from_uri(parts[3])
      next unless w1 && w2
      next if w1 == w2
      yield w1, w2
    end
  end
end

# One-time (or when upgrading ConceptNet): scan assertions gz and write sorted unique lemmas for fast dict builds.
def build_conceptnet_lemma_cache!(output_path: nil)
  assertions = conceptnet_assertions_gz_path
  raise "No conceptnet assertions .csv.gz found (set CONCEPTNET_ASSERTIONS_GZ=/path/to/file.gz)" unless assertions

  output_path ||= conceptnet_lemma_cache_output_gz_path(assertions)
  raise "Could not derive output path from #{assertions}" unless output_path

  vocab = Set.new
  edges = 0
  each_conceptnet_kept_en_en_lemma_pair(assertions) do |w1, w2|
    edges += 1
    print "." if (edges % 5_000_000).zero?
    vocab.add(w1)
    vocab.add(w2)
  end
  puts if edges >= 5_000_000

  sorted = vocab.to_a.sort!
  FileUtils.mkdir_p(File.dirname(output_path))
  require "zlib"
  Zlib::GzipWriter.open(output_path, Zlib::BEST_SPEED) do |gz|
    gz.puts "# RhymeCrime ConceptNet English lemmas (endpoints on kept relations, /c/en/<ascii_a-z> only)"
    gz.puts "# Built from: #{assertions}"
    sorted.each { |w| gz.puts(w) }
  end
  puts "Wrote #{sorted.size} lemmas from #{edges} edges to #{output_path}"
  output_path
end

# Subset of +dict_set+ that have a Numberbatch row (lowercase a-z and underscore in the embedding file).
def numberbatch_headwords_intersecting(dict_set)
  return Set.new if dict_set.nil? || dict_set.empty?
  txt_path = numberbatch_txt_path
  return Set.new unless txt_path
  by_nb = dict_set.group_by { |w| hyphens_to_underscores(w) }
  out = Set.new
  first = true
  File.foreach(txt_path, encoding: "UTF-8") do |line|
    if first
      first = false
      next
    end
    line = line.scrub
    sp = line.index(" ") || line.index("\t")
    next unless sp && sp.positive?
    token = line.byteslice(0, sp).scrub
    next unless token.match?(/\A[a-z][a-z_]*\z/)
    by_nb[token]&.each { |w| out.add(w) }
  end
  out
end

# Subset of +dict_set+ that appear as /c/en/… endpoints on a kept ConceptNet relation (same filter as edge export).
def conceptnet_headwords_intersecting(dict_set)
  return Set.new if dict_set.nil? || dict_set.empty?
  gz_path = conceptnet_assertions_gz_path
  return Set.new unless gz_path

  cache_path = conceptnet_lemma_cache_output_gz_path(gz_path)
  unless cache_path
    abort "ConceptNet lemma cache path could not be derived for assertions: #{gz_path}"
  end
  unless File.file?(cache_path)
    abort <<~MSG
      ConceptNet lemma cache missing (required for dict-build):
        #{cache_path}
      Run once from repo root:
        ./bin/preprocess-conceptnet-lemma-cache
    MSG
  end
  unless conceptnet_lemma_cache_usable?(gz_path, cache_path)
    abort <<~MSG
      ConceptNet lemma cache is older than the assertions file (required):
        cache: #{cache_path}
        assertions: #{gz_path}
      Re-run:
        ./bin/preprocess-conceptnet-lemma-cache
    MSG
  end

  vocab = conceptnet_lemma_vocab_load_cached(cache_path)
  puts "Using ConceptNet lemma cache #{cache_path} (#{vocab.size} lemmas) for headword intersection"
  dict_set.each_with_object(Set.new) do |w, out|
    out.add(w) if vocab.include?(hyphens_to_underscores(w))
  end
end

# Path of the pre-canonicalization edges cache derived from +assertions_path+.
def conceptnet_edges_cache_derived_path(assertions_path)
  return nil unless assertions_path
  stem = File.basename(assertions_path).sub(/\.csv\.gz\z/i, "").sub(/\.gz\z/i, "")
  File.join(GENERATED_DIR, "#{stem}#{CONCEPTNET_EDGES_CACHE_SUFFIX}")
end

# Stable signature of the kept-relations set; embedded in the cache header so the cache invalidates
# when the set changes (rebuilding with a wider/narrower keep list otherwise risks silent staleness).
def conceptnet_keep_relations_signature
  require "digest/sha1"
  Digest::SHA1.hexdigest(CONCEPTNET_KEEP_RELATION_INDEX.keys.sort.join(","))
end

def conceptnet_edges_cache_usable?(assertions_gz, cache_path)
  return false unless cache_path && File.file?(cache_path) && !File.zero?(cache_path)
  return false unless assertions_gz && File.file?(assertions_gz)
  File.mtime(cache_path) >= File.mtime(assertions_gz)
end

# Streaming scan of +assertions_gz+ → +cache_path+ msgpack.gz with all kept English-English edges as
# pre-canonicalization triples (w1, w2, weight) where w1 < w2. Output is a pure function of the
# assertions file + +CONCEPTNET_KEEP_RELATIONS+, so it survives across dict builds that vary only in
# +word_dict+. Header records the keep-relations signature so a relation-set change forces a rescan.
def build_conceptnet_filtered_edges_cache!(assertions_gz, cache_path)
  require 'zlib'
  keep = CONCEPTNET_KEEP_RELATION_INDEX
  triples = {}
  lines = 0
  Zlib::GzipReader.open(assertions_gz, encoding: "UTF-8") do |gz|
    gz.each_line do |line|
      lines += 1
      print "." if lines % 5_000_000 == 0
      next unless line.include?("/c/en/")
      parts = line.split("\t", 5)
      next if parts.length < 5
      next unless keep[parts[1]]
      w1 = conceptnet_en_lemma_from_uri(parts[2])
      w2 = conceptnet_en_lemma_from_uri(parts[3])
      next unless w1 && w2
      next if w1 == w2
      weight = begin
        JSON.parse(parts[4])["weight"] || 1.0
      rescue
        1.0
      end
      a, b = (w1 < w2) ? [w1, w2] : [w2, w1]
      key = "#{a}\x00#{b}"
      prev = triples[key]
      triples[key] = weight if prev.nil? || weight > prev
    end
  end
  FileUtils.mkdir_p(File.dirname(cache_path))
  Zlib::GzipWriter.open(cache_path) do |gz|
    packer = MessagePack::Packer.new(gz)
    packer.pack({
      "version" => 1,
      "keep_signature" => conceptnet_keep_relations_signature,
      "n_triples" => triples.size,
    })
    triples.each do |key, weight|
      a, b = key.split("\x00", 2)
      packer.pack(a)
      packer.pack(b)
      packer.pack(weight)
    end
    packer.flush
  end
  puts "\nwrote ConceptNet filtered-edges cache #{cache_path} (#{triples.size} triples)"
  triples.size
end

# Yields each +[w1, w2, weight]+ from a previously built cache. Returns +nil+ if the cache's
# +keep_signature+ doesn't match current +CONCEPTNET_KEEP_RELATIONS+ (so the caller falls back to
# rebuilding); returns the triple count on success.
def each_conceptnet_cached_edge(cache_path)
  return enum_for(:each_conceptnet_cached_edge, cache_path) unless block_given?
  require 'zlib'
  Zlib::GzipReader.open(cache_path) do |gz|
    unpacker = MessagePack::Unpacker.new(gz)
    header = unpacker.read
    unless header.is_a?(Hash) && header["keep_signature"] == conceptnet_keep_relations_signature
      return nil
    end
    n = header["n_triples"].to_i
    n.times do
      w1 = unpacker.read
      w2 = unpacker.read
      weight = unpacker.read
      yield w1, w2, weight
    end
    n
  end
end

def save_conceptnet_edge_map!(full_word_dict_keys, lemma_map)
  gz_path = conceptnet_assertions_gz_path
  unless gz_path
    puts "Skipping ConceptNet edge map: no conceptnet-assertions*.csv.gz under #{File.join(REPO_ROOT, 'corpora')} or repo root (set CONCEPTNET_ASSERTIONS_GZ=/path/to/file.gz)"
    return
  end
  cache_path = conceptnet_edges_cache_derived_path(gz_path)
  unless cache_path && conceptnet_edges_cache_usable?(gz_path, cache_path)
    puts "ConceptNet filtered-edges cache missing or stale; building #{cache_path} (long scan)…"
    build_conceptnet_filtered_edges_cache!(gz_path, cache_path)
  end

  dict_set = full_word_dict_keys.to_set
  edges = {}
  accumulate = lambda do |w1, w2, weight|
    next unless conceptnet_dict_includes_lemma?(dict_set, w1) || conceptnet_dict_includes_lemma?(dict_set, w2)
    c1 = relatedness_canonical_spelling_for_conceptnet_lemma(w1, dict_set, lemma_map)
    c2 = relatedness_canonical_spelling_for_conceptnet_lemma(w2, dict_set, lemma_map)
    u1 = hyphens_to_underscores(c1)
    u2 = hyphens_to_underscores(c2)
    next if u1 == u2
    key = [u1, u2].sort.join("|")
    edges[key] = weight if weight > (edges[key] || 0)
  end

  used_cache = each_conceptnet_cached_edge(cache_path, &accumulate)
  if used_cache.nil?
    puts "ConceptNet filtered-edges cache had stale keep-relations signature; rebuilding"
    build_conceptnet_filtered_edges_cache!(gz_path, cache_path)
    edges.clear
    each_conceptnet_cached_edge(cache_path, &accumulate)
  end

  ensure_generated_dict_dir!
  path = generated_dict_path_under_dict_dir(CONCEPTNET_EDGES_FILENAME)
  File.write(path, JSON.generate(edges), encoding: "UTF-8")
  puts "Wrote #{edges.size} ConceptNet edges to #{CONCEPTNET_EDGES_FILENAME}"
end

# --- Numberbatch vector build ---
# Source: numberbatch-en-19.08.txt (CC-BY-SA 4.0, pre-normalized). Resolved by numberbatch_txt_path:
#   NUMBERBATCH_TXT env (absolute path), then corpora/numberbatch/, corpora/, repo root,
#   then newest corpora/**/numberbatch*.txt
NUMBERBATCH_TXT = "numberbatch-en-19.08.txt"

def numberbatch_txt_path
  env = ENV["NUMBERBATCH_TXT"]
  return env if env && !env.empty? && File.file?(env)
  [
    File.join(REPO_ROOT, "corpora", "numberbatch", NUMBERBATCH_TXT),
    File.join(REPO_ROOT, "corpora", NUMBERBATCH_TXT),
    File.join(REPO_ROOT, NUMBERBATCH_TXT),
  ].each { |p| return p if File.file?(p) }
  [File.join(REPO_ROOT, "corpora", "numberbatch"), File.join(REPO_ROOT, "corpora"), REPO_ROOT].each do |dir|
    next unless Dir.exist?(dir)
    matches = Dir.glob(File.join(dir, "numberbatch*.txt"))
    return matches.max_by { |p| File.mtime(p) } if matches.any?
  end
  nil
end

# First-column headword tokens in the Numberbatch embedding file (underscore spelling, /c/en/-style).
def numberbatch_corpus_token_set(txt_path)
  s = Set.new
  first = true
  File.foreach(txt_path, encoding: "UTF-8") do |line|
    if first
      first = false
      next
    end
    line = line.scrub
    sp = line.index(" ") || line.index("\t")
    next unless sp && sp.positive?

    token = line.byteslice(0, sp).scrub
    next unless token.match?(/\A[a-z][a-z_]*\z/)

    s.add(token)
  end
  s
end

# Cue and single-token target spellings from USF Cue_Target_Pairs shards under corpora/usf/.
def usf_corpus_word_set
  dir = File.join(REPO_ROOT, "corpora", "usf")
  s = Set.new
  return s unless Dir.exist?(dir)

  Dir.glob(File.join(dir, "Cue_Target_Pairs.*")).sort.each do |path|
    File.foreach(path, encoding: "UTF-8") do |line|
      line = line.scrub
      next if line.include?("CUE,")
      next unless line.match?(/\A[A-Z]/)

      parts = line.split(",", 3)
      next if parts.length < 2

      cue = parts[0]
      target = parts[1]
      next unless cue && target

      s.add(cue.strip.downcase)
      ts = target.strip.downcase
      s.add(ts) if ts.match?(/\A[a-z][a-z0-9'-]*\z/)
    end
  end
  s
end

# ConceptNet English lemma vocabulary for attestation checks; nil if assertions/cache unavailable.
def conceptnet_lemma_vocab_for_attestation
  gz_path = conceptnet_assertions_gz_path
  return nil unless gz_path

  cache_path = conceptnet_lemma_cache_output_gz_path(gz_path)
  return nil unless cache_path && File.file?(cache_path)
  return nil unless conceptnet_lemma_cache_usable?(gz_path, cache_path)

  conceptnet_lemma_vocab_load_cached(cache_path)
end

def save_numberbatch_vectors!(word_keys)
  txt_path = numberbatch_txt_path
  unless txt_path
    puts "Skipping Numberbatch vectors: no numberbatch*.txt under #{File.join(REPO_ROOT, 'corpora')} or repo root (set NUMBERBATCH_TXT=/path/to/file.txt)"
    return
  end
  dict_set = word_keys.to_set
  dict_by_nb = dict_set.group_by { |w| hyphens_to_underscores(w) }
  vectors = {}
  first = true
  File.foreach(txt_path, encoding: "UTF-8") do |line|
    if first
      first = false
      next
    end
    line = line.scrub
    parts = line.rstrip.split(" ")
    word = parts[0]&.scrub
    next unless word&.match?(/\A[a-z][a-z_]*\z/)
    next unless dict_by_nb[word]
    vec = parts[1..].map(&:to_f)
    mag = Math.sqrt(vec.sum { |v| v * v })
    next if mag == 0
    vec.map! { |v| (v / mag).round(5) }
    vectors[word] = vec
  end
  ensure_generated_dict_dir!
  path = generated_dict_path_under_dict_dir(NUMBERBATCH_VECTORS_FILENAME)
  File.binwrite(path, vectors.to_msgpack)
  size_mb = File.size(path) / 1024.0 / 1024.0
  puts "Wrote #{vectors.size} Numberbatch vectors to #{NUMBERBATCH_VECTORS_FILENAME} (#{size_mb.round(1)} MB)"
end

def load_hyphen_multi_fold_map_from_disk
  path = generated_dict_path(HYPHEN_VARIANT_MAP_FILENAME)
  return nil unless File.exist?(path)
  raw = JSON.parse(File.read(path, encoding: "UTF-8"))
  out = {}
  raw.each do |fold, arr|
    out[fold] = arr.freeze
  end
  out.freeze
rescue JSON::ParserError, SystemCallError
  nil
end

def hyphen_multi_fold_map
  @hyphen_multi_fold ||= (load_hyphen_multi_fold_map_from_disk || build_hyphen_multi_fold_map)
end

def preferred_among_hyphen_equivalents(forms)
  n = forms.length
  return forms[0] if n <= 1
  nons = []
  i = 0
  while i < n
    f = forms[i]
    nons << f if NON_HYPHEN_PREF_RE.match?(f)
    i += 1
  end
  return nons.min if nons.any?
  parts = []
  i = 0
  while i < n
    f = forms[i]
    parts << f if PARTICLE_HYPHEN_PREF_RE.match?(f)
    i += 1
  end
  return parts.min if parts.any?
  redups = []
  i = 0
  while i < n
    f = forms[i]
    redups << f if hyphen_redup_prefers_hyphenated_form?(f)
    i += 1
  end
  return redups.min if redups.any?
  forms.min_by { |f| [f.count("-"), f.downcase] }
end

def preferred_form(word)
  vf = variants[word]
  if vf
    dict_utils_debug "The preferred form of '#{word}' is '#{vf[0]}'" unless vf[0] == word
    return vf[0]
  end
  morph = us_uk_morphology_pair(word)
  if morph
    return morph[0]
  end
  forms = hyphen_multi_fold_map[spelling_variant_hyphen_fold(word)]
  return word if forms.nil? || forms.length < 2
  preferred_among_hyphen_equivalents(forms)
end

# Like +preferred_form+, but US/UK / hyphen resolution consults +word_dict+ (the build-time hash) via
# +$word_dict+ so rime-bucket pruning sees the correct preferred surface before export.
def preferred_form_in_build_lexicon(word, word_dict)
  previous = $word_dict
  $word_dict = word_dict
  preferred_form(word)
ensure
  $word_dict = previous
end

def all_forms(word)
  vf = variants[word]
  forms = hyphen_multi_fold_map[spelling_variant_hyphen_fold(word)]
  forms = nil if forms.nil? || forms.length < 2
  morph = us_uk_morphology_variant_forms(word)
  if vf
    unless forms
      if morph
        merged = vf.dup
        morph.each { |x| merged << x unless merged.include?(x) }
        return merged.uniq
      end
      return vf
    end
    merged = vf.dup
    morph&.each { |x| merged << x unless merged.include?(x) }
    forms.each { |x| merged << x unless merged.include?(x) }
    return merged.uniq
  end
  if morph
    unless forms
      return morph
    end
    merged = morph.dup
    forms.each { |x| merged << x unless merged.include?(x) }
    return merged.uniq
  end
  if forms
    pref = preferred_among_hyphen_equivalents(forms)
    rest = forms.reject { |w| w == pref }.sort
    return [pref] + rest
  end
  [word]
end

SPELLING_CSV_PATH = File.join(CURATED_DIR, "spelling.csv")

# A spelling.csv column counts as a word-form (rather than a free-text notes value)
# when it consists entirely of letters, hyphens, and apostrophes (e.g. +color+,
# +'til+, +rock'n'roll+, +acknowledgement+). Anything containing whitespace, digits,
# +#+, or other punctuation is treated as the start of the optional notes column.
SPELLING_CSV_FORM_RE = /\A['[:alpha:]][[:alpha:]'\-]*\z/

# Split a comma-separated spelling.csv row into [forms, notes_or_nil].
# Forms are stripped and consumed left-to-right until the first column that does
# not look like a word-form (per +SPELLING_CSV_FORM_RE+); from there to end-of-line
# is the notes payload, rejoined with commas so embedded commas inside notes survive.
def split_spelling_row(line)
  raw = line.split(",")
  forms = []
  notes_start = nil
  raw.each_with_index do |col, i|
    stripped = col.strip
    if stripped.empty?
      forms << stripped # let downstream strip empties; an early empty stays a column boundary
      next
    end
    if stripped =~ SPELLING_CSV_FORM_RE
      forms << stripped
    else
      notes_start = i
      break
    end
  end
  forms = forms.reject(&:empty?)
  notes = notes_start ? raw[notes_start..].join(",").strip : nil
  [forms, notes]
end

# Returns an array of form-arrays: each inner array is +[preferred, alt1[, alt2, ...]]+.
# Sources, in load order (later sources OVERRIDE earlier ones because +load_variants+
# does last-write-wins per surface form):
#   * +generated/spelling_variants_auto.txt+ — emitted by dict-build, whitespace-separated
#                                   +preferred alt+ pairs. Optional (skipped when missing,
#                                   e.g. on a fresh checkout before the first build).
#   * +curated/spelling.csv+     — hand-edited list, CSV (comma-separated) with +#+ comment
#                                   header lines and an optional trailing free-text notes
#                                   column (silently dropped at load time; see
#                                   +split_spelling_row+).
# Curated MUST come last: detectors in +emit_spelling_variants_auto!+ sometimes pick the
# opposite preference direction from the human-curated list (corpus Zipf can favor +adapter+
# over +adaptor+, +ax+ over +axe+, +disc+ over +disk+, +mamma+ over +mama+) and we want the
# hand-edited choice to win for any pair that appears in both files.
#
# Comment lines (starting with +#+) and lines that don't begin with an alphabetic character
# are skipped at parse time, matching the legacy +/A[[:alpha:]]/+ filter.
def load_variants_raw
  result = []
  auto_path = generated_dict_path(SPELLING_VARIANTS_AUTO_FILENAME)
  if File.exist?(auto_path)
    File.foreach(auto_path, chomp: true, encoding: "UTF-8") do |line|
      next unless line =~ /\A[[:alpha:]]/
      forms = line.split.map(&:strip).reject(&:empty?)
      result << forms unless forms.empty?
    end
  end
  File.foreach(SPELLING_CSV_PATH, chomp: true, encoding: "UTF-8") do |line|
    next unless line =~ /\A[[:alpha:]]/
    forms, _notes = split_spelling_row(line)
    result << forms unless forms.empty?
  end
  result
end

def load_variants
  hash = {}
  load_variants_raw.each do |forms|
    forms.each { |word| hash[word] = forms }
  end
  hash
end

#
# prefixes (crime.rb prefix_words; dict.rb syllabification). Order: longer before shorter where one
# contains another (+inter+ before +in+). Overlaps +HYPHEN_COMPOUND_LEADING_PARTICLES+ only on +in+,
# +out+, +up+ — those serve different rules; do not merge arrays without checking both call sites.
#

COMMON_PREFIXES = [
  'a',       # privative (atonal, asexual, achromatic, abiotic) and locative (aflame, ashore,
             # around, aground, abuzz). Accepts splash damage on words that merely start with
             # +a+ (ajar/jar, acorn/corn, amid/mid, ahead/head, abut/but, avoid/void, ado/do,
             # abasement/basement...) -- those cases live in the +unless they're not
             # derivationally related+ spec subcontext which is currently skipped.
  'along',   # alongside
  'an',
  'ante',
  'anti',
  'arch',
  'auto',
  'be',      # beside, below, become (splash damage on between/tween etc.)
  'bi',
  'co',
  'com',
  'con',
  'contra',
  'de',
  'dis',
  'disen',   # compound dis- + en- (disenchanted → chanted). Recursive prefix stripping
             # would be more principled but regresses +served+/+undeserved+ (un+de+served),
             # so enumerate attested compounds instead.
  'down',    # downwind, downhill, downstream
  'east',
  'en',
  'endo',    # endothermic → thermic
  'ex',
  'exo',     # exothermic → thermic
  'extra',
  'hetero',
  'homeo',
  'homo',
  'hyper',
  'il',      # illegal, illicit, illogical
  'im',      # impure, impolite (splash damage on peach/impeach etc.)
  'in',
  'inter',
  'intra',
  'macro',
  'micro',
  'mid',
  'mis',
  'mono',
  'multi',   # multimillionaire/millionaire, multinational/national, multipurpose/purpose,
             # multitask/task, multiform/form, multiplex/plex. Splash damage on words that
             # merely start with +multi+ but aren't morphological derivations (none observed
             # so far — opaque uses like +multiply+/+ply+ collapse correctly here too since
             # they ARE etymologically prefixed and we don't want them paired as rhymes).
  'non',
  'north',
  'off',
  'omni',
  'out',
  'over',
  'post',
  'pre',
  'pseudo',  # pseudoscience/science etc.
  'pro',
  're',
  'south',
  'sub',
  'super',
  'sym',
  'syn',
  'tele',
  'teleo',   # teleological → logical (tele → ological wouldn't match)
  'trans',
  'tri',
  'un',
  'under',
  'uni',
  'up',
]

#
# consonant clusters and syllabification
#

ALL_INITIAL_CONSONANT_CLUSTERS = [
  'B L', # blue
  'B R', # bread
  'B W', # bueno
  'B Y', # bugle
  'F Y', # few
  'D R', # draw
  'D W', # dwell
  'D Y', # due(1)
  'F L', # flaw
  'F R', # free
  'G L', # glow
  'G R', # grow
  'G W', # guava
  'HH Y', # hue
  'K L', # claw
  'K R', # crow
  'K W', # quick
  'K Y', # cue
  'M Y', # mute
  'P L', # play
  'P R', # pray
  'P W', # pueblo
  'P Y', # pupil
  'S F', # sphere
  'S K', # sky
  'S K L', # sclera
  'S K R', # scrub
  'S K W', # squall
  'S K Y', # skew
  'S P Y', # spume
  'S L', # sled
  'S M', # small
  'S N', # snow
  'S P', # speech
  'S P L', # split
  'S P R', # spray
  'S T', # stay
  'S T R', # straw
  'S W', # sway
  'SH L', # schlock
  'SH M', # schmooze
  'SH R', # shred
  'SH T', # schtick
  'SH W', # schwa
  'T R', # tree
  'T W', # twig
  'TH R', # throw
  'TH W', # thwack
  'V Y', # view
  'JH W', # joie (ʒw — merged with JH cluster inventory)
] # ARPABET format. source: John Algeo, https://www.tandfonline.com/doi/pdf/10.1080/00437956.1978.11435661 + original work

# Onset clusters legal only at the true start of a word (forward order). Not consulted for medial
# syllabification, so e.g. L AY1 V L IY0 (lively) keeps V in the preceding coda instead of merging V+L.
WORD_INITIAL_CONSONANT_CLUSTERS = [
  'V L', # Vlad, Vladimir; Slavic Vl- names
].freeze

ALL_FINAL_CONSONANT_CLUSTERS = [
  'B D', # grabbed
  'B Z', # cubs
  'CH T', # patched
  'D TH', # width
  'D TH S', # widths
  'D S T', # midst, rare
  'D Z', # adze
  'DH D', # clothed
  'DH Z', # clothes
  'F S', # graphs
  'F T', # soft
  'F T S', # lifts
  'F TH', # fifth
  'F TH S', # fifths
  'G D', # bogged
  'G Z', # eggs
  'JH D', # bulged
  'K S', # fix
  'K S T', # fixed
  'K S T S', # texts
  'K T', # act
  'K T S', # acts
  'L B', # bulb
  'L B Z', # bulbs
  'L CH', # belch
  'L CH T', # belched
  'L D', # build
  'L D Z', # builds
  'L F', # gulf
  'L F S', # gulfs
  'L F T', # engulfed
  'L F TH', # twelfth, rare
  'L F TH S', # twelfths, rare
  'L JH', # bulge
  'L JH D', # bulged
  'L K', # silk
  'L K S', # silks
  'L K T', # milked
  'L M', # film
  'L M D', # filmed
  'L M Z', # films
  'L N', # kiln, rare
  'L N Z', # kilns, rare
  'L P', # help
  'L P S', # helps
  'L P T', # helped
  'L P T S', # sculpts, rare
  'L S', # else
  'L S T', # pulsed
  'L T', # salt
  'L T S', # salts
  'L TH', # wealth
  'L TH S', # wealths
  # 'L TH T', # wealthed? theoretically possible, but doesn't occur
  'L V', # valve
  'L V D', # solved
  'L V Z', # valves
  'L Z', # feels
  'M D', # framed
  'M F', # triumph
  'M F S', # triumphs
  'M F T', # triumphed
  'M P', # jump
  'M P S', # jumps
  'M P S T', # glimpsed
  'M P T', # jumped
  'M P T S', # tempts
  'M T', # dreamt
  'M Z', # dooms
  'N CH', # punch
  'N CH T', # punched
  'N D', # send
  'N D Z', # sends
  'N JH', # change
  'N JH D', # changed
  'N S', # fence
  'N S T', # fenced
  'N T', # cent
  'N T S', # cents
  'N T S T', # incensed (?)
  'N TH', # tenth
  'N TH S', # tenths
  # 'N TH T', # tenthed? theoretically possible, but doesn't occur
  'N Z', # bronze
  'N Z D', # bronzed
  'NG D', # wronged
  'NG K', # ink
  'NG K S', # inks
  'NG K T', # inked
  'NG K T S', # instincts
  'NG K TH', # length
  'NG K TH S', # lengths
  # 'NG TH T', # lengthed? theoretically possible, but doesn't occur
  'NG Z', # things
  'P S', # lapse
  'P S T', # lapsed
  'P T', # apt
  'P T S', # opts
  'P TH', # depth
  'P TH S', # depths
  'R B', # curb
  'R B D', # curbed
  'R B Z', # curbs
  'R CH T', # arched
  'R CH', # arch
  'R D', # beard
  'R D Z', # beards
  'R DH Z', # berths
  'R F', # scarf
  'R F S', # scarfs
  'R F T', # scarfed
  'R G', # morgue
  # 'R G D', # morgued? theoretically possible, but doesn't occur
  'R G Z', # morgues
  'R JH', # merge
  'R JH D', # merged
  'R K', # mark
  'R K T', # marked
  'R K S', # marks
  'R L D', # world
  'R L D Z', # worlds
  'R L', # curl
  'R L Z', # curls
  'R M', # storm
  'R M D', # stormed
  'R M TH', # warmth
  # 'R M TH S', # warmths? theoretically possible, but doesn't occur
  'R M Z', # storms
  'R N', # earn
  'R N D', # earned
  'R N T', # burnt
  'R N Z', # burns
  'R P', # harp
  'R P S', # harps
  'R P T', # excerpt
  'R P T S', # excerpts
  'R S', # force
  'R S T', # forced
  'R S T S', # bursts
  'R SH', # marsh
  'R SH T', # borscht
  'R T', # part
  'R T S', # parts
  'R TH', # north
  'R TH S', # births
  'R TH T', # unearthed, rare
  'R V', # curve
  'R V D', # curved
  'R V Z', # curves
  'R Z', # furs
  'S K', # mask
  'S K S', # masks
  'S K T', # masked
  'S P', # clasp
  'S P S', # clasps
  'S P T', # clasped
  'S T', # chest
  'S T S', # chests
  'SH T', # mashed
  'T S', # eats
  'T S T', # blitzed
  'TH S', # breaths
  'TH T', # bequeathed
  'V D', # caved
  'V Z', # drives
  'Z D', # dozed
] # ARPABET format. source: John Algeo, https://www.tandfonline.com/doi/pdf/10.1080/00437956.1978.11435661 + original work (+JH D+ covers camouflaged)

# Words with weird initial/final consonant clusters that should be included anyway
WHITELIST = [
  'dvorak',
  'neuroscience',
  'neuroscientist',
  'nyet',
  'sbarro',
  'schneider',
  'svelte',
  'tsetse',
  'tsunami',
  'vlad',
  'vladimir',
  'vroom',
  'voila',
  'zloty',
  'zlotys',
]

#
# file utilities
#

def load_string_hash(filename)
  # each line is of the form:
  # KEY  STRING1 STRING2 ...
  # substitutes "_" with " " in keys after loading
  hash = Hash.new # hash of strings
  File.foreach(filename, encoding: "UTF-8") do |line|
    if useful_line?(line)
      tokens = line.split
      key = tokens.shift # now TOKENS contains only the value strings
      key = key.sanitize
      hash[key] = tokens.map { |str| str.desanitize }
    else
      dict_utils_debug "Ignoring #{filename} line: #{line}"
    end
  end
  dict_utils_debug "Loaded #{hash.length} entries from #{filename}"
  hash
end
def save_string_hash(hash, filename, header="")
  # sanitizes spaces into underscores
  FileUtils.mkdir_p(File.dirname(filename))
  @fh = File.open(filename, "w", encoding: "UTF-8")
  unless header.empty?
    @fh.puts(header)
  end
  hash.each do |key, values|
    key = key.sanitize
    @fh.print "#{key} "
    for value in values do
      value = value.sanitize
      @fh.print " #{value}"
    end
    @fh.puts
  end
  @fh.close
end

def useful_line?(line)
  # ignore entries that start with ; or #
  return !(line =~ /\A;/ || line =~ /\A#/)
end

#
# pronunciation lists (dict build + load)
#

# Appends PRON to PRONS unless an equal Pronunciation is already present.
def push_pronunciation_unless_duplicate!(prons, pron)
  return if prons.any? { |existing| existing == pron }
  prons.push(pron)
end

# Returns a new array with duplicate pronunciations removed (first occurrence kept).
def dedupe_pronunciations(prons)
  result = []
  prons.each { |p| push_pronunciation_unless_duplicate!(result, p) }
  result
end

#
# word info dictionary
#

def load_word_dict()
  pathname = generated_dict_path(WORD_DICT_FILENAME)
  unless File.exist?(pathname)
    die "First run ./bin/dict-build to populate #{GENERATED_DIR}/"
  end
  word_dict = Hash.new
  File.foreach(pathname, encoding: "UTF-8") do |line|
    next unless useful_line?(line)

    parts = line.chomp.split(",", 4)
    word = parts[0].desanitize
    freq = parts[1].to_i
    pronunciations_str = parts[2] || ""
    lemma_raw = parts[3]
    prons = Array.new
    pronunciation_strings = pronunciations_str.split("|")
    for pronstr in pronunciation_strings
      phonemes = pronstr.split(" ")
      pron = Pronunciation.new(phonemes)
      push_pronunciation_unless_duplicate!(prons, pron)
    end
    lemma = (lemma_raw && !lemma_raw.strip.empty?) ? lemma_raw.strip.desanitize : word
    word_info = [freq, prons, lemma]
    word_dict[word] = word_info
  end
  clear_spelling_variant_hyphen_caches!
  $lemma_to_words = nil
  $word_to_lemma = nil
  $word_to_semantic_base = nil
  $thematically_related_memo = nil
  word_dict
end

# Overridden in +crime.rb+ for DynamoDB mode (+lexicon_word_entry+).
def lexicon_word_entry(word)
  word_dict[word]
end

# Flat +{word => lemma}+ lookup loaded from +WORD_LEMMA_MAP_FILENAME+ (built by
# dict-build). Only stores +word != lemma+ pairs to keep the file small
# (~40% of headwords have a non-self lemma); every missing key means "lemma
# is the word itself", matching the nil-collapse rule in +save_word_dict+ and
# +lexicon_word_entry+. A +false+ sentinel means "already checked and the
# file isn't on disk" — avoids re-stat'ing on every +lemma+ call.
#
# Must stay a top-level global (not a module constant) so +load_word_dict+
# can reset it as part of its invalidation handshake.
$word_to_lemma = nil
def load_word_to_lemma!
  path = generated_dict_path(WORD_LEMMA_MAP_FILENAME)
  $word_to_lemma = File.exist?(path) ? MessagePackUtils.load_and_unpack(path) : false
end

# Hot-path inner loop for +RelatedWords+ pair lookups (called thousands of
# times per page render while coloring +set_related+ tuples). The +$word_to_
# lemma+ global is checked inline rather than via a helper method so the
# common warm-path case is one Hash lookup plus one nil check, not two method
# dispatches. The +lexicon_word_entry+ fallback only fires when the msgpack
# hasn't been generated yet (pre-dict-build checkout).
def lemma(word)
  map = $word_to_lemma
  load_word_to_lemma! if map.nil?
  map = $word_to_lemma
  if map
    m = map[word]
    return m || word
  end
  entry = lexicon_word_entry(word)
  return word unless entry
  entry[2] || word
end

# Lazy +$word_to_semantic_base+ load mirroring +load_word_to_lemma!+. Map keys
# are self-lemmas (lookup composes +lemma(w)+ first), values are derivational
# roots. Missing on disk → +false+ sentinel so subsequent +semantic_base+ calls
# don't re-stat the file. Reset by +load_word_dict+ when the dictionary is
# reloaded.
$word_to_semantic_base = nil
def load_word_to_semantic_base!
  path = generated_dict_path(WORD_SEMANTIC_BASE_MAP_FILENAME)
  $word_to_semantic_base = File.exist?(path) ? MessagePackUtils.load_and_unpack(path) : false
end

# Hot path for relatedness lookups (R3). Returns the derivational root when
# WordNet pointed to one and the suffix-allowlist gates passed during
# +compute_semantic_base_map+; otherwise falls back to the inflectional
# +lemma(w)+. Composes the two normalization layers in one call so callers
# don't have to memorize the order.
#
# +RELATED_SKIP_DERIVATION=1+ disables the derivational hop (returns plain
# +lemma(w)+) — used by A/B harnesses to measure R3's contribution against the
# pre-R3 normalization regime. Layered with +RELATED_SKIP_LEMMA=1+ at the
# call sites: +RELATED_SKIP_LEMMA+ skips this entirely (passes the raw
# surface), +RELATED_SKIP_DERIVATION+ skips just the derivational layer.
def semantic_base(word)
  base = lemma(word)
  return base if ENV["RELATED_SKIP_DERIVATION"] == "1"
  map = $word_to_semantic_base
  load_word_to_semantic_base! if map.nil?
  map = $word_to_semantic_base
  return base unless map
  m = map[base]
  m || base
end

# One-shot loader for the Numberbatch cosine guard in
# +compute_semantic_base_map+. Returns the +word_underscored -> Array<Float>+
# hash from +numberbatch_vectors.msgpack+ (already L2-normalized at save time
# by +save_numberbatch_vectors!+, so cosine = dot product), or +nil+ when the
# file is absent. Independent of +signals.rb+'s +numberbatch_table+ — that
# path casts to +Numo::SFloat+ for hot-path BLAS, but the map build runs once
# and only needs the dot product, so plain Ruby arrays are fine here. Skipping
# +Numo+ also keeps +dict.rb+ free of the relatedness pipeline's heavy deps.
def load_numberbatch_vectors_for_semantic_base_guard
  path = generated_dict_path(NUMBERBATCH_VECTORS_FILENAME)
  return nil unless File.exist?(path)
  raw = MessagePack.unpack(File.binread(path))
  raw
end

def save_word_semantic_base_map!(word_dict, semantic_base_map, transform_for: nil)
  ensure_generated_dict_dir!
  msgpack_path = generated_dict_path_under_dict_dir(WORD_SEMANTIC_BASE_MAP_FILENAME)
  txt_path = generated_dict_path_under_dict_dir(WORD_SEMANTIC_BASE_MAP_TXT_FILENAME)

  obj = {}
  semantic_base_map.each do |w, target|
    next unless target && target != w
    next unless word_dict.key?(w) && word_dict.key?(target)
    obj[w] = target
  end
  MessagePackUtils.pack_and_save(msgpack_path, obj)
  puts "Wrote #{obj.size} word→semantic_base entries to #{msgpack_path} (#{File.size(msgpack_path)} bytes)"

  File.open(txt_path, "w", encoding: "UTF-8") do |f|
    f.puts "# word\tsemantic_base\ttransform"
    obj.keys.sort.each do |w|
      transform = transform_for ? transform_for[w] : ""
      f.puts "#{w}\t#{obj[w]}\t#{transform}"
    end
  end
  puts "Wrote sorted dump to #{txt_path}"
end

# Reverse map: lemma → array of all word_dict headwords that share that lemma (including the lemma
# itself when it is in word_dict). Built lazily on first access; cleared when word_dict is reloaded.
$lemma_to_words = nil
def lemma_to_words
  return $lemma_to_words unless $lemma_to_words.nil?
  # Force +word_dict+ to load before we allocate +$lemma_to_words+; +load_word_dict+ nils out
  # +$lemma_to_words+ as part of its invalidation handshake, so allocating first would make the
  # first loop iteration crash with +nil+.
  wd = word_dict
  $lemma_to_words = Hash.new { |h, k| h[k] = [] }
  wd.each_key do |w|
    base = lemma(w)
    $lemma_to_words[base] << w
  end
  $lemma_to_words
end

def save_word_dict(word_dict, lemma_map = nil)
  ensure_generated_dict_dir!
  path = generated_dict_path_under_dict_dir(WORD_DICT_FILENAME)
  f = File.open(path, "w", encoding: "UTF-8")
  f.puts(WORD_DICT_HEADER)
  for word, word_info in word_dict
    sanitized = word.sanitize
    f.print(sanitized)
    f.print(',')
    frequency, prons = word_info
    f.print(frequency)
    f.print(',')
    isFirstPron = true
    for pron in prons
      unless isFirstPron
        f.print('|')
      end
      isFirstPron = false
      f.print(pron)
    end
    if lemma_map
      lemma = lemma_map[word]
      if lemma && lemma != word
        f.print(',')
        f.print(lemma.sanitize)
      end
    end
    f.puts
  end
  f.close
end

# Emit the runtime-canonical +word_dict.msgpack+ — same +[freq, prons, lemma]+
# triple shape as the in-memory hash returned by +load_word_dict+, with two
# storage tweaks:
#
#   * +prons+ on disk is an Array of space-joined ARPABET strings (e.g.
#     +["K AE1 T", "K AE2 T"]+) rather than an Array of +Pronunciation+
#     objects — keeps the file ~30% smaller than the equivalent nested array
#     of phoneme strings (one msgpack string header per pronunciation rather
#     than per phoneme) and matches the +pron1|pron2+ wire format we already
#     use in +word_dict.txt+, so +load_word_dict_msgpack+ can pass each
#     element straight to +pronstr.split+ → +Pronunciation.new+.
#   * +lemma+ is stored as +nil+ when it equals the headword (matches
#     +save_word_lemma_map!+'s "drop self-lemmas" policy). +load_word_dict_
#     msgpack+ resolves +nil+ back to the headword so the runtime contract
#     ("entry[2] is always a non-nil string equal to lemma or word") holds.
#
# Called right after +save_word_dict+ in +rebuild_rhymecrime_dictionaries+ so
# a single dict-build refreshes both the human-readable +.txt+ and the
# runtime-loaded +.msgpack+. The +Pronunciation#to_s+ join is cheap (~200K
# entries × 1-2 prons of 4-8 phonemes), well under the rest of the build.
def save_word_dict_msgpack!(word_dict, lemma_map = nil)
  ensure_generated_dict_dir!
  path = generated_dict_path_under_dict_dir(WORD_DICT_MSGPACK_FILENAME)
  obj = {}
  word_dict.each do |word, info|
    freq, prons = info
    lem = lemma_map ? lemma_map[word] : (info[2] || word)
    pron_strs = (prons || []).map(&:to_s)
    stored_lemma = (lem && lem != word) ? lem : nil
    obj[word] = [freq.to_i, pron_strs, stored_lemma]
  end
  MessagePackUtils.pack_and_save(path, obj)
  size_mb = (File.size(path).to_f / 1024 / 1024).round(2)
  puts "Wrote #{obj.size} word_dict entries to #{WORD_DICT_MSGPACK_FILENAME} (#{size_mb} MB)"
end

# Runtime mirror of +load_word_dict+ that reads +word_dict.msgpack+ instead
# of streaming the +.txt+ file. Reconstitutes +Pronunciation+ instances and
# resolves +nil+ lemmas back to the headword so the returned hash is
# byte-for-byte equivalent to what +load_word_dict+ would have produced from
# the +.txt+ surface — every downstream consumer (+lexicon_word_entry+,
# +pronunciations+, +lemma+ fallback, etc.) is shape-agnostic between the
# two loaders.
#
# Returns +nil+ when the msgpack doesn't exist (caller falls back to the
# +.txt+ loader for fresh checkouts pre-dict-build); raises through the
# usual MessagePack errors otherwise.
def load_word_dict_msgpack
  path = generated_dict_path(WORD_DICT_MSGPACK_FILENAME)
  return nil unless File.exist?(path)
  raw = MessagePackUtils.load_and_unpack(path)
  word_dict = {}
  raw.each do |word, entry|
    freq, pron_strs, stored_lemma = entry
    prons = []
    (pron_strs || []).each do |pronstr|
      phonemes = pronstr.split(" ")
      next if phonemes.empty?
      push_pronunciation_unless_duplicate!(prons, Pronunciation.new(phonemes))
    end
    word_dict[word] = [freq.to_i, prons, stored_lemma || word]
  end
  clear_spelling_variant_hyphen_caches!
  $lemma_to_words = nil
  $word_to_lemma = nil
  $word_to_semantic_base = nil
  $thematically_related_memo = nil
  word_dict
end

# Emit the runtime-canonical +rime_dict.msgpack+ — same +{rime => [word, ...]}+
# shape as +load_string_hash(rime_dict.txt)+, but native MessagePack for fast
# Lambda cold-start load and an order-of-magnitude smaller bundle hit than
# the txt + .sanitize round-trip. Keys / values are stored verbatim (the txt
# surface uses +.sanitize+ to fold +" "+ → +"_"+ for the whitespace-delimited
# format; msgpack doesn't need the fold so we keep raw spaces). Called from
# +rebuild_rhymecrime_dictionaries+ alongside +save_string_hash(... rdict
# ...)+.
def save_rime_dict_msgpack!(rdict)
  ensure_generated_dict_dir!
  path = generated_dict_path_under_dict_dir(RIME_DICT_MSGPACK_FILENAME)
  obj = {}
  rdict.each do |rime, words|
    obj[rime.to_s] = (words || []).map(&:to_s)
  end
  MessagePackUtils.pack_and_save(path, obj)
  size_mb = (File.size(path).to_f / 1024 / 1024).round(2)
  puts "Wrote #{obj.size} rime_dict buckets to #{RIME_DICT_MSGPACK_FILENAME} (#{size_mb} MB)"
end

# Runtime mirror of +load_rime_dict_as_hash+. Returns +{rime => [word, ...]}+
# or +nil+ when the msgpack isn't on disk (caller falls back to the +.txt+
# loader for fresh checkouts pre-dict-build).
def load_rime_dict_msgpack
  path = generated_dict_path(RIME_DICT_MSGPACK_FILENAME)
  return nil unless File.exist?(path)
  raw = MessagePackUtils.load_and_unpack(path)
  out = {}
  raw.each { |rime, words| out[rime.to_s] = (words || []).map(&:to_s) }
  out
end

# Emit the runtime +word → canonical_lemma+ msgpack consumed by +word_to_lemma+.
# Called right after +save_word_dict+ in dict-build; only stores entries where
# the lemma differs from the word (matches +lemma(w)+'s "unknown → word"
# collapse and keeps the file small — ~40% of headwords have a non-self lemma).
def save_word_lemma_map!(word_dict, lemma_map)
  ensure_generated_dict_dir!
  path = generated_dict_path_under_dict_dir(WORD_LEMMA_MAP_FILENAME)
  obj = {}
  word_dict.each_key do |word|
    lem = lemma_map ? lemma_map[word] : word_dict[word][2]
    obj[word] = lem if lem && lem != word
  end
  MessagePackUtils.pack_and_save(path, obj)
  puts "Wrote #{obj.size} word→lemma entries to #{path} (#{File.size(path)} bytes)"
end

def save_part_of_speech_map(pos_map)
  ensure_generated_dict_dir!
  path = generated_dict_path_under_dict_dir(PART_OF_SPEECH_FILENAME)
  # word => sorted list of Kaikki-style POS strings (noun, verb, adj, …) after Layer A ∩ WordNet.
  obj = pos_map.keys.sort.to_h { |w| [w, pos_map[w].to_a.sort] }
  File.write(path, JSON.generate(obj), encoding: "UTF-8")
end

#
# rime (ARPABET key for rhyme lookup; see Pronunciation#rime)
#

def single_consonant?(phoneme_cluster)
  return phoneme_cluster.length == 1 && !phoneme_cluster[0].vowel?
end
