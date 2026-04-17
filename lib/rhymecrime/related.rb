#!/usr/bin/env ruby
# coding: utf-8
#
# related.rb — word relatedness (Numberbatch, ConceptNet, WordNet, USF, …). Load: require "rhymecrime/related"
#
# Determine topical relatedness of two words
# or retrieve a list of topically related words.
#
# Three-phase pipeline:
#
#   1. +PairSignals+ — gather raw signals/derived features for a lemma pair. Signals
#      are the "primitive" evidence: booleans stay booleans, counts stay counts,
#      cosine similarities stay in their natural 0..100 range. No scoring scale here.
#
#   2. +relatedness_score(signals)+ — combine features into an integer 0..100
#      (0 = definitely unrelated, 100 = maximally related). This is the only place
#      feature scaling / weighting happens.
#
#   3. +thematically_related?+ — boolean predicate: +relatedness_score >= RELATEDNESS_SCORE_THRESHOLD+.
#
# Offline signals gathered in phase 1:
#   - Numberbatch cosine similarity + ConceptNet edge weight (primary vector evidence)
#   - WordNet gloss containment (high-precision polysemy rescue)
#   - WordNet gloss-vector sense embeddings + morphy fallback (secondary rescue)
#   - USF Free Association 2-hop bridge validation (human association graph)
#   - Stop-word flag (contentless glue: related to everything)
#
# Debug: RELATED_TRACE_MEMO=1 — log surface + lemma memo path (thematically_related? → hit/miss → uncached).
#

require 'json'
require 'msgpack'
require 'rwordnet'
require 'set'
require_relative 'pace_utils'
require_relative 'dict/utils_rhyme'

WordNet::DB.path = File.join(REPO_ROOT, "corpora", "wordnet", "3.1") unless defined?(WordNet::DB) && WordNet::DB.path

# Topical relatedness artifacts (same paths dict-build writes under generated/).
CONCEPTNET_EDGES_PATH = generated_dict_path(CONCEPTNET_EDGES_FILENAME)
NUMBERBATCH_VEC_PATH = generated_dict_path(NUMBERBATCH_VECTORS_FILENAME)
USF_ASSOCIATIONS_PATH = generated_dict_path(USF_ASSOCIATIONS_FILENAME)

SIMILAR_MAX = 50000 # O_o

def related_trace_memo?
  ENV["RELATED_TRACE_MEMO"].to_s == "1"
end

# --- Tunable parameters (optimized via anneal.rb / parameter sweeps) ---

$SIMILARITY_THRESHOLD = 10
$CONCEPTNET_EDGE_BONUS = 7
$SENSE_VECTOR_THRESHOLD = 10
$SENSE_VECTOR_MIN_FLOOR = 5
$SENSE_VECTOR_MORPHY_FLOOR = 13
$SENSE_VECTOR_MIN_BASE = 6
$SENSE_VECTOR_MAX_SENSES = 4
# Asymmetric sense-vector bypass: when one direction is very strong (e.g. one word's
# WordNet definitions clearly describe the other) the reverse direction is often
# diluted by polysemy. Accept as related when +sv_max >= ASYMMETRIC_MAX+ and
# +sv_min >= ASYMMETRIC_MIN+, as long as the regular +SENSE_VECTOR_MIN_BASE+ gate
# is satisfied. The non-zero +ASYMMETRIC_MIN+ keeps pure noise out.
$SENSE_VECTOR_ASYMMETRIC_MAX = 18
$SENSE_VECTOR_ASYMMETRIC_MIN = 1
$USF_TWOHOP_BOOST = 10
$USF_MIN_BRIDGE_COS = 8
# Skip USF graph work when primary score is below this (0 = same as pre-filter behavior).
$USF_MIN_BASE = 0

# Co-occurrence combiner: additive contribution that fires when several weak signals
# line up even though no single hard-gated rule is satisfied. This is the main lever
# the 3-phase design unlocks — gates on individual rules are already tuned, but pairs
# with (e.g.) below-threshold +base+ *and* two-sided sense-vector agreement *and* a
# validated USF bridge are clearly related despite no single gate passing. Weights
# tuned on +spec/related.csv+ via grid search over a broad plateau (see
# +spec/related_weighted_accuracy.rb+). Contribution is +base * w + sv_min * w +
# max(0, sv_max - floor) * w + (usf ? w : 0)+, each term capped so one runaway
# signal can't dominate.
$COOCCUR_BASE_WEIGHT = 3.0
$COOCCUR_BASE_CAP = 15
$COOCCUR_SV_MIN_WEIGHT = 2.0
$COOCCUR_SV_MIN_CAP = 15
$COOCCUR_SV_MAX_WEIGHT = 1.5
$COOCCUR_SV_MAX_FLOOR = 5
$COOCCUR_SV_MAX_CAP = 20
$COOCCUR_USF_WEIGHT = 10

# --- ConceptNet edge map ---
# Keys are "word1|word2" (alphabetically sorted), values are edge weights.

$conceptnet_edges = nil
def conceptnet_edges
  return $conceptnet_edges unless $conceptnet_edges.nil?
  path = CONCEPTNET_EDGES_PATH
  if File.exist?(path)
    $conceptnet_edges = JSON.parse(File.read(path, encoding: "UTF-8"))
    puts "loaded #{$conceptnet_edges.size} ConceptNet edges from #{path}"
  else
    $conceptnet_edges = {}
  end
  $conceptnet_edges
end

# Expects dictionary-lemma spellings (see +similarity+). Keys match +save_conceptnet_edge_map!+ export.
def conceptnet_edge_weight(word1, word2)
  key = [hyphens_to_underscores(word1), hyphens_to_underscores(word2)].sort.join("|")
  conceptnet_edges[key] || 0.0
end

# --- USF Free Association Norms (Nelson, McEvoy & Schreiber 1998) ---
# 5,019 cue words with ~72K forward association pairs from human participants.
# Used for 2-hop inference: word1 → bridge → word2, validated by requiring
# the bridge word to have positive Numberbatch cosine with both endpoints.

$usf_associations = nil
def usf_associations
  return $usf_associations unless $usf_associations.nil?
  path = USF_ASSOCIATIONS_PATH
  if File.exist?(path)
    $usf_associations = JSON.parse(File.read(path, encoding: "UTF-8"))
    puts "loaded #{$usf_associations.size} USF cues from #{path}"
  else
    $usf_associations = {}
  end
  $usf_associations
end

def usf_twohop_bridge_validated?(word1, word2)
  ua = usf_associations
  # Neither endpoint is a USF cue → no word→bridge forward star to search.
  return false if ua.empty? || (!ua[word1] && !ua[word2])

  [[word1, word2], [word2, word1]].each do |a, b|
    targets_a = ua[a]
    next unless targets_a
    targets_a.each do |bridge, fsg1|
      next if fsg1 < 0.01
      targets_b = ua[bridge]
      next unless targets_b
      fsg2 = targets_b[b]
      next unless fsg2 && fsg2 >= 0.01
      br = lemma(bridge)
      cos_ab = numberbatch_cosine(a, br)
      cos_bb = numberbatch_cosine(br, b)
      min_cos = [cos_ab, cos_bb].min
      return true if (min_cos * 100).round >= $USF_MIN_BRIDGE_COS
    end
  end
  false
end

# --- Numberbatch vectors (pre-normalized) ---

$numberbatch = nil
def numberbatch
  return $numberbatch unless $numberbatch.nil?
  path = NUMBERBATCH_VEC_PATH
  if File.exist?(path)
    $numberbatch = MessagePack.unpack(File.binread(path))
    puts "loaded #{$numberbatch.size} Numberbatch vectors from #{path}"
  else
    $numberbatch = {}
  end
  $numberbatch
end

# Cached table handle — avoids calling #numberbatch on every vector lookup (hot path).
def numberbatch_table
  nb = $numberbatch
  nb.nil? ? numberbatch : nb
end

# Expects dictionary-lemma spellings (see +similarity+). Rows match +save_numberbatch_vectors!+ export.
def numberbatch_cosine(word1, word2)
  nb = numberbatch_table
  v1 = nb[hyphens_to_underscores(word1)]
  v2 = nb[hyphens_to_underscores(word2)]
  return 0.0 if v1.nil? || v2.nil?
  dot = 0.0
  v1.size.times { |i| dot += v1[i] * v2[i] }
  dot
end

# True if +lemma(word)+ has a row in the Numberbatch export (+save_numberbatch_vectors!+ keys, underscore-normalized).
# Used to skip the O(n) relatedness scan when the cue cannot contribute a primary vector score.
def dictionary_lemma_has_numberbatch_vector?(word)
  l = lemma(word)
  !numberbatch_table[hyphens_to_underscores(l)].nil?
end

# --- Modern sentence-transformer embeddings ---
# Built offline by +bin/dump-sense-glosses+ -> +bin/build-sense-vectors.py+, saved as
# +generated/model_sense_vectors.msgpack+. Supplements (does not replace) Numberbatch:
# Numberbatch is tiny and fast for the O(n) scan, while these contextualized vectors
# carry richer sense distinctions for the per-pair yes/no decision. Shape:
#   { "model" => String, "dim" => Integer,
#     "headword" => {lemma => [Float * dim]},
#     "senses"   => {lemma => [[Float * dim], ...]} }
# Vectors are pre-L2-normalized so cosine similarity is a plain dot product. Keys use
# hyphen-form lemmas (matching +lemma()+ output), not the underscore form Numberbatch
# keys use. Returns +nil+ if the file is absent — callers degrade gracefully (all
# model-* signals become 0 and +model_both_in_vocab?+ is false, which the learned
# combiner can condition on).
$model_sense_vectors = nil
$model_sense_vectors_loaded = false
def model_sense_vectors_table
  return $model_sense_vectors if $model_sense_vectors_loaded
  $model_sense_vectors_loaded = true
  path = generated_dict_path(MODEL_SENSE_VECTORS_FILENAME)
  return nil unless File.exist?(path)
  $model_sense_vectors = MessagePack.unpack(File.binread(path))
  hw = $model_sense_vectors["headword"] || {}
  sv = $model_sense_vectors["senses"] || {}
  puts "loaded model sense vectors from #{path} " \
       "(model=#{$model_sense_vectors['model']} dim=#{$model_sense_vectors['dim']} " \
       "headwords=#{hw.size} senses=#{sv.values.sum(&:size)})"
  $model_sense_vectors
end

def model_headword_vector(word)
  t = model_sense_vectors_table
  return nil if t.nil?
  h = t["headword"]
  h.nil? ? nil : h[word]
end

def model_sense_vectors_of(word)
  t = model_sense_vectors_table
  return [] if t.nil?
  s = t["senses"]
  return [] if s.nil?
  s[word] || []
end

# Headword-headword cosine under the contextualized model (0..1). Returns 0.0 when
# either side is out-of-vocab — pair with +model_both_in_vocab?+ so the classifier
# can distinguish "low similarity" from "no data".
def model_headword_cosine(word1, word2)
  v1 = model_headword_vector(word1)
  v2 = model_headword_vector(word2)
  return 0.0 if v1.nil? || v2.nil?
  dot = 0.0
  v1.size.times { |i| dot += v1[i] * v2[i] }
  dot
end

# Directional sense-vs-headword cosines under the contextualized model (each 0..100
# centile). Analogous to +directional_sense_cosines+ but end-to-end in the model's
# embedding space: for each sense vector of word1, the cosine against word2's headword
# vector (and symmetrically). Lets a specific sense of a polysemous word rescue the
# pair even when the averaged headword embedding doesn't match.
def model_directional_sense_cosines(word1, word2)
  best_1to2 = 0
  best_2to1 = 0

  v2_head = model_headword_vector(word2)
  if v2_head
    model_sense_vectors_of(word1).each do |sv|
      dot = 0.0
      sv.size.times { |i| dot += sv[i] * v2_head[i] }
      score = (dot * 100).round
      best_1to2 = score if score > best_1to2
    end
  end

  v1_head = model_headword_vector(word1)
  if v1_head
    model_sense_vectors_of(word2).each do |sv|
      dot = 0.0
      sv.size.times { |i| dot += sv[i] * v1_head[i] }
      score = (dot * 100).round
      best_2to1 = score if score > best_2to1
    end
  end

  [best_1to2, best_2to1]
end

# Max cosine over all (sense_of_a, sense_of_b) pairs (0..100 centile). Captures pairs
# where a specific sense of A matches a specific sense of B more tightly than either
# matches the other's headword — i.e. polysemy on *both* sides. Small O(senses_a *
# senses_b); capped at SENSE_VECTOR_MAX_SENSES^2 = 16 comparisons in practice.
def model_sense_sense_max_cosine(word1, word2)
  sa = model_sense_vectors_of(word1)
  sb = model_sense_vectors_of(word2)
  return 0 if sa.empty? || sb.empty?
  best = -1.0
  sa.each do |va|
    sb.each do |vb|
      dot = 0.0
      va.size.times { |i| dot += va[i] * vb[i] }
      best = dot if dot > best
    end
  end
  (best * 100).round
end

# --- WordNet gloss containment (high-precision polysemy rescue) ---
# Checks if word1 (or a validated derivational form) literally appears as a word
# in any WordNet definition of word2, or vice versa.

$gloss_derivation_cache = {}
# All lowercase gloss tokens for a headword (union of every synset gloss); built once per word.
$gloss_token_set_cache = {}
# Pairs (sorted key) known not to match gloss containment either direction.
$gloss_negative_pair_cache = Set.new

def gloss_word_token_set(lemma_word)
  $gloss_token_set_cache[lemma_word] ||= begin
    tokens = Set.new
    WordNet::Lemma.find_all(lemma_word).each do |lemma|
      lemma.synsets.each do |synset|
        synset.gloss.downcase.scan(/[a-z]+/).each { |tok| tokens << tok }
      end
    end
    tokens
  end
end

def validated_derivations(word)
  nb = numberbatch_table
  candidates = [word]
  %w[al ian ical ous ic ly ing ed er tion ment s].each { |s| candidates << word + s }
  candidates << word[0..-2] + "ical" if word.end_with?("y")
  candidates << word[0..-2] + "ies" if word.end_with?("y")

  candidates.select do |d|
    next true if d == word
    w_key = hyphens_to_underscores(word)
    d_key = word_dict_includes_headword?(d) ? hyphens_to_underscores(lemma(d)) : hyphens_to_underscores(d)
    v1 = nb[w_key]
    v2 = nb[d_key]
    next false unless v1 && v2
    dot = 0.0
    v1.size.times { |i| dot += v1[i] * v2[i] }
    dot >= 0.40
  end
end

def gloss_contains?(topic_word, other_word)
  derivations = $gloss_derivation_cache[topic_word] ||= validated_derivations(topic_word)
  gloss_tokens = gloss_word_token_set(other_word)
  derivations.each { |d| return true if gloss_tokens.include?(d) }
  false
end

def bidirectional_gloss_contains?(word1, word2)
  pair_key = word1 < word2 ? "#{word1}\t#{word2}" : "#{word2}\t#{word1}"
  return false if $gloss_negative_pair_cache.include?(pair_key)

  hit = gloss_contains?(word1, word2) || gloss_contains?(word2, word1)
  $gloss_negative_pair_cache.add(pair_key) unless hit
  hit
end

# --- WordNet gloss-vector sense embeddings ---
# For each WordNet sense, averages Numberbatch vectors of content words in
# the definition to create a sense-specific embedding. Handles polysemy by
# finding the best-matching sense pair.

GLOSS_STOP_WORDS = Set.new(%w[
  a an the is are was were be been being of in on at by to for or and not nor
  with that this these those it its he she they them his her their do does did
  has have had but if so as from than more most which who whom what when where
  how no some any all each every can could may might will would shall should
  very much also just only even still about into over after before between
  through during up down out off away back make made used one
]).freeze

$sense_vectors_cache = {}
def sense_vectors(word, max_senses = $SENSE_VECTOR_MAX_SENSES)
  key = [word, max_senses]
  return $sense_vectors_cache[key] if $sense_vectors_cache.key?(key)

  nb = numberbatch_table
  vecs = []
  count = 0
  WordNet::Lemma.find_all(word).each do |lemma|
    lemma.synsets.each do |synset|
      break if count >= max_senses
      content_words = synset.gloss.downcase.scan(/[a-z]+/) - GLOSS_STOP_WORDS.to_a
      embeds = content_words.filter_map do |gw|
        gk = word_dict_includes_headword?(gw) ? hyphens_to_underscores(lemma(gw)) : hyphens_to_underscores(gw)
        nb[gk]
      end
      next if embeds.size < 2
      dim = embeds.first.size
      avg = Array.new(dim, 0.0)
      embeds.each { |v| dim.times { |i| avg[i] += v[i] } }
      mag = Math.sqrt(avg.sum { |x| x * x })
      next if mag < 1e-9
      vecs << avg.map! { |x| x / mag }
      count += 1
    end
  end
  $sense_vectors_cache[key] = vecs
  vecs
end

def directional_sense_cosines(word1, word2)
  best_1to2 = 0
  best_2to1 = 0
  nb = numberbatch_table

  v2_raw = nb[hyphens_to_underscores(word2)]
  if v2_raw
    sense_vectors(word1).each do |sv|
      dot = 0.0
      sv.size.times { |i| dot += sv[i] * v2_raw[i] }
      score = (dot * 100).round
      best_1to2 = score if score > best_1to2
    end
  end

  v1_raw = nb[hyphens_to_underscores(word1)]
  if v1_raw
    sense_vectors(word2).each do |sv|
      dot = 0.0
      sv.size.times { |i| dot += sv[i] * v1_raw[i] }
      score = (dot * 100).round
      best_2to1 = score if score > best_2to1
    end
  end

  [best_1to2, best_2to1]
end

def max_sense_cosine(word1, word2)
  directional_sense_cosines(word1, word2).max
end

# Morphy-resolved sense vectors for inflected forms (plurals, verb conjugations)
# that lack direct WordNet lemma entries. Only used as a fallback when
# sense_vectors returns empty.
$morphy_sv_cache = {}
def sense_vectors_morphy(word, max_senses = $SENSE_VECTOR_MAX_SENSES)
  return $morphy_sv_cache[word] if $morphy_sv_cache.key?(word)
  nb = numberbatch_table
  morphs = (WordNet::Synset.morphy_all(word) rescue []).uniq - [word]
  vecs = []
  count = 0
  morphs.each do |form|
    break if count >= max_senses
    WordNet::Lemma.find_all(form).each do |lemma|
      break if count >= max_senses
      lemma.synsets.each do |synset|
        break if count >= max_senses
        content_words = synset.gloss.downcase.scan(/[a-z]+/) - GLOSS_STOP_WORDS.to_a
        embeds = content_words.filter_map do |gw|
          gk = word_dict_includes_headword?(gw) ? hyphens_to_underscores(lemma(gw)) : hyphens_to_underscores(gw)
          nb[gk]
        end
        next if embeds.size < 2
        dim = embeds.first.size
        avg = Array.new(dim, 0.0)
        embeds.each { |v| dim.times { |i| avg[i] += v[i] } }
        mag = Math.sqrt(avg.sum { |x| x * x })
        next if mag < 1e-9
        vecs << avg.map! { |x| x / mag }
        count += 1
      end
    end
  end
  $morphy_sv_cache[word] = vecs
  vecs
end

def morphy_directional_sense_cosines(word1, word2)
  sv1_orig = sense_vectors(word1)
  sv2_orig = sense_vectors(word2)
  sv1_morphy = sv1_orig.empty? ? sense_vectors_morphy(word1) : []
  sv2_morphy = sv2_orig.empty? ? sense_vectors_morphy(word2) : []
  return nil if sv1_morphy.empty? && sv2_morphy.empty?

  d1, d2 = directional_sense_cosines(word1, word2)
  nb = numberbatch_table

  if sv1_morphy.any?
    v2_raw = nb[hyphens_to_underscores(word2)]
    if v2_raw
      sv1_morphy.each do |sv|
        dot = 0.0
        sv.size.times { |i| dot += sv[i] * v2_raw[i] }
        score = (dot * 100).round
        d1 = score if score > d1
      end
    end
  end

  if sv2_morphy.any?
    v1_raw = nb[hyphens_to_underscores(word1)]
    if v1_raw
      sv2_morphy.each do |sv|
        dot = 0.0
        sv.size.times { |i| dot += sv[i] * v1_raw[i] }
        score = (dot * 100).round
        d2 = score if score > d2
      end
    end
  end

  [d1, d2]
end

# --- Phase 1: Signal gathering ---
#
# +PairSignals+ bundles every relatedness signal for a given dictionary-lemma pair
# +(a, b)+. Each feature is returned in its natural type/range (booleans for yes/no
# rescues, 0..100 integers for cosine-derived scores, raw weights for ConceptNet edges,
# counts for sense-vector availability) — no scaling to the composite 0..100 scale
# happens here. Accessors memoize on the instance so diagnostics, scoring, and any
# future callers can read the same signal multiple times without recomputation.
#
# Phase 2 (+relatedness_score+) is the only place feature weights / scaling live.
class PairSignals
  attr_reader :a, :b

  def initialize(a, b)
    @a = a
    @b = b
  end

  # --- boolean features ---

  def stop_word_a?
    return @stop_word_a if defined?(@stop_word_a)
    @stop_word_a = stop_word?(@a)
  end

  def stop_word_b?
    return @stop_word_b if defined?(@stop_word_b)
    @stop_word_b = stop_word?(@b)
  end

  def involves_stop_word?
    stop_word_a? || stop_word_b?
  end

  def gloss_match?
    return @gloss_match if defined?(@gloss_match)
    @gloss_match = bidirectional_gloss_contains?(@a, @b)
  end

  def usf_twohop_validated?
    return @usf_twohop if defined?(@usf_twohop)
    @usf_twohop = usf_twohop_bridge_validated?(@a, @b)
  end

  def both_have_sense_vectors?
    sv_a_count > 0 && sv_b_count > 0
  end

  def morphy_available?
    !morphy_sv_directional.nil?
  end

  # --- numeric features (natural scale) ---

  # Numberbatch cosine as a 0..100 centile (may be negative when vectors disagree).
  def cos_pct
    @cos_pct ||= (numberbatch_cosine(@a, @b) * 100).round
  end

  # Raw ConceptNet edge weight (0.0 if no edge recorded).
  def edge_weight
    return @edge_weight if defined?(@edge_weight)
    @edge_weight = conceptnet_edge_weight(@a, @b)
  end

  def edge_present?
    edge_weight > 0
  end

  # Base similarity score: Numberbatch centile + fixed ConceptNet edge bonus when an
  # edge exists. Same formula as +lemmilarity+; kept here for independent memoization.
  def base_similarity
    @base_similarity ||= cos_pct + (edge_present? ? $CONCEPTNET_EDGE_BONUS : 0)
  end

  # Directional sense-vector cosines (0..100 centiles): +sv_directional.first+ is
  # word1's sense embeddings vs. word2's Numberbatch vector; second is the reverse.
  def sv_directional
    @sv_directional ||= directional_sense_cosines(@a, @b)
  end

  def sv_d1
    sv_directional[0]
  end

  def sv_d2
    sv_directional[1]
  end

  def sv_max
    sv_directional.max
  end

  def sv_min
    sv_directional.min
  end

  # Count of WordNet senses that produced a usable gloss-average embedding.
  def sv_a_count
    return @sv_a_count if defined?(@sv_a_count)
    @sv_a_count = sense_vectors(@a).size
  end

  def sv_b_count
    return @sv_b_count if defined?(@sv_b_count)
    @sv_b_count = sense_vectors(@b).size
  end

  # Morphy-resolved directional cosines (0..100), or +nil+ when neither side needed
  # morphy (both had direct WordNet lemma entries) or no morphy form produced a
  # usable sense vector.
  def morphy_sv_directional
    return @morphy_sv_directional if defined?(@morphy_sv_directional)
    @morphy_sv_directional = morphy_directional_sense_cosines(@a, @b)
  end

  def morphy_sv_max
    m = morphy_sv_directional
    m ? m.max : 0
  end

  def morphy_sv_min
    m = morphy_sv_directional
    m ? m.min : 0
  end

  # --- Modern sentence-transformer signals ---
  # Mirror the Numberbatch-based signals above but use contextualized MPNet embeddings
  # (see +model_sense_vectors_table+). +model_both_in_vocab?+ lets the combiner treat
  # "0 because out-of-vocab" differently from "0 because actually unrelated".

  def model_both_in_vocab?
    return @model_both_in_vocab if defined?(@model_both_in_vocab)
    @model_both_in_vocab = !model_headword_vector(@a).nil? && !model_headword_vector(@b).nil?
  end

  def model_cos_pct
    @model_cos_pct ||= (model_headword_cosine(@a, @b) * 100).round
  end

  def model_sv_directional
    @model_sv_directional ||= model_directional_sense_cosines(@a, @b)
  end

  def model_sv_max
    model_sv_directional.max
  end

  def model_sv_min
    model_sv_directional.min
  end

  def model_both_have_sense_vectors?
    return @model_both_have_sv if defined?(@model_both_have_sv)
    @model_both_have_sv = !model_sense_vectors_of(@a).empty? && !model_sense_vectors_of(@b).empty?
  end

  def model_sense_sense_max
    @model_sense_sense_max ||= model_sense_sense_max_cosine(@a, @b)
  end
end

# Ordered feature vector pulled from +PairSignals+, shared by the learned-classifier
# trainer (+bin/train-relatedness-classifier+) and runtime scorer
# (+learned_relatedness_score+). Symmetrized: all directional signals are folded to
# min/max so the feature order can't leak +(a, b)+ order into the model.
#
# NOTE: keep this list and its order in lock-step with the weights file
# (+generated/relatedness_classifier.json+). When retraining, the file stores its own
# feature names to fail loud on mismatch.
LEARNED_FEATURE_NAMES = %w[
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
].freeze

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
  ]
end

# --- Phase 2: Feature combining → 0..100 relatedness score ---
#
# Each rule below produces a +[score, reason]+ tuple when applicable. The overall
# relatedness score is the max across applicable rules (equivalent to the OR logic
# of the original predicate, but graded instead of binary). Only this layer knows
# about "50 is the threshold for related" — phase 1 stays on each signal's natural
# scale, phase 3 just compares against +RELATEDNESS_SCORE_THRESHOLD+.

RELATEDNESS_SCORE_THRESHOLD = 50

def similarity_threshold
  $SIMILARITY_THRESHOLD
end

# --- Learned phase-2 combiner (optional) ---
#
# Logistic regression over +learned_feature_vector+, trained by
# +bin/train-relatedness-classifier+ and written to
# +generated/relatedness_classifier.json+. When the weights file exists it
# contributes an additional rule inside +relatedness_contributions+:
#   learned probability → calibrated 0..100 score such that
#   p = best_threshold maps to +RELATEDNESS_SCORE_THRESHOLD+.
# When the file is absent the existing rule-based combiner runs unchanged.
#
# Mode controlled by +$RELATED_LEARNED_MODE+ / env +RELATED_LEARNED_MODE+:
#   +additive+  (default) learned score joins the max-over-rules — can only add TPs.
#   +replace+             learned score is the *only* rule (except stop-word short-circuit).
#   +off+                 ignore classifier even if present.

$RELATED_LEARNED_MODE = ENV["RELATED_LEARNED_MODE"] || "additive"

RELATEDNESS_CLASSIFIER_PATH = generated_dict_path(RELATEDNESS_CLASSIFIER_FILENAME)

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

# Walk a flat tree (trainer emits one array of nodes per tree, leaves have "v",
# internal nodes have "f"/"t"/"l"/"r"). Left branch = <=, right branch = >.
def learned_tree_predict(nodes, row)
  idx = 0
  loop do
    node = nodes[idx]
    return node["v"] if node.key?("v")
    idx = row[node["f"]] <= node["t"] ? node["l"] : node["r"]
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

# Classifier probability → 0..100 score, calibrated so that +p == threshold+ maps
# to +RELATEDNESS_SCORE_THRESHOLD+ exactly. Piecewise linear in +p+; avoids wasting
# dynamic range on the mostly-empty tail above/below the decision boundary.
def learned_relatedness_score(signals)
  p = learned_relatedness_probability(signals)
  return nil if p.nil?
  clf = $relatedness_classifier
  t = clf["threshold"].to_f
  t = 0.5 if t <= 0 || t >= 1
  if p <= t
    (RELATEDNESS_SCORE_THRESHOLD * p / t).round
  else
    (RELATEDNESS_SCORE_THRESHOLD + (100 - RELATEDNESS_SCORE_THRESHOLD) * (p - t) / (1 - t)).round
  end
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
  if $RELATED_LEARNED_MODE == "replace"
    learned = learned_relatedness_score(signals)
    if learned
      p = learned_relatedness_probability(signals)
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
    learned = learned_relatedness_score(signals)
    if learned
      p = learned_relatedness_probability(signals)
      contributions << [learned, format("learned: p=%.3f", p)]
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

# True iff the two headwords are judged topically related. Symmetric in +word1+ / +word2+:
# similarity and ConceptNet edges are symmetric; gloss checks both directions; sense-vector
# and morphy paths use max/min of the two directional cosines; USF two-hop tries both orders.
#
# Stop words (+stop_word?+) are treated as related to every other word — they're
# contentless glue that legitimately appears next to anything.
#
# Surfaces are mapped through +lemma+ (dict-build base column) before scoring and memoization, so
# inflected pairs share work and align with base-form Numberbatch / ConceptNet exports.
def thematically_related?(word1, word2, include_self=false)
  if ENV["RELATED_TRACE_THEMATIC"] == "1"
    warn "thematically_related? word1=#{word1.inspect} word2=#{word2.inspect} include_self=#{include_self.inspect}"
  end

  return true if include_self && (word1 == word2 || lemma(word1) == lemma(word2))
  return true if stop_word?(word1) || stop_word?(word2)

  puts "thematically_related? #{word1} #{word2}" if related_trace_memo?

  l1 = lemma(word1)
  l2 = lemma(word2)
  a, b = l1 <= l2 ? [l1, l2] : [l2, l1]
  puts "  -> lemma key #{a} #{b}" if related_trace_memo?
  thematically_related_pair_memoized?(a, b)
end

# Same decision as +thematically_related?+, but returns a short reason string when true, or +nil+ when false.
# Reason is the highest-scoring contribution from +relatedness_contributions+. Uses +lemma+ for scoring like
# +thematically_related?+; +include_self+ treats same headword or same lemma as self when true.
def why_thematically_related?(word1, word2, include_self = false)
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

# Numberbatch + ConceptNet centile score for two dictionary lemmas (no +lemma+ lookup).
# Kept as a public helper for UI / diagnostics; phase-1 signal gathering recomputes the
# same quantity on +PairSignals#base_similarity+ so it can memoize alongside other signals.
def lemmilarity(l1, l2)
  return 0 if stop_word?(l1) || stop_word?(l2)

  cos = numberbatch_cosine(l1, l2)
  edge_w = conceptnet_edge_weight(l1, l2)
  edge_bonus = edge_w > 0 ? $CONCEPTNET_EDGE_BONUS : 0

  (cos * 100).round + edge_bonus
end

def similarity(word1, word2)
  return 0 if stop_word?(word1) || stop_word?(word2)

  lemmilarity(lemma(word1), lemma(word2))
end

def print_similarity(word1, word2)
  puts "#{word1} #{word2}: #{similarity(word1, word2)}"
end

# Enumerates RhymeCrime headwords and returns those topically related to +word+.
class RelatedWords
  class << self
    # +generated/related_precompute.jsonl+ (+bin/precompute-relatedness+): lemma -> related headwords
    # (built with +include_rhymeless+ false, +common_only+ true). At runtime we re-filter like Dynamo
    # (+dynamo_store.rb+ +find_all_related_precomputed+) so callers with other flags still behave correctly.
    def related_precompute_by_lemma
      return @related_precompute_by_lemma if instance_variable_defined?(:@related_precompute_by_lemma)

      @related_precompute_by_lemma = {}
      path = generated_dict_path(RELATED_PRECOMPUTE_JSONL_FILENAME)
      unless File.exist?(path)
        return @related_precompute_by_lemma
      end

      n = 0
      File.foreach(path, encoding: "UTF-8") do |line|
        line = line.strip
        next if line.empty?

        obj = JSON.parse(line)
        pk = obj["pk"].to_s
        next unless pk.start_with?("related#")

        lem = pk.delete_prefix("related#")
        words = obj["words"]
        next unless words.is_a?(Array)

        @related_precompute_by_lemma[lem] = words.map(&:to_s)
        n += 1
      end
      puts "loaded #{n} precomputed related lemmas from #{path}" if n.positive?
      @related_precompute_by_lemma
    rescue JSON::ParserError => e
      warn "related: skip precompute load (#{path}): #{e.message}"
      @related_precompute_by_lemma = {}
    end

    def filter_precomputed_related_word_list(raw, include_rhymeless, common_only)
      return [] if raw.nil? || raw.empty?
      unless defined?(lexicon_word_entry) && defined?(rdict_lookup)
        return raw.dup
      end

      raw.select do |w|
        entry = lexicon_word_entry(w)
        next false unless entry

        next false if common_only && entry[0].to_i <= RARE_FREQ_MAX

        if include_rhymeless
          true
        else
          entry[1].any? { |pron| !pron.rime.to_s.empty? && !rdict_lookup(pron.rime).empty? }
        end
      end
    end

    # +max_candidates+ default +SIMILAR_MAX+ caps the list by Numberbatch-centile +similarity+ for UI / display.
    # Pass +nil+ for no cap (e.g. set_related / pair rhyming): truncation can drop words that are related via
    # gloss or sense vectors but rank below the cap on +similarity+ alone.
    # When +common_only+ is true, only non-+rare?+ headwords from +words_we_care_about+ are candidates.
    def find_thematically_related_words(word, include_self, include_rhymeless = true, common_only = false, max_candidates = SIMILAR_MAX)
      words = find_all_thematically_related_words(word, include_rhymeless, common_only)
      words.push(word) if include_self
      if max_candidates && words.length > max_candidates
        words = words.sort_by { |w| -similarity(w, word) }
        words = words[0..max_candidates - 1]
      end
      words
    end

    def find_all_thematically_related_words(word, include_rhymeless = true, common_only = false)
      @related_word_cache ||= {}
      key = [word, include_rhymeless, common_only]
      return @related_word_cache[key] if @related_word_cache.key?(key)

      # Stop words (+stop_word?+) are related to every other word; short-circuit to
      # +words_we_care_about+ rather than a per-pair scan / precompute lookup, which
      # is both wasteful and (for Dynamo / JSONL) not populated for stop-word keys
      # (see +bin/precompute-relatedness+, which skips them).
      if stop_word?(word) || stop_word?(lemma(word))
        words = words_we_care_about(include_rhymeless, common_only).reject { |w| w == word }
        debug "Finding words related to #{word} (stop word, all candidates)... #{words.length}\n"
        @related_word_cache[key] = words
        return words
      end

      if defined?(Rhymecrime::DataSource) && Rhymecrime::DataSource.dynamodb?
        lemma_key = lemma(word)
        words = Rhymecrime::DynamoRuntime.find_all_related_precomputed(lemma_key, include_rhymeless, common_only)
        debug "Finding words related to #{word} (Dynamo, lemma=#{lemma_key})... #{words.length}\n"
        @related_word_cache[key] = words
        return words
      end

      pc = related_precompute_by_lemma
      if !pc.empty?
        lemma_key = lemma(word)
        raw = pc[lemma_key]
        if raw
          words = filter_precomputed_related_word_list(raw, include_rhymeless, common_only)
          debug "Finding words related to #{word} (precompute, lemma=#{lemma_key})... #{words.length}\n"
          @related_word_cache[key] = words
          return words
        end
      end

      unless dictionary_lemma_has_numberbatch_vector?(word)
        if ENV["RHYMECRIME_WARN_OOV_NUMBERBATCH"] == "1"
          warn "related: skipping full scan for '#{word}' (lemma '#{lemma(word)}' not in Numberbatch export)"
        end
        debug "Finding words related to #{word}... 0 (no Numberbatch vector for lemma)\n"
        @related_word_cache[key] = []
        return []
      end

      words = []
      debug "Finding words related to #{word}... "
      words_we_care_about(include_rhymeless, common_only).each do |w|
        if w != word && thematically_related?(word, w)
          words.push(w)
        end
      end
      debug "#{words.length}\n"
      @related_word_cache[key] = words
    end
  end
end

def similarity_color(similarity)
  case similarity
  when -1..0.29999999
    "#ff5555" # red
  when 0.30..0.33999999
    "orange"
  when 0.34..0.35999999
    "yellow"
  when 0.36..0.37999999
    "#00cc22" # green
  when 0.38..0.39999999
    "#8888ff" # blue
  when 0.40..0.41999999
    "#aa33cc" # purple
  when 0.42..0.44999999
    "violet"
  else
    "white"
  end
end

def print_similarity_color_legend_entry(similarity, text)
  cgi_print "<td style='color: #{similarity_color(similarity)}'><font size=-2>#{text}</font></td><td>&nbsp;</td>"
end

def print_similarity_color_legend
  cgi_print "<table><tr><td><font size=-2>legend:&nbsp;</font></td>"
  print_similarity_color_legend_entry(0.30, "unrelated")
  print_similarity_color_legend_entry(0.35, "almost related")
  print_similarity_color_legend_entry(0.38, "barely related")
  print_similarity_color_legend_entry(0.39, "weakly related")
  print_similarity_color_legend_entry(0.40, "somewhat related")
  print_similarity_color_legend_entry(0.41, "related")
  print_similarity_color_legend_entry(0.42, "strongly related")
  print_similarity_color_legend_entry(0.50, "related af")
  cgi_print "</tr></table>"
end

def word_similarity_color(word1, word2)
  similarity_color(similarity(word1, word2))
end

def percent_similarity(word1, word2)
  "#{similarity(word1, word2)}%"
end

def print_html_percent_similarity(word, focal_word)
  cgi_print " <span style='color: #{word_similarity_color(word, focal_word)}'>(#{percent_similarity(word, focal_word)})</span>"
end
