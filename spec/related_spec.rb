# Thematic relatedness expectations against the live directional predicate.
# Examples live in curated/related.csv: (cue, related, oughta be related?, notes).
#
# +thematically_related?(cue, related)+ is **directional** — "is +related+ a
# thematic associate of +cue+?". The Store path (+RelatedWords.pair_in_store?+)
# and the live compute path (+PairSignals+ → learned classifier + rules) both
# respect that orientation; the spec evaluates rows in the labeled +(cue, related)+
# direction, not symmetrized. Set +RELATED_BYPASS_STORE=1+ to skip the Store and
# always run the live compute pipeline (e.g. after retraining when the Store
# might be stale).
#
# Two layers of coverage live in this file:
#
#   1. Hand-curated spot checks (the +oughta_be_related+ / +ought_not_be_related+
#      / +related_words_ought_not_include+ helpers below) — each generates a
#      named rspec example so a regression on a specific well-known pair fails
#      loudly with a self-explanatory test name.
#
#   2. A full sweep over every evaluable row in curated/related.csv, run inline
#      at file load (NOT as per-row rspec examples) — we +puts+ a one-line +FAIL+
#      diagnostic per mismatch, then a single aggregate rspec example gates the
#      suite on the coverage floor + weighted-pass-rate floor. Same shape as
#      +spec/lemma_spec.rb+ and +spec/rarity_spec.rb+.
#
# Scoring: each row contributes +weight+ when the predicate matches and 0 when
# it doesn't. Weights: +related+ / +unrelated+ rows weigh 3; +related_ish+ /
# +unrelated_ish+ rows weigh 1 (so a strong row counts 3× an ish row toward
# the aggregate). False positives and false negatives are treated equally
# within each weight tier — class-balanced (this is independent of the
# +(cue, related)+ orientation, which is asymmetric and preserved per row).
# Rows skipped: +whatever+ and pairs where either side is a stop word
# (+thematically_related?+ short-circuits stop-word pairs to +true+, so they
# would be unavoidable FPs that say nothing about the classifier).

require_relative 'test_utils'

# --- Spot-check helpers (one rspec example per call; for hand-curated cases). ---

def oughta_be_related(word1, word2, not_working_message: nil)
  test_name = "'#{word1}' oughta be related to '#{word2}'"
  it test_name do
    skip_if_not_working(not_working_message)
    sim = similarity(word1, word2).round
    expect(related?(word1, word2, false)).to eql(true), "'#{word1}' / '#{word2}': expected related but related? was false. similarity=#{sim} (Numberbatch+ConceptNet centiles, threshold #{similarity_threshold()}); gloss/sense-vector/USF paths can still pass when sim is lower. #{debug_info(word1)} / #{debug_info(word2)}"
  end
end

def ought_not_be_related(word1, word2, not_working_message: nil)
  test_name = "'#{word1}' ought not be related to '#{word2}'"
  it test_name do
    skip_if_not_working(not_working_message)
    sim = similarity(word1, word2).round
    expect(related?(word1, word2, false)).to eql(false), "'#{word1}' / '#{word2}': expected unrelated but related? was true. similarity=#{sim} (threshold #{similarity_threshold()}). If sim is below threshold, a rescue path matched (WordNet gloss containment, sense vectors, or USF two-hop). #{debug_info(word1)} / #{debug_info(word2)}"
  end
end

def related_words_ought_not_include(word1, word2, not_working_message: nil)
  test_name = "'Words related to #{word1}' ought not include '#{word2}'"
  it test_name do
    skip_if_not_working(not_working_message)
    related_words = find_related_words(word1, false, false, nil)
    expect(related_words.include?(word2)).to eql(false), "Words related to '#{word1}' ought not include '#{word2}', but they do: #{related_words}"
  end
end

# --- CSV sweep helpers (every evaluable row in curated/related.csv). ---

def relatedness_row_weight(kind)
  relatedness_kind_ish?(kind) ? 1 : 3
end

# +true+ iff either side of the pair (surface or lemma) is a stop word —
# +thematically_related?+ short-circuits those pairs to +true+ regardless of
# what the classifier would say, so they tell us nothing about predicate
# quality. Mirrors the trainer's load-time filter.
def relatedness_row_stop_word_filtered?(row)
  cue = row["cue"]
  rel = row["related"]
  return true if cue.nil? || rel.nil?
  stop_word?(cue) || stop_word?(rel) || stop_word?(lemma(cue)) || stop_word?(lemma(rel))
end

# Sweep curated/related.csv against the live directional +thematically_related?+
# predicate. Returns +[evaluated, total_weight, weighted_correct]+ over rows we
# actually evaluated. Side effects: +puts+ a one-line +FAIL+ diagnostic per
# mismatch and a summary line.
#
# Skipped: +whatever+ rows (either answer acceptable), stop-word pairs (predicate
# short-circuits them to +true+), and the rare row with empty cue/related cells.
def evaluate_relatedness_csv
  rows = load_relatedness_test_cases

  evaluated = 0
  total_weight = 0.0
  weighted_correct = 0.0
  filtered_stopword = 0
  skipped_whatever = 0
  exact = 0

  rows.each_with_index do |row, i|
    if relatedness_row_stop_word_filtered?(row)
      filtered_stopword += 1
      next
    end

    kind = row["oughta be related?"].to_s.strip
    expected = relatedness_expected_boolean(kind)
    if expected.nil?
      skipped_whatever += 1
      next
    end

    cue = row["cue"]
    rel = row["related"]
    weight = relatedness_row_weight(kind)
    actual = thematically_related?(cue, rel, false)

    evaluated += 1
    total_weight += weight
    if actual == expected
      weighted_correct += weight
      exact += 1
    else
      notes = row["notes"].to_s.strip
      notes_excerpt = notes.empty? ? "" : ", #{notes[0, 60]}"
      puts format(
        "FAIL %s -> %s (oughta be %s, line %d%s) [%s -> %s]",
        "#{cue.inspect} / #{rel.inspect}", actual, kind, i + 2, notes_excerpt,
        cue, rel
      )
    end
  end

  pct = total_weight.positive? ? (100.0 * weighted_correct / total_weight) : 0.0
  puts format(
    "curated/related.csv: %.2f%% weighted (%d evaluated, %d exact, %d wrong, weighted score %.0f / weight %.0f; %d stop-word pairs filtered, %d whatever skipped)",
    pct, evaluated, exact, evaluated - exact, weighted_correct, total_weight,
    filtered_stopword, skipped_whatever
  )

  [evaluated, total_weight, weighted_correct]
end

RELATED_EVALUATED, RELATED_TOTAL_WEIGHT, RELATED_WEIGHTED_CORRECT = evaluate_relatedness_csv

describe 'RELATED' do
  context 'spot checks' do
    context 'reflexivity' do
      related_words_ought_not_include 'death', 'death'
    end

    context 'slurs are forbidden' do
      related_words_ought_not_include 'gypsy', 'romanian'
      related_words_ought_not_include 'gypsies', 'romanian'
      related_words_ought_not_include 'romanian', 'gypsy'
      related_words_ought_not_include 'romanian', 'gypsies'
    end
  end

  context 'csv sweep (curated/related.csv)' do
    it 'covers > 9000 rows at >= 90% weighted pass rate' do
      expect(RELATED_EVALUATED).to be > 9000
      rate = RELATED_TOTAL_WEIGHT.positive? ? RELATED_WEIGHTED_CORRECT / RELATED_TOTAL_WEIGHT : 0.0
      expect(rate).to be >= 0.90
    end
  end
end
