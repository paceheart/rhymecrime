# Thematic relatedness expectations against the live directional predicate.
# Examples live in curated/related.csv: (cue, related, oughta be related?, notes).
#
# thematically_related?(cue, related) is **directional** — "is related a
# thematic associate of cue?". The Store path (RelatedWords.pair_in_store?)
# and the live compute path (PairSignals → learned classifier + rules) both
# respect that orientation; the spec evaluates rows in the labeled (cue, related)
# direction, not symmetrized. Set RELATED_BYPASS_STORE=1 to skip the Store and
# always run the live compute pipeline (e.g. after retraining when the Store
# might be stale).
#
# Two layers of coverage live in this file:
#
#   1. Hand-curated spot checks (the oughta_be_related / ought_not_be_related
#      / related_words_ought_not_include helpers below) — each generates a
#      named rspec example so a regression on a specific well-known pair fails
#      loudly with a self-explanatory test name.
#
#   2. A full sweep over every evaluable row in curated/related.csv, run inline
#      at file load (NOT as per-row rspec examples) — we puts a one-line FAIL
#      diagnostic per mismatch, then a single aggregate rspec example gates the
#      suite on the coverage floor + weighted-pass-rate floor. Same shape as
#      spec/semantic_base_spec.rb and spec/rarity_spec.rb.
#
# Scoring: each row contributes weight when the predicate matches and 0 when
# it doesn't. Weights: related / unrelated rows weigh 3; related_ish /
# unrelated_ish rows weigh 1 (so a strong row counts 3× an ish row toward
# the aggregate). False positives and false negatives are treated equally
# within each weight tier — class-balanced (this is independent of the
# (cue, related) orientation, which is asymmetric and preserved per row).
# Rows skipped: whatever and pairs where either side is a stop word
# (thematically_related? short-circuits stop-word pairs to true, so they
# would be unavoidable FPs that say nothing about the classifier).

require_relative 'test_utils'

# Aggregate-pass thresholds for the curated/related.csv sweep.
RELATED_MIN_EVALUATED_ROWS = 9000
RELATED_PASS_RATE_FLOOR = 0.85
RELATED_PASS_RATE_SUSPICIOUS = 0.99

# --- Spot-check helpers (one rspec example per call; for hand-curated cases). ---

def oughta_be_related(word1, word2, not_working_reason: nil)
  test_name = "'#{word1}' oughta be related to '#{word2}'"
  it test_name do
    skip_if_not_working(not_working_reason)
    sim = similarity(word1, word2).round
    expect(thematically_related?(word1, word2, false)).to eql(true), "'#{word1}' / '#{word2}': expected related but thematically_related? was false. similarity=#{sim} (stored relatedness score, threshold #{RELATEDNESS_SCORE_THRESHOLD}); gloss/sense-vector/USF paths can still pass when sim is lower. #{debug_info(word1)} / #{debug_info(word2)}"
  end
end

def ought_not_be_related(word1, word2, not_working_reason: nil)
  test_name = "'#{word1}' ought not be related to '#{word2}'"
  it test_name do
    skip_if_not_working(not_working_reason)
    sim = similarity(word1, word2).round
    expect(thematically_related?(word1, word2, false)).to eql(false), "'#{word1}' / '#{word2}': expected unrelated but thematically_related? was true. similarity=#{sim} (stored relatedness score, threshold #{RELATEDNESS_SCORE_THRESHOLD}). If sim is below threshold, a rescue path matched (WordNet gloss containment, sense vectors, or USF two-hop). #{debug_info(word1)} / #{debug_info(word2)}"
  end
end

def related_words_ought_not_include(word1, word2, not_working_reason: nil)
  test_name = "'Words related to #{word1}' ought not include '#{word2}'"
  it test_name do
    skip_if_not_working(not_working_reason)
    related_words = find_related_words(word1, false, false, nil)
    expect(related_words.include?(word2)).to eql(false), "Words related to '#{word1}' ought not include '#{word2}', but they do: #{related_words}"
  end
end

# --- CSV sweep helpers (every evaluable row in curated/related.csv). ---

def relatedness_row_weight(kind)
  relatedness_kind_ish?(kind) ? 1 : 3
end

# true iff either side of the pair (surface or lemma) is semantically
# promiscuous — thematically_related? short-circuits those pairs to true
# regardless of what the classifier would say, so they tell us nothing about
# predicate quality. Mirrors the trainer's load-time filter.
def relatedness_row_promiscuous_filtered?(row)
  cue = row["cue"]
  rel = row["related"]
  return true if cue.nil? || rel.nil?
  semantically_promiscuous?(cue) || semantically_promiscuous?(rel) || semantically_promiscuous?(lemma(cue)) || semantically_promiscuous?(lemma(rel))
end

# Sweep curated/related.csv against the live directional thematically_related?
# predicate. Returns [evaluated, total_weight, weighted_correct] over rows we
# actually evaluated. Side effects: puts a one-line FAIL diagnostic per
# mismatch and a summary line.
#
# Skipped: whatever rows (either answer acceptable), stop-word pairs (predicate
# short-circuits them to true), and the rare row with empty cue/related cells.
def evaluate_relatedness_csv
  rows = load_relatedness_test_cases

  evaluated = 0
  total_weight = 0.0
  weighted_correct = 0.0
  filtered_stopword = 0
  skipped_whatever = 0
  exact = 0

  rows.each_with_index do |row, i|
    if relatedness_row_promiscuous_filtered?(row)
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
    elsif csv_sweep_verbose?
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

# Memoized accessor for evaluate_relatedness_csv. Lazy + per-process so
# rspec runs that don't touch the csv sweep context (e.g. rspec
# spec/rhyme_spec.rb, which still loads this file because of the default
# spec/**/*_spec.rb pattern) skip the 10k-row thematically_related? sweep
# entirely. Used to be assigned to RELATED_* module constants at file load,
# which made every rspec invocation in the repo pay the ~10s sweep cost.
$related_csv_sweep_results = nil
def related_csv_sweep_results
  $related_csv_sweep_results ||= evaluate_relatedness_csv
end

$related_csv_sweep_results_without_overrides = nil
def related_csv_sweep_results_without_overrides
  return $related_csv_sweep_results_without_overrides if $related_csv_sweep_results_without_overrides

  override_key = Rhymecrime::Env::RELATED_CSV_OVERRIDE_ENV
  old_override = ENV[override_key]
  old_bypass = ENV["RELATED_BYPASS_STORE"]
  begin
    ENV[override_key] = "0"
    ENV["RELATED_BYPASS_STORE"] = "1"
    reset_curated_relatedness_overrides! if defined?(reset_curated_relatedness_overrides!)
    $thematically_related_memo = nil if defined?($thematically_related_memo)
    $related_csv_sweep_results_without_overrides = evaluate_relatedness_csv
  ensure
    old_bypass.nil? ? ENV.delete("RELATED_BYPASS_STORE") : ENV["RELATED_BYPASS_STORE"] = old_bypass
    old_override.nil? ? ENV.delete(override_key) : ENV[override_key] = old_override
    reset_curated_relatedness_overrides! if defined?(reset_curated_relatedness_overrides!)
    $thematically_related_memo = nil if defined?($thematically_related_memo)
  end
end

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

    # Underlying directional thematically_related?(cue, related) assertions for
    # every currently-failing set_related / pair_related example in
    # spec/similar_rhymes_spec.rb. Each subcontext here mirrors one
    # similar_rhymes failure and adds the two prereq pairs the spec depends on,
    # so a relatedness regression fails loudly *here* (named, focused) instead
    # of as opaque tuple-search misses in the much-slower similar_rhymes spec.
    # When a similar_rhymes test fails but both prereqs here pass, the failure
    # is downstream of relatedness (lemma-collapse, stress-mismatch, prefix
    # filter, cross-tuple pruning, ...). When a prereq fails, that's the bug.
    context 'similar_rhymes prereqs' do
      context 'set_related: pirate -> seagull / illegal' do
        oughta_be_related 'pirate', 'seagull'
        oughta_be_related 'pirate', 'illegal'
      end
      context 'set_related: pirate -> shore / tor' do
        oughta_be_related 'pirate', 'shore'
        oughta_be_related 'pirate', 'tor', not_working_reason: "predictor gap: similarity=0; 'tor' (rocky peak) is too rare for the embeddings"
      end
      context 'set_related: pirate -> crude / pursued' do
        oughta_be_related 'pirate', 'crude'
        oughta_be_related 'pirate', 'pursued'
      end
      context 'set_related: music -> enjoys / noise' do
        oughta_be_related 'music', 'enjoys'
        oughta_be_related 'music', 'noise'
      end
      context 'set_related: music -> audition / composition' do
        oughta_be_related 'music', 'audition'
        oughta_be_related 'music', 'composition'
      end
      context 'set_related: music -> composition* / musician*' do
        oughta_be_related 'music', 'composition'
        oughta_be_related 'music', 'musician'
      end
      context 'set_related: music -> glissando / ritardando' do
        oughta_be_related 'music', 'glissando'
        oughta_be_related 'music', 'ritardando'
      end
      context 'set_related: music -> viola / hemiola' do
        oughta_be_related 'music', 'viola'
        oughta_be_related 'music', 'hemiola'
      end
      context 'set_related: music -> rest / expressed' do
        oughta_be_related 'music', 'rest'
        oughta_be_related 'music', 'expressed'
      end
      context 'set_related: music -> fortissimo / pianissimo' do
        oughta_be_related 'music', 'fortissimo'
        oughta_be_related 'music', 'pianissimo'
      end
      # Negative similar_rhymes assertion. Both halves *are* music-related — the
      # exclusion is a downstream filter (likely homophone-like coda overlap),
      # not a relatedness call. These predicates ought to return true.
      context 'set_related: music !-> bass / brass' do
        oughta_be_related 'music', 'bass'
        oughta_be_related 'music', 'brass'
      end
      context 'set_related: water -> marine / saline' do
        oughta_be_related 'water', 'marine'
        oughta_be_related 'water', 'saline'
      end
      context 'set_related: prayers -> addressed / blessed' do
        oughta_be_related 'prayers', 'addressed', not_working_reason: "predictor gap: similarity=0; 'addressed' (as in 'addressed prayers') is functional, embeddings miss it"
        oughta_be_related 'prayers', 'blessed'
      end
      context 'set_related: prayers -> blessed / request' do
        oughta_be_related 'prayers', 'blessed'
        oughta_be_related 'prayers', 'request'
      end
      context 'set_related: prayers -> recite* / rite*' do
        oughta_be_related 'prayers', 'recite'
        oughta_be_related 'prayers', 'rite'
      end
      context 'set_related: magic -> chants / trance' do
        oughta_be_related 'magic', 'chants'
        oughta_be_related 'magic', 'trance'
      end
      context 'set_related: medicine -> disease / expertise' do
        oughta_be_related 'medicine', 'disease'
        oughta_be_related 'medicine', 'expertise'
      end
      context 'set_related: exploration -> knapsack / backtrack' do
        oughta_be_related 'exploration', 'knapsack', not_working_reason: "predictor gap: similarity=0; 'knapsack' (explorer's gear) embeddings miss the exploration connection"
        oughta_be_related 'exploration', 'backtrack'
      end
      context 'set_related: carbon -> ester / sequester' do
        oughta_be_related 'carbon', 'ester'
        oughta_be_related 'carbon', 'sequester'
      end
      context 'set_related: carbon -> extract / react' do
        oughta_be_related 'carbon', 'extract'
        oughta_be_related 'carbon', 'react'
      end
      # Negative similar_rhymes assertion. The inflected forms extracted /
      # reacted remain chemistry-relevant and ought to be related to carbon
      # — the exclusion is lemma-collapse vs. the extract / react pair,
      # not relatedness. These predicates ought to return true.
      context 'set_related: carbon !-> extracted / reacted' do
        oughta_be_related 'carbon', 'extracted'
        oughta_be_related 'carbon', 'reacted'
      end
      context 'set_related: cat -> arboreal / territorial' do
        oughta_be_related 'cat', 'arboreal'
        oughta_be_related 'cat', 'territorial'
      end
      context 'pair_related: food / evil -> mushroom / doom' do
        oughta_be_related 'food', 'mushroom'
        oughta_be_related 'evil', 'doom'
      end
      context 'pair_related: food / evil -> chips / apocalypse' do
        oughta_be_related 'food', 'chips'
        oughta_be_related 'evil', 'apocalypse'
      end
      context 'pair_related: food / evil -> starvation / abomination' do
        oughta_be_related 'food', 'starvation'
        oughta_be_related 'evil', 'abomination'
      end
      # Negative similar_rhymes assertion. produce (noun) is food and abuse
      # is evil-adjacent — the exclusion is most likely a noun/verb stress
      # mismatch in the homograph pronunciations, not a relatedness call.
      context 'pair_related: food / evil !-> produce / abuse' do
        oughta_be_related 'food', 'produce'
        oughta_be_related 'evil', 'abuse'
      end
      context 'pair_related: food / dark -> ration / ashen' do
        oughta_be_related 'food', 'ration'
        oughta_be_related 'dark', 'ashen'
      end
      context 'pair_related: fashion / music -> avant-garde / bard' do
        oughta_be_related 'fashion', 'avant-garde'
        oughta_be_related 'music', 'bard'
      end
    end
  end

  context 'csv sweep (curated/related.csv)' do
    it "it's over #{RELATED_MIN_EVALUATED_ROWS}!!!!! (the row count, that is)" do
      evaluated, _total_weight, _weighted_correct = related_csv_sweep_results
      expect(evaluated).to be > RELATED_MIN_EVALUATED_ROWS
    end

    it "has >= #{format('%g', RELATED_PASS_RATE_FLOOR * 100)}% weighted pass rate" do
      _evaluated, total_weight, weighted_correct = related_csv_sweep_results
      rate = total_weight.positive? ? weighted_correct / total_weight : 0.0
      expect(rate).to be >= RELATED_PASS_RATE_FLOOR
    end

    # Verify the raw classifier/rules are not simply memorizing curated labels.
    # The default runtime predicate intentionally applies curated/related.csv
    # overrides now, so this guard disables them for the diagnostic sweep.
    it "has < #{format('%g', RELATED_PASS_RATE_SUSPICIOUS * 100)}% weighted pass rate without curated overrides" do
      _evaluated, total_weight, weighted_correct = related_csv_sweep_results_without_overrides
      rate = total_weight.positive? ? weighted_correct / total_weight : 0.0
      expect(rate).to be < RELATED_PASS_RATE_SUSPICIOUS
    end
  end
end
