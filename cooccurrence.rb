#!/usr/bin/env ruby

# NOTE: this is not scalable - it'll have to be rearchitected to work on EMR or something

require_relative 'json_extensions'
require_relative 'pace_utils'
require_relative 'globals'

#$word_counts = JSON.load!(GLOBAL_WORD_FREQUENCY_FILENAME)
#$doc_index = JSON.load!(GLOBAL_DOC_INDEX_FILENAME)
$doc_word_counts = JSON.load!(DOC_WORD_COUNTS_FILENAME)

# Which documents contain WORD? Return their IDs.
def word_doc_ids(word)
  $doc_index.key?(word) ? $doc_index[word] : []
end

# How many documents contain WORD?
def word_doc_count(word)
  word_doc_ids(word).length
end

def total_doc_count
  # @todo compute
  356316
end

# Which documents contain both WORD1 and WORD2? Return their IDs.
def both_words_doc_ids(word1, word2)
  word1_docs = word_doc_ids(word1)
  word2_docs = word_doc_ids(word2)
  return word1_docs.intersection(word2_docs)
end

# How many documents contain both WORD1 and WORD2?
def both_words_doc_count(word1, word2)
  both_words_doc_ids(word1, word2).length
end

def cooccurrence(word1, word2)
  word1_doc_count = word_doc_count(word1)
  word2_doc_count = word_doc_count(word2)
  both_doc_count = both_words_doc_count(word1, word2)
  word1_a_priori_prob = word1_doc_count.to_f / total_doc_count
  word2_a_priori_prob = word2_doc_count.to_f / total_doc_count
  both_words_independent_prob = word1_a_priori_prob * word2_a_priori_prob # if word1 and word2 were independently distributed, this would be the probability of a document containing both of them
  actual_prob = both_doc_count.to_f / total_doc_count
  # If the actual probability is less than the independent probability, word1 is negatively correlated with word2.
  # If the actual probability is greater than the independent probability, word1 is positively correlated with word2.
  prob_diff = actual_prob - both_words_independent_prob
  #println "w1 #{word1_doc_count} w2 #{word2_doc_count} both #{both_doc_count} w1p #{word1_a_priori_prob} w2p #{word2_a_priori_prob} bothp #{both_words_independent_prob} actualp #{actual_prob} pdiff #{prob_diff}"
  return prob_diff * 130000 # just to make the numbers nice-sized
end

def print_cooccurrence(word1, word2)
  println "#{word1} #{word2}: #{cooccurrence(word1, word2).round(2) * 100}%"
end

def cooccurrence_contexts(word1, word2, limit=5)
end

# for sleuthing
def print_doc_ids_with_tons_of_words
  for doc_id in 0..$doc_word_counts.length-1
    doc_word_count = $doc_word_counts[doc_id]
    if doc_word_count > 500
      println "#{doc_id} -> #{doc_word_count}"
    end
  end
end
