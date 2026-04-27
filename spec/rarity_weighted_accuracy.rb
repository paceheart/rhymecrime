#!/usr/bin/env ruby
# encoding: utf-8
#
# Weighted accuracy over curated/rarity.csv rarity categories vs live +rarity_category+ (built word_dict).
# Run from repo root:
#   ruby spec/rarity_weighted_accuracy.rb
#
# Scoring (partial credit on mismatches):
#   exact match                                         -> 1.0
#   :rare    vs :forbidden (either direction)           -> 0.9
#   :common  vs :rare      (either direction)           -> 0.1
#   :common  vs :forbidden (either direction)           -> 0.0
#
# Cue-only false-negative discount: when the expected category is :forbidden
# but the live dict classifies the word as :common / :rare *and* the word is
# not a +relatedness_target_word?+ (only surfaces as a precompute cue, never as
# a related in the UI), the penalty +1 - base_score+ is divided by
# +CUE_ONLY_FN_PENALTY_DIVISOR+ — i.e. +mismatch_score+ returns
# +1 - (1 - base)/100+. Rationale: such FNs only bloat the DB and slow
# precompute; users never see the junk word. Strong FNs keep full penalty.
#
# Weights: common / rare / forbidden rows weight 3; *_ish rows weight 1.
# Rows skipped: uncommon, *_no_rhymes, have_rhymes, and CSV skip=1.

require "csv"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "rhymecrime/crime"
require "rhymecrime/dict/rime"

CUE_ONLY_FN_PENALTY_DIVISOR = 100.0

def allowed?(word)
  !explicitly_forbidden?(word) && word_dict.key?(word)
end

def rarity_category(word)
  return :forbidden unless allowed?(word)
  rare?(word) ? :rare : :common
end

def expected_category_for_kind(kind)
  case kind.strip
  when "common", "common_ish" then :common
  when "rare", "rare_ish" then :rare
  when "forbidden", "forbidden_ish" then :forbidden
  else nil
  end
end

# True iff the mismatch is a "cue-only" false negative: we expected :forbidden
# but the live dict gave :common / :rare, *and* the word can never surface as
# a related word in the UI (fails +relatedness_target_word?+). Limited to the
# FN direction: over-forbidding (actual :forbidden) still costs full penalty
# so the metric doesn't silently excuse strong FPs.
def cue_only_false_negative?(expected, actual, word)
  return false unless expected == :forbidden
  return false if actual == :forbidden
  return false unless word_dict.key?(word)
  !relatedness_target_word?(word, word_dict, rdict)
end

def mismatch_score(expected, actual, cue_only: false)
  return 1.0 if expected == actual

  cats = [expected, actual].sort_by(&:to_s)
  base = case cats
  when %i[common forbidden]
    0.0
  when %i[common rare]
    0.1
  when %i[forbidden rare]
    0.9
  else
    raise "unexpected category pair: #{expected.inspect} vs #{actual.inspect}"
  end

  return base unless cue_only
  1.0 - (1.0 - base) / CUE_ONLY_FN_PENALTY_DIVISOR
end

def row_weight(kind)
  kind.strip.end_with?("_ish") ? 1 : 3
end

csv_path = File.expand_path("../curated/rarity.csv", __dir__)
rows = CSV.read(csv_path, headers: true, encoding: "UTF-8")

total_weight = 0.0
weighted_score = 0.0
evaluated = 0
exact = 0

rows.each_with_index do |row, i|
  kind = row["kind"].to_s
  expected = expected_category_for_kind(kind)
  next if expected.nil?

  skip = row["skip"].to_s.strip == "1"
  next if skip

  word = row["word"].to_s
  context = row["context"].to_s
  w = row_weight(kind)
  actual = rarity_category(word)
  cue_only_fn = cue_only_false_negative?(expected, actual, word)
  score = mismatch_score(expected, actual, cue_only: cue_only_fn)

  total_weight += w
  weighted_score += w * score
  evaluated += 1
  exact += 1 if score == 1.0

  next if score == 1.0

    puts [
    "F:",
    "#{word.inspect}",
    "#{actual}, oughta be #{kind}",
    format("score=%.3f", score),
    "(line #{i + 2})",
    "#{context}"
  ].join(" ")
end

pct = total_weight.positive? ? (100.0 * weighted_score / total_weight) : 0.0

puts
puts format("Weighted accuracy: %.1f%%", pct)
puts format(
  "  (weighted score %.4f / weight %.0f over %d category rows; %d exact, %d partial/zero)",
  weighted_score,
  total_weight,
  evaluated,
  exact,
  evaluated - exact
)
