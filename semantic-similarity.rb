#!/usr/bin/env ruby
# coding: utf-8
#
# Determine topical relatedness of two words
# or retrieve a list of topically related words.
#
# Combines multiple offline signals:
#   1. Numberbatch cosine similarity + ConceptNet edge bonus (primary)
#   2. WordNet gloss containment (high-precision rescue for polysemy)
#   3. WordNet gloss-vector sense embeddings + morphy fallback (secondary rescue)
#   4. USF Free Association 2-hop (boost to base score via human association graph)
#   5. ConceptNet 2-hop paths (currently disabled; toggleable via $TWOHOP_ENABLED)
#

require_relative 'Cosine'
require 'json'
require 'msgpack'
require 'rwordnet'
require 'set'
require_relative 'pace_utils'
require_relative 'IndexedWetCorpus'
require_relative 'dict/utils_rhyme'
require_relative 'WordNetReverseDictionary'

WordNet::DB.path = File.join(File.dirname(__FILE__), "dict/WordNet3.1/") unless defined?(WordNet::DB) && WordNet::DB.path

CONCEPTNET_EDGES_FILE = 'conceptnet-edges.json'
CONCEPTNET_EDGES_DICT_FILE = 'dict/generated/conceptnet_edges.json'
NUMBERBATCH_VEC_FILE  = 'numberbatch-vectors.msgpack'
NUMBERBATCH_VEC_DICT_FILE = 'dict/generated/numberbatch_vectors.msgpack'
USF_ASSOCIATIONS_FILE = 'usf-associations.json'
USF_ASSOCIATIONS_DICT_FILE = 'dict/generated/usf_associations.json'

# Legacy embedding files (kept for backward compat; Numberbatch supersedes)
EMBED_VEC_FILE = 'wiki-news-subword-220k.vec'
EMBED_DICT_FILE = 'embed-dict-subword.msgpack'

SIMILAR_MAX = 500

# --- Tunable parameters (optimized via anneal.rb / sweep experiments) ---

$SIMILARITY_THRESHOLD = 10
$CONCEPTNET_EDGE_BONUS = 7
$SENSE_VECTOR_THRESHOLD = 9
$SENSE_VECTOR_MIN_FLOOR = 5
$SENSE_VECTOR_MORPHY_FLOOR = 13
$SENSE_VECTOR_MIN_BASE = 6
$SENSE_VECTOR_MAX_SENSES = 4
$TWOHOP_ENABLED = false
$TWOHOP_MIN_BRIDGE = 3.0
$USF_TWOHOP_BOOST = 10
$USF_MIN_BRIDGE_COS = 8

# Legacy corpus-based parameters (kept for potential hybrid use)
$SENTENCE_SIMILARITY_ADJUSTMENT = 90
$DOC_SIMILARITY_WEIGHT = 0.1
$DOC_SIMILARITY_ADJUSTMENT = -80
$GLOSS_SIMILARITY = 120

# --- ConceptNet edge map ---
# Keys are "word1|word2" (alphabetically sorted), values are edge weights.

$conceptnet_edges = nil
def conceptnet_edges
  return $conceptnet_edges unless $conceptnet_edges.nil?
  path = [CONCEPTNET_EDGES_FILE, CONCEPTNET_EDGES_DICT_FILE].find { |p| File.exist?(p) }
  if path
    $conceptnet_edges = JSON.parse(File.read(path, encoding: "UTF-8"))
    puts "loaded #{$conceptnet_edges.size} ConceptNet edges from #{path}"
  else
    $conceptnet_edges = {}
  end
  $conceptnet_edges
end

def conceptnet_edge_weight(word1, word2)
  key = [word1, word2].sort.join("|")
  conceptnet_edges[key] || 0.0
end

# --- ConceptNet 2-hop adjacency ---
# Infers relatedness through an intermediate node: word1 -> bridge -> word2.
# Returns the minimum edge weight along the best 2-hop path (bottleneck score).

$cn_adjacency = nil
def cn_adjacency
  return $cn_adjacency unless $cn_adjacency.nil?
  $cn_adjacency = Hash.new { |h, k| h[k] = [] }
  conceptnet_edges.each do |key, weight|
    next if weight < 1.0
    a, b = key.split("|")
    $cn_adjacency[a] << [b, weight]
    $cn_adjacency[b] << [a, weight]
  end
  $cn_adjacency
end

def conceptnet_twohop_score(word1, word2)
  best = 0.0
  cn_adjacency[word1].each do |mid, wt1|
    cn_adjacency[mid].each do |dest, wt2|
      best = [[wt1, wt2].min, best].max if dest == word2
    end
  end
  best
end

# --- USF Free Association Norms (Nelson, McEvoy & Schreiber 1998) ---
# 5,019 cue words with ~72K forward association pairs from human participants.
# Used for 2-hop inference: word1 → bridge → word2, validated by requiring
# the bridge word to have positive Numberbatch cosine with both endpoints.

$usf_associations = nil
def usf_associations
  return $usf_associations unless $usf_associations.nil?
  path = [USF_ASSOCIATIONS_FILE, USF_ASSOCIATIONS_DICT_FILE].find { |p| File.exist?(p) }
  if path
    $usf_associations = JSON.parse(File.read(path, encoding: "UTF-8"))
    puts "loaded #{$usf_associations.size} USF cues from #{path}"
  else
    $usf_associations = {}
  end
  $usf_associations
end

def usf_twohop_bridge_validated?(word1, word2)
  [[word1, word2], [word2, word1]].each do |a, b|
    targets_a = usf_associations[a]
    next unless targets_a
    targets_a.each do |bridge, fsg1|
      next if fsg1 < 0.01
      targets_b = usf_associations[bridge]
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
  path = [NUMBERBATCH_VEC_FILE, NUMBERBATCH_VEC_DICT_FILE].find { |p| File.exist?(p) }
  if path
    $numberbatch = MessagePack.unpack(File.binread(path))
    puts "loaded #{$numberbatch.size} Numberbatch vectors from #{path}"
  else
    $numberbatch = {}
  end
  $numberbatch
end

def numberbatch_cosine(word1, word2)
  v1 = numberbatch[word1]
  v2 = numberbatch[word2]
  return 0.0 if v1.nil? || v2.nil?
  dot = 0.0
  v1.size.times { |i| dot += v1[i] * v2[i] }
  dot
end

# --- WordNet gloss containment (high-precision polysemy rescue) ---
# Checks if word1 (or a validated derivational form) literally appears as a word
# in any WordNet definition of word2, or vice versa.

$gloss_derivation_cache = {}

def validated_derivations(word)
  candidates = [word]
  %w[al ian ical ous ic ly ing ed er tion ment s].each { |s| candidates << word + s }
  candidates << word[0..-2] + "ical" if word.end_with?("y")
  candidates << word[0..-2] + "ies" if word.end_with?("y")

  candidates.select do |d|
    next true if d == word
    v1 = numberbatch[word]
    v2 = numberbatch[d]
    next false unless v1 && v2
    dot = 0.0
    v1.size.times { |i| dot += v1[i] * v2[i] }
    dot >= 0.40
  end
end

def gloss_contains?(topic_word, other_word)
  derivations = $gloss_derivation_cache[topic_word] ||= validated_derivations(topic_word)
  WordNet::Lemma.find_all(other_word).each do |lemma|
    lemma.synsets.each do |synset|
      gloss_words = synset.gloss.downcase.scan(/[a-z]+/).to_set
      derivations.each { |d| return true if gloss_words.include?(d) }
    end
  end
  false
end

def bidirectional_gloss_contains?(word1, word2)
  gloss_contains?(word1, word2) || gloss_contains?(word2, word1)
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

def sense_vectors(word, max_senses = $SENSE_VECTOR_MAX_SENSES)
  vecs = []
  count = 0
  WordNet::Lemma.find_all(word).each do |lemma|
    lemma.synsets.each do |synset|
      break if count >= max_senses
      content_words = synset.gloss.downcase.scan(/[a-z]+/) - GLOSS_STOP_WORDS.to_a
      embeds = content_words.filter_map { |w| numberbatch[w] }
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
  vecs
end

def directional_sense_cosines(word1, word2)
  best_1to2 = 0
  best_2to1 = 0

  v2_raw = numberbatch[word2]
  if v2_raw
    sense_vectors(word1).each do |sv|
      dot = 0.0
      sv.size.times { |i| dot += sv[i] * v2_raw[i] }
      score = (dot * 100).round
      best_1to2 = score if score > best_1to2
    end
  end

  v1_raw = numberbatch[word1]
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
        embeds = content_words.filter_map { |w| numberbatch[w] }
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

  if sv1_morphy.any?
    v2_raw = numberbatch[word2]
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
    v1_raw = numberbatch[word1]
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

# --- Legacy embed dict (wiki-news-subword) ---

$embed_dict = nil
def embed_dict
  if $embed_dict.nil?
    begin
      $embed_dict = load_embed_dict
    rescue
      $embed_dict = {}
    end
  end
  $embed_dict
end

def load_embed_dict
  puts "loading embed dict"
  MessagePack.unpack(File.binread(EMBED_DICT_FILE))
end

def save_embed_dict
  File.binwrite(EMBED_DICT_FILE, $embed_dict.to_msgpack)
  $embed_dict
end

def embed_dict_add(word, embedding)
  embed_dict[word] = embedding
end

def compute_embed_dict
  $embed_dict = {}
  is_first_line = true
  print("Loading #{EMBED_VEC_FILE}")
  i = 0
  IO.readlines(EMBED_VEC_FILE, chomp: true, encoding: 'UTF-8').each do |line|
    i += 1
    print "." if i % 1000 == 0
    if is_first_line
      is_first_line = false
    else
      tokens = line.rstrip.split(' ')
      word, *embedding = *tokens
      embed_dict_add(word, embedding.map(&:to_f)) if word_dict.key?(word)
    end
  end
  print(" loaded #{$embed_dict.length} semantic vectors.\n")
end

def compute_and_save_embed_dict
  compute_embed_dict
  save_embed_dict
end

def get_embedding(word)
  embed_dict[word]
end

# --- Corpus ---

$wet = nil
def wet_corpus
  $wet ||= IndexedWetCorpus.new
end

# --- Main scoring ---

def similarity_threshold
  $SIMILARITY_THRESHOLD
end

def semantically_related?(word1, word2, include_self=false)
  base = similarity(word1, word2)
  return true if base >= $SIMILARITY_THRESHOLD

  return true if bidirectional_gloss_contains?(word1, word2)

  if $TWOHOP_ENABLED
    return true if conceptnet_twohop_score(word1, word2) >= $TWOHOP_MIN_BRIDGE
  end

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
     (base + $USF_TWOHOP_BOOST) >= $SIMILARITY_THRESHOLD &&
     usf_twohop_bridge_validated?(word1, word2)
    return true
  end

  false
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

# Legacy corpus-based similarity (kept for anneal.rb backward compat and hybrid experiments)
def corpus_similarity(word1, word2)
  return 0 if stop_word?(word1) || stop_word?(word2)
  sentence_cooccurrence = wet_corpus.cooccurrence(word1, word2, true) + $SENTENCE_SIMILARITY_ADJUSTMENT
  doc_cooccurrence = wet_corpus.cooccurrence(word1, word2, false)
  adjusted_doc_cooccurrence = doc_cooccurrence * $DOC_SIMILARITY_WEIGHT + $DOC_SIMILARITY_ADJUSTMENT
  gloss = adjusted_gloss_cooccurrence(word1, word2)
  r = rarity(word1, word2)
  (sentence_cooccurrence + adjusted_doc_cooccurrence + gloss) * r
end

$wn_dict = nil
def wn_dict
  $wn_dict ||= WordNetReverseDictionary.new
end

def adjusted_gloss_cooccurrence(word, gloss_word)
  wn_dict.gloss_cooccurs?(word, gloss_word) ? $GLOSS_SIMILARITY : 0
end

def rarity(word1, word2)
  idf1 = wet_corpus.inverse_document_frequency(word1)
  idf2 = wet_corpus.inverse_document_frequency(word2)
  most_common_idf = [idf1, idf2].min
  most_common_idf - 1
end

def cosine_similarity(word1, word2)
  vec1 = get_embedding(word1)
  vec2 = get_embedding(word2)
  if vec1.nil? || vec2.nil?
    0
  else
    Cosine.new(vec1, vec2).calculate_similarity.round(2)
  end
end

def print_similarity(word1, word2)
  puts "#{word1} #{word2}: #{similarity(word1, word2)}"
end

class IndexedWetCorpus

  def find_semantically_related_words(word, include_self, include_rhymeless=true)
    words = find_all_semantically_related_words(word, include_rhymeless)
    if(include_self)
      words.push(word)
    end
    if words.length > SIMILAR_MAX
      words = words.sort_by!{|w| -similarity(w, word)}
      words = words[0..SIMILAR_MAX-1]
    end
    return words
  end

  memoize def find_all_semantically_related_words(word, include_rhymeless=true)
    words = []
    debug "Finding words related to #{word}... "
    for w in words_we_care_about do
      if w != word and (include_rhymeless or has_rhyming_word?(word)) and semantically_related?(word, w)
        words.push(w)
      end
    end
    debug "#{words.length()}\n"
    return words
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
