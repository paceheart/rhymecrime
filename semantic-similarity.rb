#!/usr/bin/env ruby
# coding: utf-8
#
# Determine semantic similarity of two words
# or retrieve a list of semantically related words
#

require_relative 'Cosine'
require 'msgpack'
#require_relative 'crime'

EMBED_VEC_FILE = 'wiki-news-220k.vec'
EMBED_DICT_FILE = 'embed-dict.msgpack'
SIMILARITY_THRESHOLD = 0.42
print "SIMILARITY_THRESHOLD = #{SIMILARITY_THRESHOLD}\n"

$embed_dict = nil
def embed_dict()
  # word => array of floats
  if $embed_dict.nil?
    #$embed_dict = compute_and_save_embed_dict # @todo robustify
    $embed_dict = load_embed_dict
  end
  $embed_dict
end

def load_embed_dict
  MessagePack.unpack(File.binread(EMBED_DICT_FILE))
end

def save_embed_dict()
  pickled_embed_dict = $embed_dict.to_msgpack
  File.binwrite(EMBED_DICT_FILE, pickled_embed_dict)
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

def semantically_related?(word1, word2, include_self=false, lang="en")
  # Is word1 semantically related to word2?
  similarity(word1, word2) >= SIMILARITY_THRESHOLD
end

def similarity(word1, word2)
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

def find_semantically_related_words(word, include_self, lang)
  words = find_all_semantically_related_words(word)
  if(include_self)
    words.push(word)
  end
  return words
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
  
def find_all_semantically_related_words(word)
  if related_dict().key?(word)
    return related_dict()[word]
  else
    result = really_find_all_semantically_related_words(word)
    related_dict()[word] = result
  end
end

def really_find_all_semantically_related_words(word)
  words = []
  for w in word_dict().keys do
    if w != word and semantically_related?(word, w)
      words.push(w)
    end
  end
  return words
end

# tbp
def println(str)
  print str
  print "\n"
end

def test_stuff
  print_similarity('cat', 'meow')
  print_similarity('cat', 'meow')
  print_similarity('mow', 'lawn')
  print_similarity('mow', 'mows')
  print_similarity('mow', 'mowed')
  print_similarity('mow', 'moll')
  print_similarity('mow', 'mosh')
end

# Main
#compute_and_save_embed_dict
#test_stuff
