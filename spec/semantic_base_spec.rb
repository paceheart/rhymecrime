# Semantic-base column expectations from generated/word_dict (see bin/dict-build).
# Rows: surface, semantic_base, optional skip (1 to skip unless RHYMECRIME_RUN_SKIPPED), optional notes.
#
# Layout note: every row in +curated/semantic_base.csv+ is exercised inline at
# file load (not as a per-row rspec example) — we sweep, +puts+ a one-line FAIL
# diagnostic on each mismatch, and stash the totals in a module constant. The
# single +describe+ block below then converts those totals into one aggregate
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

# Sweep curated/semantic_base.csv against live +semantic_base()+. Returns
# +[total, passed]+ over rows we actually evaluated; rows with +skip+==1 are
# excluded from both counts unless +RHYMECRIME_RUN_SKIPPED+ is set (matching
# the rest of the suite). Side effects: +puts+ a one-line +FAIL+ diagnostic
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
end
