# Test word rarity expectations.
#
# Two layers of coverage live in this file:
#
#   1. A handful of hand-curated spot checks (the +oughta_be_*+ helpers below)
#      — each generates a named rspec example so a regression on a specific
#      well-known word fails loudly with a self-explanatory test name.
#
#   2. A full sweep over every evaluable row in curated/rarity.csv, run inline
#      at file load (NOT as per-row rspec examples) — we +puts+ a one-line
#      +FAIL+ diagnostic per mismatch, then a single aggregate rspec example
#      gates the suite on the coverage floor + weighted-pass-rate floor. Same
#      shape as +spec/lemma_spec.rb+.
#
# Scoring (partial credit on mismatches; symmetric — false positives and
# false negatives are penalized equally):
#   exact match                                         -> 1.0
#   :rare   vs :forbidden (either direction)            -> 0.9
#   :common vs :rare      (either direction)            -> 0.1
#   :common vs :forbidden (either direction)            -> 0.0
#
# Weights: +common+ / +rare+ / +forbidden+ rows weigh 3; +*_ish+ rows weigh 1
# (so a strong row counts 3x an ish row toward the aggregate). Rows skipped:
# +uncommon+, +*_no_rhymes+, +have_rhymes+, and CSV +skip+=1 (unless
# +RHYMECRIME_RUN_SKIPPED=1+).

require_relative "test_utils"

def allowed?(word)
  !explicitly_forbidden?(word) && word_dict.key?(word)
end

# Coarse bucket for expectations: not allowed for use (:forbidden) vs allowed
# and rare vs common.
def rarity_category(word)
  return :forbidden unless allowed?(word)
  rare?(word) ? :rare : :common
end

# Human-readable state for FAIL-line diagnostics and per-example failure messages.
def rarity_status_line(word)
  f = frequency(word)
  case rarity_category(word)
  when :forbidden
    if explicitly_forbidden?(word)
      "explicitly_forbidden, frequency #{f}"
    elsif !word_dict.key?(word)
      "not in word_dict (frequency #{f})"
    else
      "not allowed, frequency #{f}"
    end
  when :rare
    "in word_dict, frequency #{f}, rare"
  when :common
    "in word_dict, frequency #{f}, common"
  end
end

# --- Spot-check helpers (one rspec example per call; for hand-curated cases
# where a named regression is more useful than a row in rarity.csv). ---

def oughta_be_common(word, important: true, not_working_message: nil)
  test_name = "'#{word}' oughta be common"
  it test_name do
    skip_if_not_working(not_working_message)
    msg = "'#{word}' oughta be common, but is #{rarity_category(word)} — #{rarity_status_line(word)}"
    msg += " (but it's not that big a deal)" unless important
    expect(rarity_category(word)).to eq(:common), msg
  end
end

def ought_not_be_common(word, important: true, not_working_message: nil)
  test_name = "'#{word}' ought not be common"
  it test_name do
    skip_if_not_working(not_working_message)
    msg = "'#{word}' ought not be common, but is: — #{rarity_status_line(word)}"
    msg += " (but it's not that big a deal)" unless important
    expect(rarity_category(word)).to_not eq(:common), msg
  end
end

def oughta_be_rare(word, important: true, not_working_message: nil)
  test_name = "'#{word}' oughta be rare"
  it test_name do
    skip_if_not_working(not_working_message)
    msg = "'#{word}' oughta be rare, but is #{rarity_category(word)} — #{rarity_status_line(word)}"
    msg += " (but it's not that big a deal)" unless important
    expect(rarity_category(word)).to eq(:rare), msg
  end
end

def oughta_be_forbidden(word, not_working_message: nil)
  test_name = "'#{word}' oughta be forbidden"
  it test_name do
    skip_if_not_working(not_working_message)
    msg = "'#{word}' oughta be forbidden, but is #{rarity_category(word)} — #{rarity_status_line(word)}"
    expect(rarity_category(word)).to eq(:forbidden), msg
  end
end

# --- CSV sweep helpers (all rows in curated/rarity.csv, evaluated inline). ---

def expected_category_for_kind(kind)
  case kind.to_s.strip
  when "common", "common_ish" then :common
  when "rare", "rare_ish" then :rare
  when "forbidden", "forbidden_ish" then :forbidden
  end
end

# Symmetric mismatch scoring — no FN/FP discount. Returns 1.0 on exact match,
# else a partial-credit base in [0.0, 0.9] depending on how far apart the two
# categories are on the rare/common/forbidden spectrum.
def rarity_mismatch_score(expected, actual)
  return 1.0 if expected == actual

  cats = [expected, actual].sort_by(&:to_s)
  case cats
  when %i[common forbidden] then 0.0
  when %i[common rare] then 0.1
  when %i[forbidden rare] then 0.9
  else
    raise "unexpected category pair: #{expected.inspect} vs #{actual.inspect}"
  end
end

def rarity_row_weight(kind)
  kind.to_s.strip.end_with?("_ish") ? 1 : 3
end

# Sweep curated/rarity.csv against live +rarity_category+. Returns
# +[evaluated, total_weight, weighted_score]+ over rows we actually evaluated.
# Side effects: +puts+ a one-line +FAIL+ diagnostic per mismatch and a summary
# line.
def evaluate_rarity_csv
  rows = load_rarity_csv_rows
  rows.each_with_index { |row, i| validate_rarity_csv_row!(row, "line #{i + 2}") }

  evaluated = 0
  total_weight = 0.0
  weighted_score = 0.0
  exact = 0

  rows.each_with_index do |row, i|
    kind = row["kind"].to_s
    expected = expected_category_for_kind(kind)
    next if expected.nil?

    skip = row["skip"].to_s.strip == "1"
    next if skip && !rhymecrime_run_skipped_examples?

    word = row["word"].to_s
    context = row["context"].to_s
    weight = rarity_row_weight(kind)
    actual = rarity_category(word)
    score = rarity_mismatch_score(expected, actual)

    evaluated += 1
    total_weight += weight
    weighted_score += weight * score
    if score == 1.0
      exact += 1
    else
      puts format(
        "FAIL %s -> %s (oughta be %s, score=%.2f, line %d, %s — %s)",
        word.inspect, actual, kind, score, i + 2, context, rarity_status_line(word)
      )
    end
  end

  pct = total_weight.positive? ? (100.0 * weighted_score / total_weight) : 0.0
  puts format(
    "curated/rarity.csv: %.2f%% weighted (%d evaluated, %d exact, %d partial/zero, weighted score %.4f / weight %.0f)",
    pct, evaluated, exact, evaluated - exact, weighted_score, total_weight
  )

  [evaluated, total_weight, weighted_score]
end

RARITY_EVALUATED, RARITY_TOTAL_WEIGHT, RARITY_WEIGHTED_SCORE = evaluate_rarity_csv

describe "RARITY" do
  context "spot checks" do
    oughta_be_forbidden 'gypsy'
    oughta_be_forbidden 'aosidhgjqoerigh'
    oughta_be_forbidden 'imagineeringes'
    oughta_be_forbidden 'skyey'
    oughta_be_forbidden 'tooken'
    oughta_be_forbidden 'e-mai'
    oughta_be_forbidden 'iii'
    oughta_be_forbidden 'the' # stop word

    oughta_be_rare 'blepharoplasty'
    oughta_be_rare 'wakefield'
    oughta_be_rare 'absquatulate'

    ought_not_be_common 'rikers'
    ought_not_be_common 'taw'

    oughta_be_common 'fiddler'
    oughta_be_common 'pirate'
    oughta_be_common 'cat'
    oughta_be_common 'crime'
    oughta_be_common 'geometry'
    oughta_be_common 'mitten'
    oughta_be_common 'finesse'
    oughta_be_common 'finessed'
  end

  context 'unicode' do
    oughta_be_forbidden '🌮'
    oughta_be_forbidden '🍇'
    oughta_be_forbidden '🧢'
  end

  context "csv sweep (curated/rarity.csv)" do
    it "covers >= 1000 rows at >= 97.5% weighted pass rate" do
      expect(RARITY_EVALUATED).to be >= 2500
      rate = RARITY_TOTAL_WEIGHT.positive? ? RARITY_WEIGHTED_SCORE / RARITY_TOTAL_WEIGHT : 0.0
      expect(rate).to be >= 0.97
    end
  end
end
