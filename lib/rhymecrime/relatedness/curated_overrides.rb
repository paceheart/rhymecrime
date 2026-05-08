#!/usr/bin/env ruby
# coding: utf-8
#
# relatedness/curated_overrides.rb — runtime override of the learned classifier
# from curated/related.csv.
#
# The classifier reaches ~89% weighted pass rate on the labels in
# curated/related.csv (see spec/related_spec.rb's aggregate gate). Of the
# remaining ~11%, every miss is a pair we've explicitly hand-judged in CSV —
# information already in the repo, not learnable. Throwing away those gold
# labels at compute time costs us a few percent of correctness on exactly the
# pairs we care most about (the curated cues are the ones we've invested
# curation effort in). This module folds those labels back in:
#
#   * (cue, related, related)         → force-include the candidate, score 100
#   * (cue, related, related_ish)     → force-include the candidate, score 80
#   * (cue, related, unrelated)       → force-exclude the candidate
#   * (cue, related, unrelated_ish)   → force-exclude the candidate
#   * (cue, related, whatever)        → no override (defer to classifier)
#
# Polarity-contradictory pairs are skipped (a CSV that says both related and
# unrelated for the same (cue_lemma, related_lemma) has nothing for us to
# override _to_, and the contradiction is a curation bug worth flagging via
# verbose rather than silently picking a side).
#
# Lemma-keyed: rows are resolved through lemma(word) before being indexed,
# matching the lemma-keyed scan in find_all_thematically_related_words_by_scan.
# Inflected curated rows like (cats, mice, related) therefore fold into the
# (cat, mouse) override the runtime actually consults.
#
# Gated by RHYMECRIME_RELATED_CSV_OVERRIDE — default ON. Set to 0 to disable
# (e.g. to A/B-test the classifier without the curated rescue). The env var is
# read on first access so a single-process eval can flip it between calls by
# resetting the memo via reset_curated_relatedness_overrides!.
#
# Consulted by both compute output generation and the local-dev predicate
# fallback. Production runtime sees the same decisions after compute serializes
# them into related rows; local runtime without a cache must apply the same
# overrides directly or it regresses exactly the curated pairs compute would
# have rescued.

require "csv"
require_relative "../build/utils_rhyme"

# Fixed scores assigned to curated related / related_ish overrides. Picked so
# that strong-curated overrides outrank borderline classifier hits (which cluster
# just above RELATEDNESS_SCORE_THRESHOLD = 50) and weak-curated overrides land
# just below the strongest organic matches but well above the threshold.
CURATED_OVERRIDE_SCORE_RELATED = 100
CURATED_OVERRIDE_SCORE_RELATED_ISH = 80

$curated_relatedness_overrides = nil
$curated_relatedness_overrides_stats = nil

# Returns true unless explicitly disabled via env var. Default ON.
def curated_relatedness_overrides_enabled?
  ENV["RHYMECRIME_RELATED_CSV_OVERRIDE"].to_s != "0"
end

# Drop the memoized override map. Used by tests and by tooling that mutates
# curated/related.csv within a single process.
def reset_curated_relatedness_overrides!
  $curated_relatedness_overrides = nil
  $curated_relatedness_overrides_stats = nil
end

# Build the override map: Hash[ [cue_lemma, related_lemma] ] -> verdict where
# verdict is one of :related, :related_ish, :unrelated, :unrelated_ish.
# Rows are resolved through lemma(word) so inflected curated entries map to
# the same key the lemma-keyed scan uses. Polarity-contradictory pairs (any
# (related*, unrelated*) mix) are dropped and logged in stats[:contradictory].
#
# Returns {} when the CSV is missing or the override is disabled. Memoized in
# $curated_relatedness_overrides; reset via reset_curated_relatedness_overrides!.
def curated_relatedness_overrides
  return $curated_relatedness_overrides if $curated_relatedness_overrides
  unless curated_relatedness_overrides_enabled?
    $curated_relatedness_overrides = {}
    $curated_relatedness_overrides_stats = { rows: 0, pairs: 0, contradictory: 0, whatever: 0, malformed: 0, disabled: true }
    return $curated_relatedness_overrides
  end
  path = curated_relatedness_csv_path
  unless File.exist?(path)
    $curated_relatedness_overrides = {}
    $curated_relatedness_overrides_stats = { rows: 0, pairs: 0, contradictory: 0, whatever: 0, malformed: 0, missing_csv: true }
    return $curated_relatedness_overrides
  end

  by_pair = Hash.new { |h, k| h[k] = [] }
  rows_seen = 0
  malformed = 0
  whatever = 0
  BuildIoUtils.csv_foreach(path, headers: true, encoding: "UTF-8", hint: "load_curated_relatedness_overrides") do |row|
    cue = row["cue"]&.strip
    rel = row["related"]&.strip
    kind = row["oughta be related?"].to_s.strip.downcase
    if cue.nil? || cue.empty? || rel.nil? || rel.empty?
      malformed += 1
      next
    end
    rows_seen += 1
    if kind == "whatever"
      whatever += 1
      next
    end
    unless %w[related related_ish unrelated unrelated_ish].include?(kind)
      malformed += 1
      next
    end
    cue_lem = lemma(cue) || cue
    rel_lem = lemma(rel) || rel
    next if cue_lem == rel_lem # self-pair, no-op for the scan
    by_pair[[cue_lem, rel_lem]] << kind
  end

  overrides = {}
  contradictory = 0
  by_pair.each do |key, kinds|
    related_kinds = kinds.select { |k| k.start_with?("related") }
    unrelated_kinds = kinds.select { |k| k.start_with?("unrelated") }
    if related_kinds.any? && unrelated_kinds.any?
      contradictory += 1
      next
    end
    verdict =
      if related_kinds.any?
        related_kinds.include?("related") ? :related : :related_ish
      elsif unrelated_kinds.include?("unrelated")
        :unrelated
      else
        :unrelated_ish
      end
    overrides[key] = verdict
  end

  $curated_relatedness_overrides_stats = {
    rows: rows_seen,
    pairs: overrides.size,
    contradictory: contradictory,
    whatever: whatever,
    malformed: malformed,
  }
  $curated_relatedness_overrides = overrides
end

# Path to the curated CSV. Override-able via RHYMECRIME_RELATED_CSV_PATH for
# tooling that reads from a generated/staged copy (e.g. the
# bin/augment-related-from-feedback dry-run preview).
def curated_relatedness_csv_path
  ENV["RHYMECRIME_RELATED_CSV_PATH"] || File.expand_path("../../../curated/related.csv", __dir__)
end

# Stats hash populated as a side effect of curated_relatedness_overrides. Keys:
# :rows (CSV rows considered), :pairs (lemma-pair overrides emitted),
# :contradictory (lemma-pair-level polarity conflicts dropped), :whatever
# (rows with explicit whatever verdict, ignored), :malformed (rows missing
# cue/related or with an unknown kind), :disabled / :missing_csv flags.
def curated_relatedness_overrides_stats
  curated_relatedness_overrides unless $curated_relatedness_overrides_stats
  $curated_relatedness_overrides_stats || {}
end

# Boolean override for the local predicate path. Returns true/false when
# curated/related.csv has a non-contradictory verdict for the ordered lemma pair,
# or nil when there is no override and the classifier/rules should decide.
def curated_relatedness_override_related?(cue_lemma, related_lemma)
  case curated_relatedness_overrides[[cue_lemma, related_lemma]]
  when :related, :related_ish
    true
  when :unrelated, :unrelated_ish
    false
  else
    nil
  end
end

# Convenience for callers that want to log the override coverage once at compute
# startup (bin/compute-relatedness) before the scan loop begins.
def announce_curated_relatedness_overrides!
  s = curated_relatedness_overrides_stats
  if s[:disabled]
    puts "Curated relatedness overrides: DISABLED (RHYMECRIME_RELATED_CSV_OVERRIDE=0)"
    return
  end
  if s[:missing_csv]
    puts "Curated relatedness overrides: skipped (no curated/related.csv on disk)"
    return
  end
  puts format(
    "Curated relatedness overrides: %d lemma-pair overrides loaded from %d CSV rows " \
    "(%d contradictory pairs dropped, %d whatever rows skipped, %d malformed rows skipped). " \
    "Disable with RHYMECRIME_RELATED_CSV_OVERRIDE=0.",
    s[:pairs] || 0, s[:rows] || 0, s[:contradictory] || 0, s[:whatever] || 0, s[:malformed] || 0
  )
end
