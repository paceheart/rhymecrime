#!/usr/bin/env ruby
# coding: utf-8
#
# Determine semantic similarity of two words
# or retrieve a list of semantically related words
#

require_relative 'Cosine'
require 'msgpack'
require_relative 'pace_utils'
require_relative 'IndexedWetCorpus'
require_relative 'dict/utils_rhyme'

EMBED_VEC_FILE = 'wiki-news-subword-220k.vec'
EMBED_DICT_FILE = 'embed-dict-subword.msgpack'
SIMILAR_MAX = 500
# @todo adjust colors once $SIMILARITY_THRESHOLD is stable
$SIMILARITY_THRESHOLD, $SENTENCE_SIMILARITY_ADJUSTMENT, $DOC_SIMILARITY_WEIGHT, $DOC_SIMILARITY_ADJUSTMENT = 41, 51, 0.13, -42 # -> 62

$embed_dict = nil
def embed_dict()
  # word => array of floats
  if $embed_dict.nil?
    begin
      $embed_dict = load_embed_dict
    rescue
      $embed_dict = compute_and_save_embed_dict
    end
  end
  $embed_dict
end

def load_embed_dict
  puts "loading embed dict"
  MessagePack.unpack(File.binread(EMBED_DICT_FILE))
end

def save_embed_dict()
  pickled_embed_dict = $embed_dict.to_msgpack
  File.binwrite(EMBED_DICT_FILE, pickled_embed_dict)
  return $embed_dict
end

def embed_dict_add(word, embedding)
   embed_dict()[word] = embedding
end

def compute_embed_dict()
  $embed_dict = Hash.new()
  words = word_dict().keys
  isFirstLine = true
  print("Loading #{EMBED_VEC_FILE}")
  i = 0
  for line in IO.readlines(EMBED_VEC_FILE, chomp: true)
    i += 1
    if i % 1000 == 0
      print "."
    end
    if isFirstLine
      isFirstLine = false # ignore header row
    else
      tokens = line.rstrip().split(' ')
      word, *embedding = *tokens
      if word_dict().key?(word)
        embed_dict_add(word, embedding.map(&:to_f))
      end
    end
  end
  print(" loaded #{$embed_dict.length} semantic vectors.\n")
end

def compute_and_save_embed_dict()
  compute_embed_dict
  save_embed_dict
end

def get_embedding(word)
  # Might return nil
  embed_dict()[word]
end

$wet = nil
def wet_corpus
  $wet ||= IndexedWetCorpus.new
end

def similarity_threshold
  $SIMILARITY_THRESHOLD
end

def semantically_related?(word1, word2, include_self=false)
  # Is word1 semantically related to word2?
  similarity(word1, word2) >= $SIMILARITY_THRESHOLD
end

def similarity(word1, word2)
  if stop_word?(word1) or stop_word?(word2)
    return 0
  end
  #cosine_similarity(word1, word2)
  sentence_cooccurrence = wet_corpus.cooccurrence(word1, word2, true) + $SENTENCE_SIMILARITY_ADJUSTMENT
  doc_cooccurrence = wet_corpus.cooccurrence(word1, word2, false)
  adjusted_doc_cooccurrence = doc_cooccurrence * $DOC_SIMILARITY_WEIGHT + $DOC_SIMILARITY_ADJUSTMENT
  rarity = rarity(word1, word2)
  (sentence_cooccurrence + adjusted_doc_cooccurrence) * rarity
end

def rarity(word1, word2)
  idf1 = wet_corpus.inverse_document_frequency(word1)
  idf2 = wet_corpus.inverse_document_frequency(word2)
  most_common_idf = [idf1, idf2].min # the rarity of a word pair is defined by its most common word
  most_common_idf - 1 # subtract 1 to make common words closer to 1
end

def cosine_similarity(word1, word2)
  vec1 = get_embedding(word1)
  vec2 = get_embedding(word2)
  if vec1.nil? or vec2.nil?
    return 0
  else
    return Cosine.new(vec1, vec2).calculate_similarity().round(2)
  end
end

def print_similarity(word1, word2)
  puts(word1 + " " + word2 + ": " + similarity(word1, word2))
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
