#!/usr/bin/env ruby
# coding: utf-8
#
# relatedness/score.rb — offline relatedness scoring (phases 2 + 3 of the pipeline).
#
# Requires +relatedness/signals+ first (for +PairSignals+, +learned_feature_vector+'s
# unigram helpers, and every knowledge base the rules consult). Provides:
#
#   - +learned_feature_vector+ + +LEARNED_FEATURE_NAMES+ — the classifier's input.
#   - +relatedness_classifier+ + +learned_relatedness_{probability,score}+ — GBT /
#     logistic regression over phase-1 signals, loaded from
#     +generated/relatedness_classifier.json+.
#   - +relatedness_contributions+ + +relatedness_score+ — hand-tuned rule bundle
#     (plus the learned score in +additive+ / +replace+ modes) that composes phase-1
#     signals into an integer 0..100.
#   - +thematically_related_pair_uncached?+ + +..._memoized?+ — the predicate at
#     +RELATEDNESS_SCORE_THRESHOLD+, symmetric in +(a, b)+, memoized by lemma pair.
#
# Not required at Lambda runtime. The runtime shim in +lib/rhymecrime/related.rb+
# lazy-requires this file only when neither DynamoDB nor the precompute JSONL has
# an answer for the pair — the local-dev fallback path.
#

require_relative "signals"

RELATEDNESS_CLASSIFIER_PATH = generated_dict_path(RELATEDNESS_CLASSIFIER_FILENAME) unless defined?(RELATEDNESS_CLASSIFIER_PATH)

# On-disk GBT tree format this loader understands. When +bin/train-relatedness-classifier+
# emits a different +tree_format+, the classifier is rejected at load time (loud
# warning, rule-based mode takes over) rather than silently misbehaving. Bump in
# lock-step with the trainer whenever the node layout changes.
SUPPORTED_GBT_TREE_FORMAT = "parallel_v1" unless defined?(SUPPORTED_GBT_TREE_FORMAT)

def related_trace_memo?
  ENV["RELATED_TRACE_MEMO"].to_s == "1"
end

# Ordered feature vector pulled from +PairSignals+, shared by the learned-classifier
# trainer (+bin/train-relatedness-classifier+) and runtime scorer
# (+learned_relatedness_score+). Symmetrized: all directional signals are folded to
# min/max so the feature order can't leak +(a, b)+ order into the model.
#
# NOTE: keep this list and its order in lock-step with the weights file
# (+generated/relatedness_classifier.json+). When retraining, the file stores its own
# feature names to fail loud on mismatch.
LEARNED_FEATURE_NAMES = (
  %w[
    bias
    gloss_match
    usf_twohop
    both_sv
    morphy_available
    edge_present
    cos_pct
    edge_weight
    base_similarity
    sv_max
    sv_min
    sv_count_min
    sv_count_max
    morphy_sv_max
    morphy_sv_min
    base_x_sv_max
    base_x_sv_min
    sv_max_x_sv_min
    base_x_usf
    sv_max_x_usf
    model_in_vocab
    model_both_sv
    model_cos_pct
    model_sv_max
    model_sv_min
    model_sense_sense_max
    model_cos_x_cos
    model_sv_max_x_sv_min
    model_cos_x_base
    model_sv_max_x_usf
    cn_hops
    cn_shared_neighbors
    usf_direct_max
    usf_direct_min
  ] + unigram_pair_feature_names
).freeze

def learned_feature_vector(signals)
  both_sv = signals.both_have_sense_vectors?
  sv_max = both_sv ? signals.sv_max : 0
  sv_min = both_sv ? signals.sv_min : 0
  usf = signals.usf_twohop_validated? ? 1.0 : 0.0
  base = signals.base_similarity
  ca = signals.sv_a_count
  cb = signals.sv_b_count

  # Contextualized-model signals. Gated on +model_both_in_vocab?+ so out-of-vocab
  # pairs don't inject a misleading "cos = 0" into the linear combination — the
  # gate feature lets the learner condition on data availability.
  m_in = signals.model_both_in_vocab?
  m_cos = m_in ? signals.model_cos_pct : 0
  m_both_sv = signals.model_both_have_sense_vectors?
  m_sv_max = m_both_sv ? signals.model_sv_max : 0
  m_sv_min = m_both_sv ? signals.model_sv_min : 0
  m_ss_max = m_both_sv ? signals.model_sense_sense_max : 0

  [
    1.0,
    signals.gloss_match? ? 1.0 : 0.0,
    usf,
    both_sv ? 1.0 : 0.0,
    signals.morphy_available? ? 1.0 : 0.0,
    signals.edge_present? ? 1.0 : 0.0,
    signals.cos_pct.to_f,
    signals.edge_weight.to_f,
    base.to_f,
    sv_max.to_f,
    sv_min.to_f,
    (ca < cb ? ca : cb).to_f,
    (ca > cb ? ca : cb).to_f,
    signals.morphy_sv_max.to_f,
    signals.morphy_sv_min.to_f,
    base * sv_max / 100.0,
    base * sv_min / 100.0,
    sv_max * sv_min / 100.0,
    base * usf / 10.0,
    sv_max * usf / 10.0,
    m_in ? 1.0 : 0.0,
    m_both_sv ? 1.0 : 0.0,
    m_cos.to_f,
    m_sv_max.to_f,
    m_sv_min.to_f,
    m_ss_max.to_f,
    m_cos * signals.cos_pct / 100.0,
    m_sv_max * m_sv_min / 100.0,
    m_cos * base / 100.0,
    m_sv_max * usf / 10.0,
    signals.cn_hops.to_f,
    signals.cn_shared_neighbors.to_f,
    signals.usf_direct_max.to_f,
    signals.usf_direct_min.to_f,
  ].concat(unigram_pair_feature_values(signals.a, signals.b))
end

# --- Learned phase-2 combiner (optional) ---
#
# Logistic regression / gradient-boosted-trees over +learned_feature_vector+,
# trained by +bin/train-relatedness-classifier+ and written to
# +generated/relatedness_classifier.json+. When the weights file exists it
# contributes an additional rule inside +relatedness_contributions+:
#   learned probability → calibrated 0..100 score such that
#   p = best_threshold maps to +RELATEDNESS_SCORE_THRESHOLD+.
# When the file is absent the existing rule-based combiner runs unchanged.
#
# Mode controlled by +$RELATED_LEARNED_MODE+ / env +RELATED_LEARNED_MODE+:
#   +replace+   (default) learned score is the *only* rule (except stop-word short-circuit).
#   +additive+            learned score joins the max-over-rules — can only add TPs.
#   +off+                 ignore classifier even if present.
#
# +replace+ is the default because the hand rules composed via max-over-contributions
# overgenerate: +cooccurrence+ + +sense_vectors+ + +similarity+ between them produced
# ~330 of the ~380 strong FPs on the live pipeline (2026-04 eval on +spec/related.csv+),
# compared to 80 strong FPs with the classifier alone. The learned combiner sees all
# 67 phase-1 features (gloss_match, usf_twohop, sv_max/min, edge_present, cn_hops,
# contextualized-model signals, per-word priors) and composes them coherently under
# the symmetric training objective (+--fn-weight 1 --fn-penalty 1+), so it doesn't
# need the hand rules to catch genuine positives.
#
# +additive+ and +off+ remain available for debugging: +additive+ to compare the
# combined score with the learned component, +off+ to isolate the rule bundle.
#
# NOTE: flipping the default only affects live compute (local-dev fallback, spec
# eval with +RELATED_BYPASS_STORE=1+, +bin/precompute-relatedness+). Runtime lookups
# via +Rhymecrime::Store+ still read whatever scores the most recent precompute
# wrote — rebuild the store with +bin/precompute-relatedness+ to materialize the
# replace-mode scores for production.

$RELATED_LEARNED_MODE = ENV["RELATED_LEARNED_MODE"] || "replace"

$relatedness_classifier = nil
$relatedness_classifier_loaded = false
def relatedness_classifier
  return $relatedness_classifier if $relatedness_classifier_loaded
  $relatedness_classifier_loaded = true
  return nil if $RELATED_LEARNED_MODE == "off"

  path = RELATEDNESS_CLASSIFIER_PATH
  return nil unless File.exist?(path)

  clf = JSON.parse(File.read(path, encoding: "UTF-8"))
  got = clf["feature_names"]
  expected = LEARNED_FEATURE_NAMES
  unless got == expected
    warn "related: classifier feature-name mismatch (#{path}); ignoring. got=#{got.inspect} expected=#{expected.inspect}"
    return nil
  end

  if (clf["model_type"] || "logreg") == "gbt"
    fmt = clf["tree_format"]
    unless fmt == SUPPORTED_GBT_TREE_FORMAT
      warn "related: unsupported GBT tree_format=#{fmt.inspect} in #{path} (expected #{SUPPORTED_GBT_TREE_FORMAT.inspect}); retrain via bin/retrain-relatedness."
      return nil
    end
  end

  $relatedness_classifier = clf
  type = clf["model_type"] || "logreg"
  extra = if type == "gbt"
            " trees=#{clf['trees'].size}"
          else
            ""
          end
  puts "loaded relatedness classifier from #{path} (type=#{type} threshold=#{clf['threshold']}#{extra})"
  $relatedness_classifier
end

def learned_sigmoid(z)
  if z >= 0
    ez = Math.exp(-z)
    1.0 / (1.0 + ez)
  else
    ez = Math.exp(z)
    ez / (1.0 + ez)
  end
end

# Walk a parallel-array tree (trainer emits one +{f, t, l, r}+ hash per tree).
# +f[i] == -1+ marks a leaf and +t[i]+ carries the leaf value (threshold and leaf
# value share the slot — an internal node's +t+ is a threshold, a leaf's +t+ is
# its return value). Hoist all four arrays once per tree so the hot loop is pure
# integer indexing. Left branch = <=, right branch = >.
def learned_tree_predict(tree, row)
  f = tree["f"]
  t = tree["t"]
  l = tree["l"]
  r = tree["r"]
  idx = 0
  loop do
    fi = f[idx]
    return t[idx] if fi < 0
    idx = row[fi] <= t[idx] ? l[idx] : r[idx]
  end
end

# Classifier probability in 0..1. Returns +nil+ when no classifier is loaded.
# Dispatches on +model_type+: "logreg" (linear, with standardization) or "gbt"
# (gradient-boosted tree ensemble over raw features).
def learned_relatedness_probability(signals)
  clf = relatedness_classifier
  return nil if clf.nil?

  feats = learned_feature_vector(signals)
  case clf["model_type"] || "logreg"
  when "logreg"
    means = clf["means"]
    stds = clf["stds"]
    weights = clf["weights"]
    z = 0.0
    feats.each_with_index do |v, i|
      x = i.zero? ? v : (v - means[i]) / stds[i]
      z += weights[i] * x
    end
    learned_sigmoid(z)
  when "gbt"
    score = clf["bias"]
    lr = clf["lr"]
    clf["trees"].each { |t| score += lr * learned_tree_predict(t, feats) }
    learned_sigmoid(score)
  else
    warn "related: unknown classifier model_type=#{clf['model_type'].inspect}"
    nil
  end
end

# Piecewise-linear map from classifier probability in +[0, 1]+ to the public
# 0..100 relatedness score. Calibrated so +p == threshold+ maps to
# +RELATEDNESS_SCORE_THRESHOLD+ exactly — that way changing the classifier's
# operating point (its +threshold+ field) moves only the confidence-to-score
# curve, never the cross-over between "related" and "not related". Extracted
# into its own helper so callers that already have +p+ in hand don't have to
# re-invoke the 200-tree GBT just to compute the display score.
def probability_to_learned_score(p)
  clf = $relatedness_classifier
  t = clf["threshold"].to_f
  t = 0.5 if t <= 0 || t >= 1
  if p <= t
    (RELATEDNESS_SCORE_THRESHOLD * p / t).round
  else
    (RELATEDNESS_SCORE_THRESHOLD + (100 - RELATEDNESS_SCORE_THRESHOLD) * (p - t) / (1 - t)).round
  end
end

# Classifier probability → 0..100 score, calibrated so that +p == threshold+ maps
# to +RELATEDNESS_SCORE_THRESHOLD+ exactly. Piecewise linear in +p+; avoids wasting
# dynamic range on the mostly-empty tail above/below the decision boundary.
def learned_relatedness_score(signals)
  p = learned_relatedness_probability(signals)
  return nil if p.nil?
  probability_to_learned_score(p)
end

# Returns an array of +[score, reason]+ tuples: one per rule whose preconditions are
# satisfied by +signals+. May be empty when no signal passes its gate.
def relatedness_contributions(signals)
  # Stop words are contentless glue: related to every other word. Fully saturates
  # the composite score so no other signal is consulted.
  if signals.involves_stop_word?
    stop = signals.stop_word_a? ? signals.a : signals.b
    return [[100, "stop_word: #{stop.inspect} is a stop word (related to everything)"]]
  end

  # Learned-classifier replace mode: the logistic regression over all phase-1
  # signals is the *only* contribution (except the stop-word short-circuit above).
  #
  # Score and reason both need the classifier probability, but the GBT is the
  # hot-path bottleneck in +bin/precompute-relatedness+ (~70% of per-cue scan
  # time). Compute +p+ once and derive the display score from it rather than
  # calling the classifier twice.
  if $RELATED_LEARNED_MODE == "replace"
    p = learned_relatedness_probability(signals)
    if p
      learned = probability_to_learned_score(p)
      return [[learned, format("learned_replace: p=%.3f", p)]]
    end
  end

  contributions = []
  base = signals.base_similarity

  # Primary: Numberbatch cosine + ConceptNet edge bonus. Above +$SIMILARITY_THRESHOLD+
  # we map linearly into [50, 95]; below threshold we still emit a weak partial score
  # so the composite reflects how close we came (always < 50, so never flips the
  # predicate on its own).
  if base >= $SIMILARITY_THRESHOLD
    score = [50 + (base - $SIMILARITY_THRESHOLD) * 2, 95].min
    contributions << [score, "similarity: base=#{base} >= #{$SIMILARITY_THRESHOLD} (Numberbatch centiles + ConceptNet edge bonus)"]
  elsif base > 0
    contributions << [[base * 3, 49].min, "similarity_partial: base=#{base} (< #{$SIMILARITY_THRESHOLD})"]
  end

  # High-precision rescue: literal gloss/derivation containment.
  contributions << [90, "gloss: bidirectional WordNet gloss/derivation containment"] if signals.gloss_match?

  # Sense-vector rescue (polysemy aware): only meaningful when the base signal is
  # non-trivial (+$SENSE_VECTOR_MIN_BASE+) so we don't fire on noise.
  if base >= $SENSE_VECTOR_MIN_BASE
    if signals.both_have_sense_vectors?
      sv_max = signals.sv_max
      sv_min = signals.sv_min
      if sv_max >= $SENSE_VECTOR_THRESHOLD && sv_min >= $SENSE_VECTOR_MIN_FLOOR
        score = [55 + (sv_max - $SENSE_VECTOR_THRESHOLD), 80].min
        contributions << [score, "sense_vectors: directional max=#{sv_max} min=#{sv_min} (need max>=#{$SENSE_VECTOR_THRESHOLD} min>=#{$SENSE_VECTOR_MIN_FLOOR}; base similarity=#{base})"]
      elsif sv_max >= $SENSE_VECTOR_ASYMMETRIC_MAX && sv_min >= $SENSE_VECTOR_ASYMMETRIC_MIN
        contributions << [55, "sense_vectors_asymmetric: directional max=#{sv_max} min=#{sv_min} (need max>=#{$SENSE_VECTOR_ASYMMETRIC_MAX} min>=#{$SENSE_VECTOR_ASYMMETRIC_MIN}; base similarity=#{base})"]
      end
    elsif $SENSE_VECTOR_MORPHY_FLOOR > 0 && signals.morphy_available?
      mx = signals.morphy_sv_max
      mn = signals.morphy_sv_min
      if mx >= $SENSE_VECTOR_THRESHOLD && mn >= $SENSE_VECTOR_MORPHY_FLOOR
        contributions << [55, "sense_vectors_morphy: directional max=#{mx} min=#{mn} (need max>=#{$SENSE_VECTOR_THRESHOLD} min>=#{$SENSE_VECTOR_MORPHY_FLOOR}; base similarity=#{base})"]
      end
    end
  end

  # USF 2-hop: validated human-association bridge. Equivalent to the old
  # +base + $USF_TWOHOP_BOOST >= $SIMILARITY_THRESHOLD+ gate, with the boosted
  # score mapped just over the relatedness threshold.
  if $USF_TWOHOP_BOOST > 0 &&
     base >= $USF_MIN_BASE &&
     base + $USF_TWOHOP_BOOST >= $SIMILARITY_THRESHOLD &&
     signals.usf_twohop_validated?
    boosted = base + $USF_TWOHOP_BOOST
    contributions << [55, "usf_twohop: base=#{base} + boost=#{$USF_TWOHOP_BOOST} => #{boosted} >= #{$SIMILARITY_THRESHOLD}, validated bridge"]
  end

  # Co-occurrence: sum weak evidence across features. Each term is capped so one
  # signal can't carry the rule alone — the point is to catch pairs where several
  # weak signals reinforce each other. Sense-vector terms require both sides to
  # have WordNet senses (no asymmetric bypass here — that's what
  # +sense_vectors_asymmetric+ is for).
  cooccur = 0.0
  cooccur += [[base, 0].max, $COOCCUR_BASE_CAP].min * $COOCCUR_BASE_WEIGHT
  if signals.both_have_sense_vectors?
    cooccur += [signals.sv_min, $COOCCUR_SV_MIN_CAP].min * $COOCCUR_SV_MIN_WEIGHT
    cooccur += [[signals.sv_max - $COOCCUR_SV_MAX_FLOOR, 0].max, $COOCCUR_SV_MAX_CAP].min * $COOCCUR_SV_MAX_WEIGHT
  end
  cooccur += $COOCCUR_USF_WEIGHT if signals.usf_twohop_validated?
  if cooccur > 0
    contributions << [
      cooccur.round,
      "cooccurrence: base=#{base} sv=(#{signals.sv_d1},#{signals.sv_d2}) usf=#{signals.usf_twohop_validated?}",
    ]
  end

  # Learned-classifier additive mode: logistic regression over all phase-1 signals
  # contributes one more rule. Max-over-contributions means it can only rescue
  # pairs the hand rules missed, never veto them — safe to enable alongside.
  if $RELATED_LEARNED_MODE == "additive"
    p = learned_relatedness_probability(signals)
    if p
      contributions << [probability_to_learned_score(p), format("learned: p=%.3f", p)]
    end
  end

  contributions
end

# Integer 0..100: 0 = definitely unrelated, 100 = maximally related. See
# +relatedness_contributions+ for the rule-by-rule decomposition.
def relatedness_score(signals)
  c = relatedness_contributions(signals)
  return 0 if c.empty?
  [c.map(&:first).max, 0].max
end

# --- Phase 3: Threshold → boolean predicate ---

# Memo keyed by sorted dictionary lemma pair (see +thematically_related?+). Cleared when +load_word_dict+ runs.
$thematically_related_memo = nil

# Uncached predicate on two dictionary lemmas. Symmetric in +a+ / +b+.
def thematically_related_pair_uncached?(a, b)
  puts "related? #{a} #{b}" if related_trace_memo?
  relatedness_score(PairSignals.new(a, b)) >= RELATEDNESS_SCORE_THRESHOLD
end

# +a+ and +b+ are dictionary lemmas in lexicographic order (+a+ <= +b+); see +thematically_related?+.
def thematically_related_pair_memoized?(a, b)
  memo = ($thematically_related_memo ||= {})
  key = [a, b]
  if memo.key?(key)
    puts "  cache hit #{a} #{b}" if related_trace_memo?
    return memo[key]
  end

  puts "thematically_related_pair_uncached? #{a} #{b}" if related_trace_memo?
  memo[key] = thematically_related_pair_uncached?(a, b)
end

# Full-pipeline thematic relatedness predicate. Used by the local-dev / spec fallback
# in +lib/rhymecrime/related.rb+ when no precomputed data (DynamoDB or JSONL) is
# available. At Lambda runtime the runtime shim's DDB lookup handles this path.
def thematically_related_full?(word1, word2, include_self = false)
  return true if include_self && (word1 == word2 || lemma(word1) == lemma(word2))
  return true if stop_word?(word1) || stop_word?(word2)

  l1 = lemma(word1)
  l2 = lemma(word2)
  a, b = l1 <= l2 ? [l1, l2] : [l2, l1]
  thematically_related_pair_memoized?(a, b)
end

# Same decision as +thematically_related_full?+, but returns a short reason string
# when true (the highest-scoring rule from +relatedness_contributions+), or +nil+
# when false. Used at seed-time (precompute + spec diagnostics) and by the local-dev
# fallback in +lib/rhymecrime/related.rb+.
def why_thematically_related_full?(word1, word2, include_self = false)
  return "self: same headword" if include_self && word1 == word2
  return "self: same lexeme (lemma)" if include_self && lemma(word1) == lemma(word2)

  l1 = lemma(word1)
  l2 = lemma(word2)
  a, b = l1 <= l2 ? [l1, l2] : [l2, l1]
  contributions = relatedness_contributions(PairSignals.new(a, b))
  return nil if contributions.empty?

  best_score, best_reason = contributions.max_by(&:first)
  return nil if best_score < RELATEDNESS_SCORE_THRESHOLD
  best_reason
end
