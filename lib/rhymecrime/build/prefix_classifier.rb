# frozen_string_literal: true
#
# Prefix-rhyme-filter classifier: maps (word, base, prefix) triples to
# :filter or :allow, using the model trained by bin/train-prefix-classifier.
#
# Two tiers:
#   productive prefixes — listed in the JSON; always return :filter.
#   mixed prefixes      — hybrid GBT/logreg: prefix_model_map selects which
#                         model to use per-prefix (decided by per-prefix CV BA
#                         during training). Falls back to the overall CV winner.
#
# Feature vector matches the training script exactly:
#   bias, cosine, cosine_missing, wiktionary_prefix_template, prefix_len,
#   pfx_<name> (one-hot over the ordered mixed-prefix list stored in the JSON)
#
# Strict-load policy (mirrors rarity_classifier.rb): if the JSON is present
# but its feature-name list doesn't match LEARNED_PREFIX_FEATURE_NAMES, raise
# rather than silently degrading.  Set RHYMECRIME_PREFIX_CLASSIFIER=off to
# disable and fall back to the existing rule-based path.
#
# This file is built-context-only (used by bin/precompute-prefix-gate and any
# build step that calls prefix_pair_classify).  It is NOT loaded at query time;
# allow-list bases are written into word_dict (4th slot) by precompute-prefix-gate.

require "json"
require "fileutils"
require_relative "build_utils"
require_relative "constants"
# Gloss functions (gloss_tokens_for_word, gloss_cites_base?, gloss_word_token_set)
# are provided by rhymecrime/tuples + rhymecrime/relatedness/signals, which the
# caller (bin/precompute-prefix-gate) is responsible for requiring before invoking
# prefix_pair_classify or prefix_feature_vector.

PREFIX_CLASSIFIER_FILENAME = "prefix_classifier.json"

# Keep in lock-step with bin/train-prefix-classifier.  The JSON records its
# own feature-name list so mismatches are detected at load time.
LEARNED_PREFIX_FEATURE_NAMES = %w[
  bias
  cosine
  cosine_missing
  wiktionary_prefix_template
  prefix_len
].freeze
# The per-prefix one-hot features (pfx_<name>) are appended at training time
# and stored in the JSON; their names are NOT fixed here because the set of
# mixed prefixes can grow as curated/prefix.csv is extended.
# These trailing fixed features come after the one-hot block:
LEARNED_PREFIX_TRAILING_FEATURE_NAMES = %w[
  gloss_cites_base
  gloss_base_substring
  gloss_jaccard
  word_senses
  base_senses
  etym_base_sense_match
  base_expected_pos
].freeze
# The JSON's feature_names list is the authoritative ordered list checked at load.

def prefix_classifier_disabled?
  v = ENV["RHYMECRIME_PREFIX_CLASSIFIER"]
  v && %w[off 0 false no disabled].include?(v.downcase)
end

$prefix_classifier      = nil
$prefix_classifier_load = false

def prefix_classifier_json_path
  # In a pipeline build: reads from runtime/ (symlinked from bootstrap/ by bin/build).
  # In a standalone dev session: reads from generated/current/ or generated/.
  generated_dict_path(PREFIX_CLASSIFIER_FILENAME)
end

def prefix_classifier
  return $prefix_classifier if $prefix_classifier_load
  $prefix_classifier_load = true
  return nil if prefix_classifier_disabled?
  path = prefix_classifier_json_path
  unless File.exist?(path)
    raise "prefix classifier not found at #{path}.\n" \
          "Train it via: ./bin/train-prefix-classifier"
  end
  clf = JSON.parse(BuildIo.read(path, encoding: "UTF-8", hint: "prefix_classifier"))
  got      = clf["feature_names"] || []
  expected = LEARNED_PREFIX_FEATURE_NAMES +
             (clf["mixed_prefixes"] || []).map { |p| "pfx_#{p}" } +
             LEARNED_PREFIX_TRAILING_FEATURE_NAMES
  unless got == expected
    raise "prefix classifier feature-name mismatch in #{path}:\n" \
          "  got=#{got.inspect}\n  expected=#{expected.inspect}\n" \
          "Retrain via ./bin/train-prefix-classifier."
  end
  $prefix_classifier = clf
  fallback = clf["model_type"] || "unknown"
  map_summary = (clf["prefix_model_map"] || {}).map { |p, m| "#{p}:#{m}" }.join(", ")
  puts "loaded prefix classifier from #{path} (fallback=#{fallback} prefix_map={#{map_summary}})"
  $prefix_classifier
end

# ---------------------------------------------------------------------------
# Feature extraction (duplicates the logic in bin/train-prefix-classifier so
# the runtime doesn't need to re-require the training script)
# ---------------------------------------------------------------------------

# Vectors are already L2-normalized in numberbatch_vectors.msgpack,
# so cosine similarity equals the dot product.
def _prefix_cosine(v1, v2)
  return 0.0 unless v1 && v2
  v1.each_with_index.sum { |a, i| a * v2[i] }
end

# Base words too semantically general to be meaningful gloss-citation evidence.
# Kept in sync with GLOSS_STOPWORDS in bin/train-prefix-classifier.
PREFIX_GLOSS_STOPWORDS = Set.new(%w[cause]).freeze

def _prefix_has_wik_template?(word, base, wik_templates)
  entries   = wik_templates[word.downcase] || []
  base_bare = base.downcase.gsub(/[^a-z]/, "")
  entries.any? { |ms, _sense| ms.last == base_bare }
end

def _prefix_etym_base_sense_match(word, base, wik_templates)
  entries   = wik_templates[word.downcase] || []
  base_bare = base.downcase.gsub(/[^a-z]/, "")
  matching  = entries.select { |ms, _| ms.last == base_bare }
  return 0.0 if matching.empty?

  sense = matching.filter_map { |_, s| s.empty? ? nil : s }.first
  return 0.5 if sense.nil?

  etym_toks = sense.downcase.scan(/[a-z]+/).reject { |t| t.length < 3 }.to_set
  base_toks  = gloss_word_token_set(base).reject  { |t| t.length < 3 }.to_set
  u = (etym_toks | base_toks).size
  return 0.5 if u.zero?
  (etym_toks & base_toks).size.to_f / u
end

PREFIX_EXPECTED_POS_RT = {
  "a"     => %w[a s n],
  "be"    => %w[a n],
  "co"    => %w[v n],
  "de"    => %w[v],
  "dis"   => %w[a s],
  "en"    => %w[v a n],
  "im"    => %w[a s],
  "in"    => %w[a s],
  "inter" => %w[v n],
  "re"    => %w[v],
  "sub"   => %w[a s n],
  "un"    => %w[a s],
  "under" => %w[v a s],
}.freeze

def _prefix_base_expected_pos_frac(base, prefix)
  expected = PREFIX_EXPECTED_POS_RT[prefix.to_s] || []
  return 0.5 if expected.empty?

  surface = base.to_s.downcase
  lem = lemma(surface) rescue nil
  forms = [surface]
  forms << lem if lem && !forms.include?(lem)

  by_pos = Hash.new(0); total = 0
  wn_available = defined?(WordNet::Lemma) && wordnet_corpora_present?
  forms.each do |f|
    if wn_available
      WordNet::Lemma.find_all(f).each do |l|
        l.synsets.each { |s| total += 1; by_pos[s.pos] += 1 }
      end
    end
    break if total > 0
  end
  return 0.5 if total == 0

  expected.map { |pos| by_pos[pos].to_f / total }.max
rescue StandardError
  0.5
end

def _prefix_sense_count(word)
  surface = word.to_s.downcase
  lem = lemma(surface) rescue nil
  forms = [surface]
  forms << lem if lem && !forms.include?(lem)

  count = 0
  wn_available = defined?(WordNet::Lemma) && wordnet_corpora_present?
  forms.each do |f|
    count += WordNet::Lemma.find_all(f).sum { |l| l.synsets.size } if wn_available
    count += wiktionary_glosses_for(f).size
    break if count > 0
  end
  Math.log(1 + count)
end

def prefix_feature_vector(word, base, prefix, vectors, wik_templates, clf)
  mixed_prefix_list = clf["mixed_prefixes"] || []
  v1  = vectors[word]
  v2  = vectors[base]
  cos = _prefix_cosine(v1, v2)

  toks    = gloss_tokens_for_word(word)
  base_lc = base.downcase
  base_is_stopword = PREFIX_GLOSS_STOPWORDS.include?(base_lc)
  cites     = base_is_stopword || toks.empty? ? 0.0 :
              (gloss_cites_base?(word, base) ? 1.0 : 0.0)
  substring = base_is_stopword || toks.empty? || base_lc.length < 3 ? 0.0 :
              (toks.any? { |t| t != word.downcase && t.include?(base_lc) } ? 1.0 : 0.0)

  t1 = gloss_word_token_set(word).reject { |t| t.length < 3 }.to_set
  t2 = gloss_word_token_set(base).reject { |t| t.length < 3 }.to_set
  u  = (t1 | t2).size
  jaccard = u.zero? ? 0.0 : (t1 & t2).size.to_f / u

  w_senses         = _prefix_sense_count(word)
  b_senses         = _prefix_sense_count(base)
  etym_sense_match = _prefix_etym_base_sense_match(word, base, wik_templates)
  base_expected_pos = _prefix_base_expected_pos_frac(base, prefix)

  [
    1.0,
    cos,
    (v1.nil? || v2.nil?) ? 1.0 : 0.0,
    _prefix_has_wik_template?(word, base, wik_templates) ? 1.0 : 0.0,
    prefix.length.to_f / 10.0,
  ] + mixed_prefix_list.map { |p| prefix == p ? 1.0 : 0.0 } +
    [cites, substring, jaccard, w_senses, b_senses, etym_sense_match,
     base_expected_pos]
end

# ---------------------------------------------------------------------------
# Inference helpers (GBT)
# ---------------------------------------------------------------------------

def _pclf_sigmoid(z)
  z >= 0 ? 1.0 / (1.0 + Math.exp(-z)) : (ez = Math.exp(z); ez / (1.0 + ez))
end

def _pclf_tree_predict(nodes, row)
  idx = 0
  loop do
    n = nodes[idx]
    return n["v"] if n.key?("v")
    idx = row[n["f"]] <= n["t"] ? n["l"] : n["r"]
  end
end

def _pclf_gbt_prob(feats, model)
  score = model["bias"].to_f
  lr    = model["lr"].to_f
  model["trees"].each { |t| score += lr * _pclf_tree_predict(t, feats) }
  _pclf_sigmoid(score)
end

def _pclf_logreg_prob(feats, model)
  means = model["means"]
  stds  = model["stds"]
  w     = model["weights"]
  z = 0.0
  feats.each_with_index do |v, i|
    if i.zero?
      x = v
    else
      s = stds[i]; x = s > 1e-12 ? (v - means[i]) / s : 0.0
    end
    z += w[i] * x
  end
  _pclf_sigmoid(z)
end

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

# Returns :filter, :allow, or nil (classifier disabled / prefix unknown).
# vectors:      Hash word => Array<Float>  (from numberbatch_vectors.msgpack)
# wik_templates: Hash word => [[morpheme...], ...]  (from kaikki etymology)
def prefix_pair_classify(word, base, prefix, vectors:, wik_templates:)
  clf = prefix_classifier
  return nil if clf.nil?

  productive = clf["productive_prefixes"] || []
  return :filter if productive.include?(prefix)

  mixed = clf["mixed_prefixes"] || []
  return nil unless mixed.include?(prefix)

  feats = prefix_feature_vector(word, base, prefix, vectors, wik_templates, clf)

  # Hybrid dispatch: per-prefix CV winner, falling back to overall CV winner
  map      = clf["prefix_model_map"] || {}
  type     = map[prefix] || clf["model_type"]
  m        = clf["#{type}_model"] || clf["model"]
  prob_filter = case type
                when "gbt"    then _pclf_gbt_prob(feats, m)
                when "logreg" then _pclf_logreg_prob(feats, m)
                else raise "unknown prefix classifier model_type: #{type.inspect}"
                end
  prob_filter >= 0.5 ? :filter : :allow
end
