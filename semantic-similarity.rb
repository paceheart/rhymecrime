#!/usr/bin/env ruby
# coding: utf-8
#
# Determine semantic similarity of two words
# or retrieve a list of semantically related words
#

require_relative 'Cosine'
require 'msgpack'

EMBED_VEC_FILE = 'wiki-news-subword-220k.vec'
SIMILARITY_THRESHOLD = 0.34
#print "SIMILARITY_THRESHOLD = #{SIMILARITY_THRESHOLD}\n"
SIMILAR_MAX = 500

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

def embed_dict_file
  result = EMBED_VEC_FILE
  result = result.gsub(".vec", ".msgpack")
  result = result.gsub(".txt", ".msgpack")
  return result
end

def load_embed_dict
  MessagePack.unpack(File.binread(embed_dict_file))
end

def save_embed_dict()
  pickled_embed_dict = $embed_dict.to_msgpack
  File.binwrite(embed_dict_file, pickled_embed_dict)
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

def percent_similarity_threshold
  (SIMILARITY_THRESHOLD * 100).round
end

def semantically_related?(word1, word2, include_self=false)
  # Is word1 semantically related to word2?
  similarity(word1, word2) >= SIMILARITY_THRESHOLD
end

def similarity(word1, word2)
  if stop_word?(word1) or stop_word?(word2)
    return 0
  end
  vec1 = get_embedding(word1)
  vec2 = get_embedding(word2)
  if vec1.nil? or vec2.nil?
    return 0
  else
    return Cosine.new(vec1, vec2).calculate_similarity().round(2)
  end
end

def percent_similarity(word1, word2)
  "#{(similarity(word1, word2) * 100).round()}%"
end

def print_similarity(word1, word2)
  println(word1 + " " + word2 + ": " + percent_similarity(word1, word2))
end

$related_dict = nil
def related_dict
  # word => array of semantically related words
  if $related_dict.nil?
    $related_dict = load_related_dict
  end
  $related_dict
end

def load_related_dict
  Hash.new() # @todo load from cache
end
  
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

def find_all_semantically_related_words(word, include_rhymeless=true)
  if related_dict().key?(word)
    return related_dict()[word]
  else
    result = really_find_all_semantically_related_words(word, include_rhymeless)
    related_dict()[word] = result
  end
end

def really_find_all_semantically_related_words(word, include_rhymeless=true)
  words = []
  debug "Finding words related to #{word}... "
  for w in word_dict().keys do
    if w != word and (include_rhymeless or has_rhyming_word?(word)) and semantically_related?(word, w)
      words.push(w)
    end
  end
  debug "#{words.length()}\n"
  return words
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
  print_similarity_color_legend_entry(0, "unrelated")
  print_similarity_color_legend_entry(0.30, "almost related")
  print_similarity_color_legend_entry(0.34, "barely related")
  print_similarity_color_legend_entry(0.36, "weakly related")
  print_similarity_color_legend_entry(0.38, "somewhat related")
  print_similarity_color_legend_entry(0.40, "related")
  print_similarity_color_legend_entry(0.42, "strongly related")
  print_similarity_color_legend_entry(0.50, "related af")
  cgi_print "</tr></table>"
end

def word_similarity_color(word1, word2)
  similarity_color(similarity(word1, word2))
end

# tbp
def println(str)
  print str
  print "\n"
end
