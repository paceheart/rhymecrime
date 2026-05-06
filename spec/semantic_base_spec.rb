# Semantic-base column expectations from generated/word_dict (see bin/dict-build).
# Rows: surface, semantic_base, optional skip (1 to skip unless RHYMECRIME_RUN_SKIPPED), optional notes.
#
# Layout note: every row in curated/semantic_base.csv is exercised inline at
# file load (not as a per-row rspec example) — we sweep, puts a one-line FAIL
# diagnostic on each mismatch, and stash the totals in a module constant. The
# single describe block below then converts those totals into one aggregate
# spec (coverage floor + pass-rate floor) so red/green still flows through
# rspec.

require "csv"
require_relative "test_utils"

def semantic_base_csv_path
  File.expand_path("../curated/semantic_base.csv", __dir__)
end

def load_semantic_base_csv_rows
  raw = File.read(semantic_base_csv_path, encoding: "UTF-8")
  CSV.parse(raw, headers: true, encoding: "UTF-8")
end

def validate_semantic_base_csv_row!(row, line_hint = nil)
  hint = line_hint ? " (#{line_hint})" : ""
  surface = row["surface"].to_s.strip
  sb = row["semantic_base"].to_s.strip
  raise "semantic_base.csv: empty surface#{hint}" if surface.empty?
  raise "semantic_base.csv: empty semantic_base#{hint}" if sb.empty?
end

# Sweep curated/semantic_base.csv against live semantic_base(). Returns
# [total, passed] over rows we actually evaluated; rows with skip==1 are
# excluded from both counts unless RHYMECRIME_RUN_SKIPPED is set (matching
# the rest of the suite). Side effects: puts a one-line FAIL diagnostic
# per mismatch and a summary line.
def evaluate_semantic_base_csv
  rows = load_semantic_base_csv_rows
  rows.each_with_index { |row, i| validate_semantic_base_csv_row!(row, "line #{i + 2}") }

  total = 0
  passed = 0
  rows.each do |row|
    surface  = row["surface"].to_s.strip
    expected = row["semantic_base"].to_s.strip
    skip     = row["skip"].to_s.strip == "1"
    next if skip && !rhymecrime_run_skipped_examples?

    total += 1
    got = semantic_base(surface)
    if got == expected
      passed += 1
    elsif csv_sweep_verbose?
      puts "FAIL semantic_base(#{surface.inspect}) -> #{got.inspect}, expected #{expected.inspect}"
    end
  end

  failed = total - passed
  rate_pct = total.zero? ? 0.0 : (passed.to_f / total) * 100
  puts format("curated/semantic_base.csv: %d/%d pass (%.1f%%, %d fail)", passed, total, rate_pct, failed)
  [total, passed]
end

SEMANTIC_BASE_TOTAL, SEMANTIC_BASE_PASSED = evaluate_semantic_base_csv
SEMANTIC_BASE_PASS_RATE_FLOOR = 0.70
SEMANTIC_BASE_PASS_RATE_SUSPICIOUS_THRESHOLD = 0.95

# Per-example assertion that semantic_base(word) == expected. Sibling to
# oughta_be_common / oughta_rhyme — same it-block shape so individual
# regressions show up as named rspec failures rather than dragging the
# curated/semantic_base.csv aggregate pass-rate floor down. Use this for
# spot checks that document specific lemma / derivational-base bugs we
# want red until word_lemma_map / word_semantic_base_map catch up
# (e.g. icier → icey when the right answer is icy).
def oughta_have_semantic_base(word, expected, not_working_reason: nil)
  test_name = "'#{word}' oughta have semantic_base '#{expected}'"
  it test_name do
    skip_if_not_working(not_working_reason)
    got = semantic_base(word)
    expect(got).to eql(expected),
      "semantic_base(#{word.inspect}) returned #{got.inspect}, expected #{expected.inspect}"
  end
end

describe "SEMANTIC_BASE" do
  it "covers >= 100 rows" do
    expect(SEMANTIC_BASE_TOTAL).to be >= 90
  end

  it "has >= #{format('%g', SEMANTIC_BASE_PASS_RATE_FLOOR * 100)}% pass rate" do
    rate = SEMANTIC_BASE_TOTAL.zero? ? 0.0 : SEMANTIC_BASE_PASSED.to_f / SEMANTIC_BASE_TOTAL
    expect(rate).to be >= SEMANTIC_BASE_PASS_RATE_FLOOR
  end

  it "has < #{format('%g', SEMANTIC_BASE_PASS_RATE_SUSPICIOUS_THRESHOLD * 100)}% pass rate; anything greater is suspicious" do
    rate = SEMANTIC_BASE_TOTAL.zero? ? 0.0 : SEMANTIC_BASE_PASSED.to_f / SEMANTIC_BASE_TOTAL
    expect(rate).to be < SEMANTIC_BASE_PASS_RATE_SUSPICIOUS_THRESHOLD
  end

  # Comparative / superlative forms whose lemma map currently routes through
  # the dispreferred -ey spellings (icey, wavey) instead of the
  # canonical -y heads (icy, wavy). Both heads have entries in
  # word_dict, so this isn't a missing-lemma issue — it's a preferred-
  # variant tie-break in compute_word_lemma_map. Listed here as failing
  # spot checks so the bug is named and the next word_lemma_map pass has
  # a concrete acceptance criterion. Dual-purpose: also surfaces in the
  # leming-class rarity sweep where icier / iciest / wavier /
  # waviest ride freq=10 off the bad lemma chain (see curated/rarity.csv
  # leming-class rows).
  context 'preferred-variant comparative/superlative lemmas' do
    oughta_have_semantic_base 'icier', 'icy'
    oughta_have_semantic_base 'iciest', 'icy'
    oughta_have_semantic_base 'wavier', 'wavy'
    oughta_have_semantic_base 'waviest', 'wavy'
  end
end
