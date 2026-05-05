require 'csv'
require "rhymecrime/pace_utils"

# True when +RHYMECRIME_VERBOSE_CSV_SWEEP+ is set to a truthy value (1/true/yes/on,
# case-insensitive). Gates the per-row +puts "FAIL ..."+ diagnostics emitted by the
# +evaluate_*_csv+ sweeps in +related_spec.rb+, +rarity_spec.rb+, and +semantic_base_spec.rb+.
# Off by default so the rspec failure summary at the end of a run isn't drowned in
# 1k+ lines of expected-but-not-yet-passing rows; the per-CSV summary line still
# always prints (with the FAIL count), so you know whether to flip this on.
#
#   RHYMECRIME_VERBOSE_CSV_SWEEP=1 bundle exec rspec spec/related_spec.rb
def csv_sweep_verbose?
  v = ENV.fetch("RHYMECRIME_VERBOSE_CSV_SWEEP", "").strip.downcase
  !v.empty? && %w[1 true yes on].include?(v)
end

# Valid values for the +oughta be related?+ column in curated/related.csv. Rows marked +whatever+ are
# ignored by the spec / weighted accuracy script because either answer is acceptable. Rows marked
# +*_ish+ represent weak-signal cases (originally encoded as a +ish+ marker in the +notes+ column).
RELATEDNESS_KINDS = %w[related related_ish unrelated unrelated_ish whatever].freeze

def relatedness_expected_boolean(kind)
  case kind.to_s.strip
  when "related", "related_ish" then true
  when "unrelated", "unrelated_ish" then false
  when "whatever" then nil
  else raise "unknown relatedness kind #{kind.inspect}"
  end
end

def relatedness_kind_ish?(kind)
  k = kind.to_s.strip
  k == "related_ish" || k == "unrelated_ish"
end

$cases = nil
def relatedness_test_cases
  $cases ||= load_relatedness_test_cases
end

# cue, related, oughta be related?, notes
def load_relatedness_test_cases
  cases = CSV.parse(File.read("curated/related.csv", encoding: 'UTF-8'), headers: true) or raise "Could not read/parse related.csv"
  for c in cases
    repair_relatedness_test_case(c)
  end
  for c in cases
    validate_relatedness_test_case(c)
  end
end

def word?(object)
  object.is_a?(String) and object == object.strip
end

def repair_relatedness_test_case(c)
  c['notes'] ||= ""
end

def validate_relatedness_test_case(c)
  cue = c['cue']
  word?(cue) or raise "Malformed cue '#{cue}' in #{c}"
  related = c['related']
  word?(related) or raise "Malformed related '#{related}' in #{c}"
  kind = c['oughta be related?'].to_s.strip
  RELATEDNESS_KINDS.include?(kind) or raise "Malformed oughta_be_related? '#{kind}' in #{c} (expected one of #{RELATEDNESS_KINDS.join(', ')})"
  notes = c['notes']
  notes.is_a?(String) or raise "Malformed notes '#{notes}' in #{c}"
end

def define_relatedness_test_case(c)
  kind = c["oughta be related?"].to_s.strip
  return if kind == "whatever"
  context c["notes"] do
    if relatedness_expected_boolean(kind)
      oughta_be_related c["cue"], c["related"]
    else
      ought_not_be_related c["cue"], c["related"]
    end
  end
end

def load_and_define_relatedness_test_cases
  load_relatedness_test_cases.each { |c| define_relatedness_test_case(c) }
end

def relatedness_test_passes?(test_case)
  expected = relatedness_expected_boolean(test_case['oughta be related?'])
  return true if expected.nil?
  actual = thematically_related?(test_case["cue"], test_case["related"], false)
  debug expected == actual ? "." : "F"
  return expected == actual
end

def succeeding_test_count
  cases = relatedness_test_cases
  success_count = cases.count { |c| relatedness_test_passes?(c) }
  return success_count
end

def failing_test_count
  relatedness_test_cases.count - succeeding_test_count
end

# --- rarity.csv (curated/rarity.csv, exercised by spec/rarity_spec.rb) ---

RARITY_CSV_KINDS = %w[
  common common_ish rare rare_ish uncommon forbidden forbidden_ish
  common_no_rhymes rare_no_rhymes have_rhymes
].freeze

def rarity_csv_path
  File.expand_path("../curated/rarity.csv", __dir__)
end

def load_rarity_csv_rows
  raw = File.read(rarity_csv_path, encoding: "UTF-8")
  CSV.parse(raw, headers: true, encoding: "UTF-8")
end

def validate_rarity_csv_row!(row, line_hint = nil)
  ctx = row["context"]
  word = row["word"]
  kind = row["kind"]
  hint = line_hint ? " (#{line_hint})" : ""
  raise "rarity.csv: empty context#{hint}" if ctx.nil? || ctx.strip.empty?
  raise "rarity.csv: empty word#{hint}" if word.nil? || word.empty?
  raise "rarity.csv: unknown kind #{kind.inspect}#{hint}" unless RARITY_CSV_KINDS.include?(kind.to_s.strip)
end

def define_rarity_nested_contexts(names, &block)
  if names.empty?
    yield
  else
    context(names.first) do
      define_rarity_nested_contexts(names.drop(1), &block)
    end
  end
end

def apply_rarity_csv_row(row)
  validate_rarity_csv_row!(row)
  word = row["word"]
  important = row["important"].to_s.strip != "0"
  case row["kind"].strip
  when "common"
    oughta_be_common word, important: important
  when "common_ish"
    oughta_be_common_ish word
  when "rare"
    oughta_be_rare word, important: important
  when "rare_ish"
    oughta_be_rare_ish word
  when "uncommon"
    oughta_be_uncommon word
  when "forbidden"
    oughta_be_forbidden word
  when "forbidden_ish"
    oughta_be_forbidden_ish word
  when "common_no_rhymes"
    oughta_be_common_but_has_no_rhymes word
  when "rare_no_rhymes"
    oughta_be_rare_but_has_no_rhymes word
  when "have_rhymes"
    oughta_have_rhymes word
  else
    raise "rarity.csv: unhandled kind #{row['kind'].inspect}"
  end
end

# Loads curated/rarity.csv and defines nested RSpec contexts + examples. Requires +oughta_be_*+ helpers from
# +rarity_spec.rb+ (same pattern as +related_spec.rb+ / +related.csv+).
def load_and_define_rarity_test_cases_from_csv
  rows = load_rarity_csv_rows
  rows.each_with_index do |row, i|
    validate_rarity_csv_row!(row, "line #{i + 2}")
  end
  order = []
  rows.each do |row|
    c = row["context"]
    order << c unless order.include?(c)
  end
  order.each do |ctx|
    names = ctx.split(" / ").map(&:strip).reject(&:empty?)
    grouped = rows.select { |r| r["context"] == ctx }
    define_rarity_nested_contexts(names) do
      grouped.each { |r| apply_rarity_csv_row(r) }
    end
  end
end
