# frozen_string_literal: true
#
# prefix_curated_overrides.rb — fold curated/prefix.csv into the prefix allow
# gate after classifier scoring (bin/precompute-prefix-gate), same role as
# rarity_curated_overrides.rb for the rarity rescore: hand labels win over the
# model on disagreements.
#
# After the classifier labels each (prefix+base, base) triple, every row in
# curated/prefix.csv with verdict allow or filter is applied to the gate:
#
#   * (prefix, base, allow)   → ensure base is in the allow list for word prefix+base
#   * (prefix, base, filter)  → remove base from the allow list for that word (if present)
#
# Verdict "whatever" and unknown verdicts are skipped (eval-only), counted in
# stats. Same (prefix, base) with both allow and filter in the CSV is a
# contradiction — the pair is dropped and counted.
#
# Optional "word" column: when present, must equal prefix+base or the row is malformed.
#
# Gated by RHYMECRIME_PREFIX_CSV_OVERRIDE — default ON. Set to 0 to disable.
# Reset memoization via reset_prefix_curated_overrides! after env or CSV edits.

require "set"
require_relative "build_io"
require_relative "../env"

PREFIX_CURATED_CSV_PATH = File.join(CURATED_DIR, "prefix.csv").freeze

CURATED_PREFIX_OVERRIDE_VERDICTS = {
  "allow"   => :allow,
  "filter"  => :filter,
}.freeze

$prefix_curated_overrides_payload = nil

def prefix_curated_overrides_enabled?
  Rhymecrime::Env.prefix_csv_override_enabled?
end

def reset_prefix_curated_overrides!
  $prefix_curated_overrides_payload = nil
end

# Returns { actions: { [prefix, base] => :allow | :filter }, stats: Hash }.
# Memoized; call reset_prefix_curated_overrides! to reload.
def prefix_curated_overrides_payload
  return $prefix_curated_overrides_payload if $prefix_curated_overrides_payload

  unless prefix_curated_overrides_enabled?
    stats = { rows: 0, pairs: 0, contradictory: 0, non_override_kind: 0, malformed: 0, disabled: true }
    return $prefix_curated_overrides_payload = { actions: {}, stats: stats }
  end
  unless File.exist?(PREFIX_CURATED_CSV_PATH)
    stats = { rows: 0, pairs: 0, contradictory: 0, non_override_kind: 0, malformed: 0, missing_csv: true }
    return $prefix_curated_overrides_payload = { actions: {}, stats: stats }
  end

  by_pair = Hash.new { |h, k| h[k] = Set.new }
  rows_seen = 0
  malformed = 0
  non_override_kind = 0

  BuildIo.csv_foreach(PREFIX_CURATED_CSV_PATH, headers: true, encoding: "UTF-8", hint: "prefix_curated_overrides prefix.csv") do |row|
    prefix = row["prefix"].to_s.strip
    base   = row["base"].to_s.strip
    kind   = row["verdict"].to_s.strip.downcase
    rows_seen += 1
    if prefix.empty? || base.empty?
      malformed += 1
      next
    end
    if row["word"] && !row["word"].to_s.strip.empty?
      derived = prefix + base
      unless row["word"].to_s.strip == derived
        malformed += 1
        next
      end
    end
    verdict = CURATED_PREFIX_OVERRIDE_VERDICTS[kind]
    if verdict.nil?
      non_override_kind += 1
      next
    end
    by_pair[[prefix, base]] << verdict
  end

  actions = {}
  contradictory = 0
  by_pair.each do |pair, verdicts|
    if verdicts.size == 1
      actions[pair] = verdicts.first
    else
      contradictory += 1
    end
  end

  stats = {
    rows: rows_seen,
    pairs: actions.size,
    contradictory: contradictory,
    non_override_kind: non_override_kind,
    malformed: malformed,
  }
  $prefix_curated_overrides_payload = { actions: actions, stats: stats }
end

def prefix_curated_overrides_stats
  prefix_curated_overrides_payload[:stats]
end

def announce_prefix_curated_overrides!
  s = prefix_curated_overrides_stats
  if s[:disabled]
    puts "Curated prefix.csv fold-in: DISABLED (RHYMECRIME_PREFIX_CSV_OVERRIDE=0)"
    return
  end
  if s[:missing_csv]
    puts "Curated prefix.csv fold-in: skipped (no #{PREFIX_CURATED_CSV_PATH} on disk)"
    return
  end
  puts format(
    "Curated prefix.csv fold-in: %d (prefix,base) actions from %d CSV rows " \
    "(%d contradictory pairs dropped, %d non-allow/filter rows skipped, %d malformed rows skipped). " \
    "Disable with RHYMECRIME_PREFIX_CSV_OVERRIDE=0.",
    s[:pairs] || 0, s[:rows] || 0, s[:contradictory] || 0, s[:non_override_kind] || 0, s[:malformed] || 0
  )
end

# Mutates gate: Hash[word, Array<base>] of classifier :allow entries.
# Applies curated allow (add) / filter (remove) from prefix.csv after the model.
def prefix_curated_overrides_apply!(gate)
  announce_prefix_curated_overrides!
  actions = prefix_curated_overrides_payload[:actions]
  return if actions.empty?

  n_allow = 0
  n_filter = 0
  actions.each do |(prefix, base), verdict|
    word = prefix + base
    case verdict
    when :allow
      gate[word] ||= []
      unless gate[word].include?(base)
        gate[word] << base
        n_allow += 1
      end
    when :filter
      next unless gate[word]
      if gate[word].delete(base)
        n_filter += 1
        gate.delete(word) if gate[word].empty?
      end
    end
  end
  puts "  prefix.csv fold-in: +#{n_allow} allow, −#{n_filter} filter (pair-level edits)" if n_allow.positive? || n_filter.positive?
end
