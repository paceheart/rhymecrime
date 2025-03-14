#!/usr/bin/env ruby

require_relative 'json_extensions'
require_relative 'pace_utils'
require_relative 'WetCorpus'
require 'memery'

class IndexedWetCorpus
  include Memery
  
  String @dir

  Array @urls # array where the index is global doc_id and the value is the URL for that document, just for efficiency to avoid passing long strings around
  Array @doc_sentence_counts # DOC_ID -> total # of sentences in that document
  Array @sentence_word_counts # SENTENCE_ID -> total # of (relevant) words in that sentence
  Array @doc_word_counts # DOC_ID -> total # of (relevant) words in that document
  
  Hash @global_word_counts # WORD -> total # of occurrences across the entire corpus
  Hash @word_doc_ids # WORD -> array of doc_ids containing WORD
  Hash @word_sentence_ids # WORD -> array of sentence IDs containing WORD

  def initialize(directory=".")
    @dir = directory.ensure_trailing_slash

    @urls = load_chunk_specific_files(@dir, $WET_URLS_UNIQUIFIER)
    @doc_sentence_counts = load_chunk_specific_files(@dir, $WET_DOC_SENTENCE_COUNTS_UNIQUIFIER)
    @sentence_word_counts = load_chunk_specific_files(@dir, $WET_SENTENCE_WORD_COUNTS_UNIQUIFIER)
    @doc_word_counts = load_chunk_specific_files(@dir, $WET_DOC_WORD_COUNTS_UNIQUIFIER)
    
    @word_doc_ids = JSON.load!(@dir + $WET_GLOBAL_DOC_INDEX_FILENAME)
    @word_doc_ids = @word_doc_ids.sort_values # @todo remove as soon as we re-collate
    @word_sentence_ids = JSON.load!(@dir + $WET_GLOBAL_SENTENCE_INDEX_FILENAME)
    @word_sentence_ids = @word_sentence_ids.sort_values # @todo remove as soon as we re-collate
    @global_word_counts = JSON.load!(@dir + $WET_GLOBAL_WORD_COUNTS_FILENAME)
  end

  def global_word_count(word)
    @global_word_counts[word] || 0
    #@global_word_counts.key?(word) ? @global_word_counts[word] : 0
  end

  def chunk_ids
    `ls -d word-counts/chunk-*`.split.map { |chunk_dir| chunk_dir[-5..-1].to_i }
  end
  
  def load_chunk_specific_files(dir, uniquifier)
    result = []
    for chunk_id in chunk_ids
      chunk_result = JSON.load!(construct_chunk_specific_filename(chunk_id, uniquifier))
      for value, local_doc_id in chunk_result.each_with_index
        doc_id = compute_doc_id(chunk_id, local_doc_id)
        result[doc_id] = value
      end
    end
    return result
  end
  
  memoize def total_sentence_count
    @doc_sentence_counts.sum_numeric
  end

  memoize def total_doc_count
    @doc_word_counts.non_nil_count
  end

  # for sleuthing
  def print_doc_ids_with_tons_of_sentences
    for doc_sentence_count, doc_id in @doc_sentence_counts.each_with_index
      if doc_sentence_count > 1500
        puts "#{doc_id} -> #{doc_sentence_count}"
      end
    end
  end

  # for sleuthing
  def print_doc_ids_with_tons_of_words
    for doc_word_count, doc_id in @doc_word_counts.each_with_index
      if doc_word_count > 500
        puts "#{doc_id} -> #{doc_word_count}"
      end
    end
  end

  # for sleuthing
  def print_doc_ids_with_tons_of_this_word(word)
    for doc_id in word_doc_ids(word)
      sentence_ids_in_this_doc = word_sentence_ids_in_doc(word, doc_id)
      count = sentence_ids_in_this_doc.length
      if count > 3
        puts "#{count} #{doc_id} #{doc_url(doc_id)}"
        for sentence_id in sentence_ids_in_this_doc
          puts sentence(sentence_id)
        end
      end
    end
  end

  def doc_text(doc_id)
    chunk_id, local_doc_id = split_doc_id(doc_id)
    file = $WET_INPUT_FILE_TEMPLATE.gsub("CHUNK_ID", chunk_id.to_s.rjust(5, "0"))
    json = JSON.parse!(IO.readlines(file)[local_doc_id])
    return json["text"]
  end

  def doc_url(doc_id)
    @urls[doc_id]
  end
  
  def doc_sentences(doc_id)
    tokenize_by_sentence(doc_text(doc_id))
  end

  def sentence(sentence_id)
    doc_id, local_sentence_id = split_sentence_id(sentence_id)
    return doc_sentences(doc_id)[local_sentence_id]
  end

  # Which sentences contain WORD? Return their sentence IDs.
  memoize def word_sentence_ids(word)
    @word_sentence_ids.key?(word) ? @word_sentence_ids[word] : []
  end

  # Which documents contain WORD? Return their doc IDs.
  memoize def word_doc_ids(word)
    @word_doc_ids.key?(word) ? @word_doc_ids[word] : []
  end

  # How many times does WORD occur in DOC_ID?
  def doc_word_occurrence_count(word, doc_id)
    @word_doc_ids.count(doc_id) || 0
  end
  
  # How many sentences contain WORD?
  def word_sentence_count(word)
    word_sentence_ids(word).length
  end

  # How many documents contain WORD?
  def word_doc_count(word)
    word_doc_ids(word).length
  end

  def sentence_in_doc?(sentence_id, doc_id)
    sentence_doc_id, local_sentence_id = split_sentence_id(sentence_id)
    return sentence_doc_id == doc_id
  end
  
  # Which sentences in DOC_ID contain WORD? Return their sentence IDs.
  def word_sentence_ids_in_doc(word, doc_id)
    word_sentence_ids(word).select { |sent_id| sentence_in_doc?(sent_id, doc_id) }
  end

  # How many sentences in DOC_ID conatin WORD?
  def word_sentence_count_in_doc(word, doc_id)
    word_sentence_ids_in_doc(word, doc_id).length
  end

  # Which sentences contain both WORD1 and WORD2? Return their sentence IDs.
  def both_words_sentence_ids(word1, word2)
    word1_sentence_ids = word_sentence_ids(word1)
    word2_sentence_ids = word_sentence_ids(word2)
    return word1_sentence_ids.intersection_assuming_sorted(word2_sentence_ids)
  end

  # Which documents contain both WORD1 and WORD2? Return their doc IDs.
  def both_words_doc_ids(word1, word2)
    word1_docs = word_doc_ids(word1)
    word2_docs = word_doc_ids(word2)
    return word1_docs.intersection_assuming_sorted(word2_docs)
  end

  # How many sentences contain both WORD1 and WORD2?
  def both_words_sentence_count(word1, word2)
    both_words_sentence_ids(word1, word2).length
  end

  # How many documents contain both WORD1 and WORD2?
  def both_words_doc_count(word1, word2)
    both_words_doc_ids(word1, word2).length
  end

  # Return an integer between -100 and 100
  def cooccurrence(word1, word2, use_sentences=true)
    if use_sentences
      word1_count = word_sentence_count(word1)
      word2_count = word_sentence_count(word2)
      both_count = both_words_sentence_count(word1, word2)
      total = total_sentence_count
      result = cooccurrence_1(word1_count, word2_count, both_count, total)
      if $debug_mode
        debug cooccurrence_sentences(word1, word2, 5)
      end
      return result
    else
      word1_count = word_doc_count(word1)
      word2_count = word_doc_count(word2)
      both_count = both_words_doc_count(word1, word2)
      total = total_doc_count
      return cooccurrence_1(word1_count, word2_count, both_count, total)
    end
  end

  def cooccurrence_1(word1_count, word2_count, both_count, total)
    word1_a_priori_prob = word1_count.to_f / total
    word2_a_priori_prob = word2_count.to_f / total
    both_words_independent_prob = word1_a_priori_prob * word2_a_priori_prob # if word1 and word2 were independently distributed, this would be the probability of a document containing both of them
    actual_prob = both_count.to_f / total
    # If the actual probability is less than the independent probability, word1 is negatively correlated with word2.
    # If the actual probability is greater than the independent probability, word1 is positively correlated with word2.
    prob_diff = actual_prob - both_words_independent_prob
    result = massage_prob_diff(prob_diff)
    debug "w1 #{word1_count} w2 #{word2_count} both #{both_count} w1p #{word1_a_priori_prob} w2p #{word2_a_priori_prob} bothp #{both_words_independent_prob} actualp #{actual_prob} pdiff #{prob_diff} result #{result}"
    return result
  end

  def massage_prob_diff(prob_diff)
    if prob_diff == 0
      return 0
    elsif prob_diff <= 0
      return -massage_positive_prob_diff(-prob_diff)
    else
      return massage_positive_prob_diff(prob_diff)
    end
  end

  def massage_positive_prob_diff(prob_diff)
    log_prob_diff = Math.log(prob_diff, 10) # test cases have a range of -5.7..-3.8 (and zero)
    # next we map this to a nice percentage, roughly:
    # -2 -> 100%
    # -3 ->  80%
    # -4 ->  60%
    # -5 ->  40%
    # -6 ->  20%
    # -7 ->   0%
    debug " logdiff #{log_prob_diff}"
    # shifted down by 1 for sentences instead of documents
    if log_prob_diff >= -3
      return 100
    elsif log_prob_diff <= -8
      return 0
    else
      return ((1 + ((log_prob_diff + 3) * 0.2)) * 100).round
    end
  end

  def print_cooccurrence(word1, word2)
    puts "#{word1} #{word2}: #{cooccurrence(word1, word2, true)} #{cooccurrence(word1, word2, false)}"
  end

  def debug_info(word1, word2)
      word1_sentence_count = word_sentence_count(word1)
      word2_sentence_count = word_sentence_count(word2)
      word1_doc_count = word_doc_count(word1)
      word2_doc_count = word_doc_count(word2)
      word1_idf = inverse_document_frequency(word1)
      word2_idf = inverse_document_frequency(word2)
      both_sentence_count = both_words_sentence_count(word1, word2)
      both_doc_count = both_words_doc_count(word1, word2)
    return "\n#{word1} #{word1_sentence_count} #{word1_doc_count} #{word1_idf} #{word2} #{word2_sentence_count} #{word2_doc_count} #{word2_idf} both #{both_sentence_count} #{both_doc_count}"
  end

  # The frequency of WORD within DOC_ID
  def doc_word_frequency(word, doc_id)
    doc_word_occurrence_count(word, doc_id).to_f / @doc_word_counts[doc_id]
  end

  # The rarity of WORD across the corpus
  def inverse_document_frequency(word)
    (Math.log((total_doc_count.to_f + 1) / global_word_count(word) + 1, 10) + 1).round(2)
  end

  def tf_idf(word, doc_id)
    doc_word_frequency(word, doc_id) * inverse_document_frequency(word)
  end

  def cooccurrence_sentences(word1, word2, limit=10)
    sentence_ids = both_words_sentence_ids(word1, word2)
    result = []
    for sentence_id in sentence_ids do
      next if result.length >= limit
      doc_id, local_sentence_id = split_sentence_id(sentence_id)
      result.push(doc_url(doc_id) + " " + sentence(sentence_id))
    end
    return result
  end

  def cooccurrence_documents(word1, word2, limit=10)
    doc_ids = both_words_doc_ids(word1, word2)
    result = []
    for doc_id in doc_ids do
      next if result.length >= limit
      url = doc_url(doc_id)
      sent1 = sentence(word_sentence_ids_in_doc(word1, doc_id)[0])
      sent2 = sentence(word_sentence_ids_in_doc(word2, doc_id)[0])
      result.push([url, sent1, sent2])
    end
    return result
  end

end

def pirate_test(wet)
  test_words = ['ship', 'cache', 'lash', 'cove', 'trove', 'handsome', 'ransom', 'wench', 'gang', 'hang', 'plank', 'peg', 'leg', 'daring', 'swearing', 'hacker', 'cracker', 'sea', 'dvd', 'gold', 'bold', 'buccaneer', 'peer-to-peer', 'commandeer', 'crew', 'tattoo', 'reef', 'thief', 'coast', 'ghost', 'loot', 'pursuit', 'rum', 'saber', 'scurvy', 'pew', 'roc', 'miko', 'mrs.', 'needlework', 'popcorn', 'galaxy', 'ebony', 'ballerina', 'bungee', 'homemade', 'pimping', 'prehistoric', 'reindeer', 'adipose', 'asexual', 'doodle', 'frisbee', 'isaac', 'laser', 'homophobic', 'pedantic']
  test_words = test_words.sort_by { |w| -wet.cooccurrence('pirate', w, false) }
  for word in test_words.sort_by { |w| -wet.cooccurrence('pirate', w) }
    wet.print_cooccurrence('pirate', word)
  end
end

#require 'stackprof'
wet = IndexedWetCorpus.new
#StackProf.run(mode: :cpu, out:'/tmp/crime.dump') do
#  pirate_test(wet)
#end

for word in words_we_care_about.sort_by { |w| -wet.inverse_document_frequency(w) }
  print word
  print " "
  puts wet.inverse_document_frequency(word)
end
