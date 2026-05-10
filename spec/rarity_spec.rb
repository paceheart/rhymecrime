# Test word rarity expectations.
#
# Two layers of coverage live in this file:
#
#   1. A handful of hand-curated spot checks (the oughta_be_* helpers below)
#      — each generates a named rspec example so a regression on a specific
#      well-known word fails loudly with a self-explanatory test name.
#
#   2. A full sweep over every evaluable row in curated/rarity.csv, run inline
#      at file load (NOT as per-row rspec examples) — we puts a one-line
#      FAIL diagnostic per mismatch, then a single aggregate rspec example
#      gates the suite on the coverage floor + weighted-pass-rate floor. Same
#      shape as spec/semantic_base_spec.rb.
#
# Scoring (partial credit on mismatches; symmetric — false positives and
# false negatives are penalized equally):
#   exact match                                         -> 1.0
#   :rare   vs :forbidden (either direction)            -> 0.9
#   :common vs :rare      (either direction)            -> 0.1
#   :common vs :forbidden (either direction)            -> 0.0
#
# Weights: common / rare / forbidden rows weigh 3; *_ish rows weigh 1
# (so a strong row counts 3x an ish row toward the aggregate). Rows skipped:
# uncommon, *_no_rhymes, have_rhymes (no rarity-family expectation).

require_relative "test_utils"

# Aggregate-pass thresholds for the curated/rarity.csv sweep. Floor is the bar
# the suite must clear; the suspicious threshold is an upper-band sanity gate
# (a rate above it usually means the CSV has drifted toward the live predicate
# rather than the predicate genuinely improving).
RARITY_MIN_EVALUATED_ROWS = 2500
RARITY_PASS_RATE_FLOOR = 0.975
RARITY_PASS_RATE_SUSPICIOUS_THRESHOLD = 0.99

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

def oughta_be_common(word, important: true, not_working_reason: nil)
  test_name = "'#{word}' oughta be common"
  it test_name do
    skip_if_not_working(not_working_reason)
    msg = "'#{word}' oughta be common, but is #{rarity_category(word)} — #{rarity_status_line(word)}"
    msg += " (but it's not that big a deal)" unless important
    expect(rarity_category(word)).to eq(:common), msg
  end
end

def ought_not_be_common(word, important: true, not_working_reason: nil)
  test_name = "'#{word}' ought not be common"
  it test_name do
    skip_if_not_working(not_working_reason)
    msg = "'#{word}' ought not be common, but is: — #{rarity_status_line(word)}"
    msg += " (but it's not that big a deal)" unless important
    expect(rarity_category(word)).to_not eq(:common), msg
  end
end

def oughta_be_rare(word, important: true, not_working_reason: nil)
  test_name = "'#{word}' oughta be rare"
  it test_name do
    skip_if_not_working(not_working_reason)
    msg = "'#{word}' oughta be rare, but is #{rarity_category(word)} — #{rarity_status_line(word)}"
    msg += " (but it's not that big a deal)" unless important
    expect(rarity_category(word)).to eq(:rare), msg
  end
end

def oughta_be_forbidden(word, not_working_reason: nil)
  test_name = "'#{word}' oughta be forbidden"
  it test_name do
    skip_if_not_working(not_working_reason)
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

# Coarse rarity family for contradiction detection. foo and foo_ish (and
# foo_no_rhymes) all collapse to the same family, so listing a word as both
# common and common_ish is fine. have_rhymes is orthogonal to commonness
# (returns nil) and is excluded from the contradiction check.
def rarity_kind_family(kind)
  case kind.to_s.strip
  when "common", "common_ish", "common_no_rhymes" then :common
  when "rare", "rare_ish", "rare_no_rhymes" then :rare
  when "uncommon" then :uncommon
  when "forbidden", "forbidden_ish" then :forbidden
  when "have_rhymes" then nil
  end
end

# Group rarity.csv rows by word and return only those words whose rows
# disagree about the rarity family (e.g. ok listed as both forbidden and
# rare). Returns [[word, [{kind:, family:, line:, context:}, ...]], ...]
# sorted by word. foo/foo_ish pairs are NOT contradictions.
def find_contradictory_rarity_rows
  rows = load_rarity_csv_rows
  by_word = Hash.new { |h, k| h[k] = [] }
  rows.each_with_index do |row, i|
    family = rarity_kind_family(row["kind"])
    next if family.nil?
    by_word[row["word"].to_s] << {
      kind: row["kind"].to_s.strip,
      family: family,
      line: i + 2,
      context: rarity_csv_section_path_from_notes(row["notes"]),
    }
  end
  by_word
    .select { |_, occurrences| occurrences.map { |o| o[:family] }.uniq.size > 1 }
    .sort_by { |word, _| word }
end

# Group rarity.csv rows by word and return only those words that appear in
# more than one row. Returns [[word, [{kind:, line:, context:}, ...]], ...]
# sorted by word. Stricter than find_contradictory_rarity_rows: this also
# catches same-family multi-rows (e.g. a word listed both common and
# common_ish, or two forbidden rows under different contexts), which are
# bookkeeping noise rather than informative redundancy.
def find_redundant_rarity_rows
  rows = load_rarity_csv_rows
  by_word = Hash.new { |h, k| h[k] = [] }
  rows.each_with_index do |row, i|
    by_word[row["word"].to_s] << {
      kind: row["kind"].to_s.strip,
      line: i + 2,
      context: rarity_csv_section_path_from_notes(row["notes"]),
    }
  end
  by_word
    .select { |_, occurrences| occurrences.size > 1 }
    .sort_by { |word, _| word }
end

# Words that appear in BOTH curated/rarity.csv and the curated word-set file
# curated/<filename>. Returns [[word, [{kind:, line:, context:}, ...]], ...]
# sorted by word. Used to flag overlap with unrhymable_stop_words.txt /
# semantically_promiscuous.txt: those files have the final say at build /
# runtime, so any rarity.csv row for the same word is unreachable noise (and,
# in the common case, mints a stillborn pron-less BuildEntry in the
# common-list pass before unrhymable_scrub tombstones it).
def find_rarity_rows_overlapping_curated_set(filename)
  members = load_curated_word_set(filename)
  rows = load_rarity_csv_rows
  by_word = Hash.new { |h, k| h[k] = [] }
  rows.each_with_index do |row, i|
    word = row["word"].to_s
    next unless members.include?(word)
    by_word[word] << {
      kind: row["kind"].to_s.strip,
      line: i + 2,
      context: rarity_csv_section_path_from_notes(row["notes"]),
    }
  end
  by_word.sort_by { |word, _| word }
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

# Sweep curated/rarity.csv against live rarity_category. Returns
# [evaluated, total_weight, weighted_score] over rows we actually evaluated.
# Side effects: puts a one-line FAIL diagnostic per mismatch and a summary
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

    word = row["word"].to_s
    context = rarity_csv_section_path_from_notes(row["notes"])
    weight = rarity_row_weight(kind)
    actual = rarity_category(word)
    score = rarity_mismatch_score(expected, actual)

    evaluated += 1
    total_weight += weight
    weighted_score += weight * score
    if score == 1.0
      exact += 1
    elsif csv_sweep_verbose?
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
    oughta_be_forbidden 'parasailingses'
    oughta_be_forbidden 'skyey'
    oughta_be_forbidden 'tooken'
    oughta_be_forbidden 'e-mai'
    oughta_be_forbidden 'iii'
    oughta_be_forbidden 'the' # stop word
    oughta_be_forbidden 'alles'
    oughta_be_forbidden 'theyed'
    oughta_be_forbidden 'gots'
    oughta_be_forbidden 'nots'
    oughta_be_forbidden 'leming'
    
    oughta_be_rare 'blepharoplasty'
    oughta_be_rare 'wakefield'
    oughta_be_rare 'absquatulate'

    ought_not_be_common 'rikers'
    ought_not_be_common 'taw'
    ought_not_be_common 'sameer'

    oughta_be_common 'fiddler'
    oughta_be_common 'pirate'
    oughta_be_common 'cat'
    oughta_be_common 'crime'
    oughta_be_common 'geometry'
    oughta_be_common 'mitten'
    oughta_be_common 'finesse'
    oughta_be_common 'finessed'
    oughta_be_common 'enby'
    oughta_be_common 'enbies'
    oughta_be_common 'polycule'
  end

  context 'unicode' do
    oughta_be_forbidden '🌮'
    oughta_be_forbidden '🍇'
    oughta_be_forbidden '🧢'
  end

  context 'hyphens' do
    oughta_be_common 'so-so'
    oughta_be_forbidden 'soso'
    oughta_be_common 'nonplussed'
    oughta_be_forbidden 'non-plussed'
    oughta_be_rare 'state-of-the-art'
    oughta_be_forbidden 'stateoftheart'
    ought_not_be_common 'nt-a-car'
  end

  context 'initialisms' do
    ought_not_be_common 'uss'
    oughta_be_rare 'cia'
    oughta_be_rare 'fbi'
    oughta_be_rare 'abc'
    oughta_be_rare 'atm'
    oughta_be_rare 'cnn'
    oughta_be_rare 'gps'
    oughta_be_forbidden 'b-j'
    oughta_be_rare 'jfk'
    oughta_be_rare 'un'
    oughta_be_rare 'phd'
  end

  context 'acronyms' do
    oughta_be_common 'scuba'
    oughta_be_common 'laser'
  end

  # This is to verify that the classifier isn't training on the labels
  context 'words that do not appear in rarity.csv' do
    oughta_be_common 'elongated'
    oughta_be_rare 'doubtfire'
  end

  # Wiktionary/Kaikki paradigm-table overgenerates -s rows for every
  # gerund-as-noun lemma, so the dict gets bannings, pricings,
  # addressings, marketings etc. — none real corpus surfaces. The
  # wiktionary_overgenerated_gerund_plural? predicate in morphology/prefix_clusters.rb
  # demotes the shape to :rare at runtime; concrete bases (morning
  # noun.time, meeting noun.group, saving surface in WN) survive via the
  # gates inside that predicate.
  context 'wiktionary -ings overgeneration' do
    oughta_be_rare 'addressings'
    oughta_be_rare 'lendings'
    oughta_be_rare 'pennings'
    oughta_be_rare 'wranglings'
    oughta_be_common 'mornings' # noun.time base — predicate preserves
    oughta_be_common 'feelings' # surface in WN — predicate preserves
    oughta_be_common 'upswings' # explicit common override in rarity.csv
  end

  context "-in'" do
    oughta_be_forbidden "stin'"
  end

  # Wiktionary also pluralizes abstract -ness nominalizations
  # (abruptnesses, stiffnesses, goodnesses) — paradigm-table noise that
  # English never produces. wiktionary_overgenerated_abstract_nesses_plural?
  # in morphology/curated_rarity.rb forbids these via explicitly_forbidden?; concrete
  # -ness surfaces (baronesses, base baroness noun.person) survive via
  # the WN concreteness gate.
  context 'wiktionary -nesses overgeneration' do
    oughta_be_forbidden 'abruptnesses'
    oughta_be_forbidden 'stiffnesses'
    oughta_be_forbidden 'goodnesses'
    oughta_be_forbidden 'blandnesses'
    oughta_be_common 'baronesses' # noun.person base — predicate preserves
  end

  context "overpluralization" do
    oughta_be_forbidden 'ccses'
    oughta_be_forbidden 'cdses'
    oughta_be_forbidden 'idses'
    oughta_be_forbidden 'tolds'
  end

  context '-ed overgeneration' do
    oughta_be_forbidden 'aied'
  end

  context "csv sweep (curated/rarity.csv)" do
    it "covers >= #{RARITY_MIN_EVALUATED_ROWS} rows" do
      expect(RARITY_EVALUATED).to be >= RARITY_MIN_EVALUATED_ROWS
    end

    it "has >= #{format('%g', RARITY_PASS_RATE_FLOOR * 100)}% weighted pass rate" do
      rate = RARITY_TOTAL_WEIGHT.positive? ? RARITY_WEIGHTED_SCORE / RARITY_TOTAL_WEIGHT : 0.0
      expect(rate).to be >= RARITY_PASS_RATE_FLOOR
    end

    it "has < #{format('%g', RARITY_PASS_RATE_SUSPICIOUS_THRESHOLD * 100)}% weighted pass rate; anything greater is suspicious" do
      rate = RARITY_TOTAL_WEIGHT.positive? ? RARITY_WEIGHTED_SCORE / RARITY_TOTAL_WEIGHT : 0.0
      expect(rate).to be >= RARITY_PASS_RATE_SUSPICIOUS_THRESHOLD
    end

    it "has no contradictory rows" do
      contradictions = find_contradictory_rarity_rows
      contradictions.each do |word, occurrences|
        details = occurrences
          .map { |o| "line #{o[:line]} (#{o[:context]}): #{o[:kind]}" }
          .join("; ")
        puts "CONTRADICTION #{word.inspect}: #{details}"
      end
      expect(contradictions).to be_empty,
        "found #{contradictions.size} contradictory word(s) in curated/rarity.csv " \
        "(same word listed with disagreeing rarity families; see CONTRADICTION lines above)"
    end

    it "has no redundant rows" do
      redundancies = find_redundant_rarity_rows
      redundancies.each do |word, occurrences|
        details = occurrences
          .map { |o| "line #{o[:line]} (#{o[:context]}): #{o[:kind]}" }
          .join("; ")
        puts "REDUNDANT #{word.inspect}: #{details}"
      end
      expect(redundancies).to be_empty,
        "found #{redundancies.size} redundant word(s) in curated/rarity.csv " \
        "(same word listed in more than one row; see REDUNDANT lines above)"
    end

    it "has no rows for words also in unrhymable_stop_words.txt" do
      overlaps = find_rarity_rows_overlapping_curated_set(UNRHYMABLE_STOP_WORDS_FILENAME)
      overlaps.each do |word, occurrences|
        details = occurrences
          .map { |o| "line #{o[:line]} (#{o[:context]}): #{o[:kind]}" }
          .join("; ")
        puts "UNRHYMABLE_OVERLAP #{word.inspect}: #{details}"
      end
      expect(overlaps).to be_empty,
        "found #{overlaps.size} word(s) listed in both curated/rarity.csv and " \
        "curated/#{UNRHYMABLE_STOP_WORDS_FILENAME} (the stop-word list has the " \
        "final say at build time, so the rarity.csv row is unreachable; see " \
        "UNRHYMABLE_OVERLAP lines above)"
    end

    it "has no rows for words also in semantically_promiscuous.txt" do
      overlaps = find_rarity_rows_overlapping_curated_set(SEMANTICALLY_PROMISCUOUS_FILENAME)
      overlaps.each do |word, occurrences|
        details = occurrences
          .map { |o| "line #{o[:line]} (#{o[:context]}): #{o[:kind]}" }
          .join("; ")
        puts "PROMISCUOUS_OVERLAP #{word.inspect}: #{details}"
      end
      expect(overlaps).to be_empty,
        "found #{overlaps.size} word(s) listed in both curated/rarity.csv and " \
        "curated/#{SEMANTICALLY_PROMISCUOUS_FILENAME} (promiscuous membership " \
        "trumps rarity-family labels at build time; see PROMISCUOUS_OVERLAP " \
        "lines above)"
    end
  end
end
