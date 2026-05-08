# encoding: utf-8
#
# rarity_curated_overrides.rb — build-time override of the learned rarity
# classifier from curated/rarity.csv (rarity-pipeline stage 2 short-circuit).
#
# The classifier reaches ~97-98% weighted pass rate on the labels in
# curated/rarity.csv (see spec/rarity_spec.rb's aggregate gate). Of the
# remaining few percent, every miss is a word we've explicitly hand-judged in
# the same CSV — information already in the repo, not learnable from corpus
# scalars alone. The classifier sees common_words_flag / rare_words_flag
# as features but can still overrule them when corpus evidence (Zipf,
# SUBTLEX, WordNet) pushes the other way (e.g. cheffy trained at
# freq=98 by neol-promotion of a non-existent base, nosocomephobia scoring
# common on long-word features). This module folds those labels back in:
#
#   * (word, common)         → force :common   (freq 10)
#   * (word, common_ish)     → force :common   (freq 10)
#   * (word, rare)           → force :rare     (freq 2)
#   * (word, rare_ish)       → force :rare     (freq 2)
#   * (word, forbidden)      → force :forbidden (delete from hash)
#   * (word, forbidden_ish)  → force :forbidden (delete from hash)
#   * (word, uncommon)       → no override (deferred to classifier)
#   * (word, *_no_rhymes)    → no override (rhyme-coverage label, not rarity)
#   * (word, have_rhymes)    → no override (rhyme-coverage label, not rarity)
#
# Only unambiguous verdicts override: a word that has rows in multiple
# rarity-relevant categories (e.g. one common row AND one rare row) is a
# curation contradiction with nothing for us to override _to_, so we skip the
# override and log the count via verbose rather than silently picking a
# side. (Same reasoning as the contradictory skip in
# relatedness/curated_overrides.rb.) Non-rarity labels — uncommon,
# common_no_rhymes, rare_no_rhymes, have_rhymes — neither contribute
# nor block a verdict.
#
# Surface-form keyed (rarity rescore iterates headwords directly, no lemma
# fold-down step like relatedness has). Inflected curated rows therefore stay
# distinct from their bases — cats,common overrides cats only.
#
# Gated by RHYMECRIME_RARITY_CSV_OVERRIDE — default ON. Set to 0 to
# disable (e.g. to evaluate the classifier without the curated rescue). Read
# on first access; reset the memo via reset_rarity_curated_overrides! to
# pick up an env-var change inside a single process.
#
# Consulted only by rarity_rescore_and_dump! in rarity_classifier.rb.
# spec/rarity_spec.rb deliberately sweeps live rarity_category (which
# reads word_dict frequencies and explicitly_forbidden?) — folding the
# CSV labels into that predicate would short-circuit the spec to a vacuous
# 100% pass rate, masking real classifier regressions.

require "csv"
require "set"
require_relative "build_utils"
require_relative "build_io"

# Rarity-relevant kind values mapped to the verdict the override emits.
# Other kinds (uncommon, *_no_rhymes, have_rhymes) are intentionally absent —
# they're eval-only labels and contribute nothing to the override map.
CURATED_RARITY_OVERRIDE_KINDS = {
  "common" => :common,
  "common_ish" => :common,
  "rare" => :rare,
  "rare_ish" => :rare,
  "forbidden" => :forbidden,
  "forbidden_ish" => :forbidden,
}.freeze

# Integer freq emitted per verdict; matches rarity_classify so the rescore
# call site can use the override result without a separate freq mapping table.
CURATED_RARITY_OVERRIDE_FREQ = {
  common: 10,
  rare: 2,
  forbidden: 0,
}.freeze

$rarity_curated_overrides = nil
$rarity_curated_overrides_stats = nil

# Returns true unless explicitly disabled via env var. Default ON.
def rarity_curated_overrides_enabled?
  ENV["RHYMECRIME_RARITY_CSV_OVERRIDE"].to_s != "0"
end

# Drop the memoized override map. Used by tests and by tooling that mutates
# curated/rarity.csv within a single process.
def reset_rarity_curated_overrides!
  $rarity_curated_overrides = nil
  $rarity_curated_overrides_stats = nil
end

# Build the override map: Hash[word] -> verdict where verdict is one of
# :common, :rare, :forbidden. Words with rows in multiple rarity-relevant
# categories are dropped and logged in stats[:contradictory]. Returns {}
# when the CSV is missing or the override is disabled. Memoized in
# $rarity_curated_overrides; reset via reset_rarity_curated_overrides!.
def rarity_curated_overrides
  return $rarity_curated_overrides if $rarity_curated_overrides
  unless rarity_curated_overrides_enabled?
    $rarity_curated_overrides = {}
    $rarity_curated_overrides_stats = { rows: 0, words: 0, contradictory: 0, non_rarity_kind: 0, malformed: 0, disabled: true }
    return $rarity_curated_overrides
  end
  unless File.exist?(RARITY_CSV_PATH)
    $rarity_curated_overrides = {}
    $rarity_curated_overrides_stats = { rows: 0, words: 0, contradictory: 0, non_rarity_kind: 0, malformed: 0, missing_csv: true }
    return $rarity_curated_overrides
  end

  by_word = Hash.new { |h, k| h[k] = Set.new }
  rows_seen = 0
  malformed = 0
  non_rarity_kind = 0
  BuildIo.csv_foreach(RARITY_CSV_PATH, headers: true, encoding: "UTF-8", hint: "load_rarity_curated_overrides") do |row|
    word = row["word"].to_s.strip
    kind = row["kind"].to_s.strip
    if word.empty?
      malformed += 1
      next
    end
    rows_seen += 1
    verdict = CURATED_RARITY_OVERRIDE_KINDS[kind]
    if verdict.nil?
      non_rarity_kind += 1
      next
    end
    by_word[word] << verdict
  end

  overrides = {}
  contradictory = 0
  by_word.each do |word, verdicts|
    if verdicts.size == 1
      overrides[word] = verdicts.first
    else
      contradictory += 1
    end
  end

  $rarity_curated_overrides_stats = {
    rows: rows_seen,
    words: overrides.size,
    contradictory: contradictory,
    non_rarity_kind: non_rarity_kind,
    malformed: malformed,
  }
  $rarity_curated_overrides = overrides
end

# Stats hash populated as a side effect of rarity_curated_overrides. Keys:
# :rows (CSV rows considered), :words (unambiguous overrides emitted),
# :contradictory (words with conflicting rarity rows, dropped),
# :non_rarity_kind (rows whose kind is uncommon / *_no_rhymes /
# have_rhymes, ignored), :malformed (rows missing word), :disabled /
# :missing_csv flags.
def rarity_curated_overrides_stats
  rarity_curated_overrides unless $rarity_curated_overrides_stats
  $rarity_curated_overrides_stats || {}
end

# Convenience for callers (currently rarity_rescore_and_dump!) that want to
# log the override coverage once before the rescore loop begins.
def announce_rarity_curated_overrides!
  s = rarity_curated_overrides_stats
  if s[:disabled]
    puts "Curated rarity overrides: DISABLED (RHYMECRIME_RARITY_CSV_OVERRIDE=0)"
    return
  end
  if s[:missing_csv]
    puts "Curated rarity overrides: skipped (no curated/rarity.csv on disk)"
    return
  end
  puts format(
    "Curated rarity overrides: %d word overrides loaded from %d CSV rows " \
    "(%d contradictory words dropped, %d non-rarity kind rows skipped, %d malformed rows skipped). " \
    "Disable with RHYMECRIME_RARITY_CSV_OVERRIDE=0.",
    s[:words] || 0, s[:rows] || 0, s[:contradictory] || 0, s[:non_rarity_kind] || 0, s[:malformed] || 0
  )
end
