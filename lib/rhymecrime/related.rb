#!/usr/bin/env ruby
# coding: utf-8
#
# related.rb — word relatedness (Numberbatch, ConceptNet, WordNet, USF, …). Load: require "rhymecrime/related"
#
# Determine topical relatedness of two words
# or retrieve a list of topically related words.
#
# Combines multiple offline signals:
#   1. Numberbatch cosine similarity + ConceptNet edge bonus (primary)
#   2. WordNet gloss containment (high-precision rescue for polysemy)
#   3. WordNet gloss-vector sense embeddings + morphy fallback (secondary rescue)
#   4. USF Free Association 2-hop (boost to base score via human association graph)
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

SIMILAR_MAX = 500

# --- Tunable parameters (optimized via anneal.rb / parameter sweeps) ---

$SIMILARITY_THRESHOLD = 10
$CONCEPTNET_EDGE_BONUS = 7
$SENSE_VECTOR_THRESHOLD = 9
$SENSE_VECTOR_MIN_FLOOR = 5
$SENSE_VECTOR_MORPHY_FLOOR = 13
$SENSE_VECTOR_MIN_BASE = 6
$SENSE_VECTOR_MAX_SENSES = 4
$USF_TWOHOP_BOOST = 10
$USF_MIN_BRIDGE_COS = 8
# Skip USF graph work when primary score is below this (0 = same as pre-filter behavior).
$USF_MIN_BASE = 0

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
      cos_ab = numberbatch_cosine(a, bridge)
      cos_bb = numberbatch_cosine(bridge, b)
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

def numberbatch_cosine(word1, word2)
  nb = numberbatch_table
  v1 = nb[hyphens_to_underscores(word1)]
  v2 = nb[hyphens_to_underscores(word2)]
  return 0.0 if v1.nil? || v2.nil?
  dot = 0.0
  v1.size.times { |i| dot += v1[i] * v2[i] }
  dot
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
    v1 = nb[hyphens_to_underscores(word)]
    v2 = nb[hyphens_to_underscores(d)]
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
      embeds = content_words.filter_map { |w| nb[hyphens_to_underscores(w)] }
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
        embeds = content_words.filter_map { |w| nb[hyphens_to_underscores(w)] }
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

# --- Main scoring ---

def similarity_threshold
  $SIMILARITY_THRESHOLD
end

# True iff the two headwords are judged topically related. Symmetric in +word1+ / +word2+:
# similarity and ConceptNet edges are symmetric; gloss checks both directions; sense-vector
# and morphy paths use max/min of the two directional cosines; USF two-hop tries both orders.
def thematically_related?(word1, word2, include_self=false)
  if ENV["RELATED_TRACE_THEMATIC"] == "1"
    warn "thematically_related? word1=#{word1.inspect} word2=#{word2.inspect} include_self=#{include_self.inspect}"
  end

  base = similarity(word1, word2)
  return true if base >= $SIMILARITY_THRESHOLD

  return true if bidirectional_gloss_contains?(word1, word2)

  if !stop_word?(word1) && !stop_word?(word2) && base >= $SENSE_VECTOR_MIN_BASE
    d1, d2 = directional_sense_cosines(word1, word2)
    sv_max = [d1, d2].max
    sv_min = [d1, d2].min
    both_have_senses = sense_vectors(word1).size > 0 && sense_vectors(word2).size > 0
    if both_have_senses
      return true if sv_max >= $SENSE_VECTOR_THRESHOLD && sv_min >= $SENSE_VECTOR_MIN_FLOOR
    elsif $SENSE_VECTOR_MORPHY_FLOOR > 0
      morphy_result = morphy_directional_sense_cosines(word1, word2)
      if morphy_result
        md1, md2 = morphy_result
        return true if [md1, md2].max >= $SENSE_VECTOR_THRESHOLD && [md1, md2].min >= $SENSE_VECTOR_MORPHY_FLOOR
      end
    end
  end

  if $USF_TWOHOP_BOOST > 0 &&
     base >= $USF_MIN_BASE &&
     (base + $USF_TWOHOP_BOOST) >= $SIMILARITY_THRESHOLD &&
     usf_twohop_bridge_validated?(word1, word2)
    return true
  end

  false
end

# Same decision as +thematically_related?+, but returns a short reason string when true, or +nil+ when false.
# Order of checks matches +thematically_related?+ (first win is reported). +include_self+ is accepted for API
# parity; it is not used by the predicate today.
def why_thematically_related?(word1, word2, include_self = false)
  base = similarity(word1, word2)
  if base >= $SIMILARITY_THRESHOLD
    return "similarity: #{base} >= #{$SIMILARITY_THRESHOLD} (Numberbatch centiles + ConceptNet edge bonus)"
  end

  if bidirectional_gloss_contains?(word1, word2)
    return "gloss: bidirectional WordNet gloss/derivation containment"
  end

  if !stop_word?(word1) && !stop_word?(word2) && base >= $SENSE_VECTOR_MIN_BASE
    d1, d2 = directional_sense_cosines(word1, word2)
    sv_max = [d1, d2].max
    sv_min = [d1, d2].min
    both_have_senses = sense_vectors(word1).size > 0 && sense_vectors(word2).size > 0
    if both_have_senses
      if sv_max >= $SENSE_VECTOR_THRESHOLD && sv_min >= $SENSE_VECTOR_MIN_FLOOR
        return "sense_vectors: directional max=#{sv_max} min=#{sv_min} (need max>=#{$SENSE_VECTOR_THRESHOLD} min>=#{$SENSE_VECTOR_MIN_FLOOR}; base similarity=#{base})"
      end
    elsif $SENSE_VECTOR_MORPHY_FLOOR > 0
      morphy_result = morphy_directional_sense_cosines(word1, word2)
      if morphy_result
        md1, md2 = morphy_result
        mx = [md1, md2].max
        mn = [md1, md2].min
        if mx >= $SENSE_VECTOR_THRESHOLD && mn >= $SENSE_VECTOR_MORPHY_FLOOR
          return "sense_vectors_morphy: directional max=#{mx} min=#{mn} (need max>=#{$SENSE_VECTOR_THRESHOLD} min>=#{$SENSE_VECTOR_MORPHY_FLOOR}; base similarity=#{base})"
        end
      end
    end
  end

  if $USF_TWOHOP_BOOST > 0 &&
     base >= $USF_MIN_BASE &&
     (base + $USF_TWOHOP_BOOST) >= $SIMILARITY_THRESHOLD &&
     usf_twohop_bridge_validated?(word1, word2)
    boosted = base + $USF_TWOHOP_BOOST
    return "usf_twohop: base=#{base} + boost=#{$USF_TWOHOP_BOOST} => #{boosted} >= #{$SIMILARITY_THRESHOLD}, validated bridge"
  end

  nil
end

def similarity(word1, word2)
  return 0 if stop_word?(word1) || stop_word?(word2)

  # Primary signal: Numberbatch cosine (0.0..1.0 range, scaled to integer centiles)
  cos = numberbatch_cosine(word1, word2)

  # ConceptNet edge bonus: if a direct knowledge-graph edge exists, boost score
  edge_w = conceptnet_edge_weight(word1, word2)
  edge_bonus = edge_w > 0 ? $CONCEPTNET_EDGE_BONUS : 0

  # Score in centiles (threshold 9 = cosine 0.09)
  (cos * 100).round + edge_bonus
end

def print_similarity(word1, word2)
  puts "#{word1} #{word2}: #{similarity(word1, word2)}"
end

# Enumerates RhymeCrime headwords and returns those topically related to +word+.
class RelatedWords
  class << self
    # +max_candidates+ default +SIMILAR_MAX+ caps the list by Numberbatch-centile +similarity+ for UI / display.
    # Pass +nil+ for no cap (e.g. set_related / pair rhyming): truncation can drop words that are related via
    # gloss or sense vectors but rank below the cap on +similarity+ alone.
    def find_thematically_related_words(word, include_self, include_rhymeless = true, max_candidates = SIMILAR_MAX)
      words = find_all_thematically_related_words(word, include_rhymeless)
      words.push(word) if include_self
      if max_candidates && words.length > max_candidates
        words = words.sort_by { |w| -similarity(w, word) }
        words = words[0..max_candidates - 1]
      end
      words
    end

    def find_all_thematically_related_words(word, include_rhymeless = true)
      @related_word_cache ||= {}
      key = [word, include_rhymeless]
      return @related_word_cache[key] if @related_word_cache.key?(key)

      words = []
      debug "Finding words related to #{word}... "
      words_we_care_about.each do |w|
        if w != word && (include_rhymeless || has_rhyming_word?(word)) && thematically_related?(word, w)
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
