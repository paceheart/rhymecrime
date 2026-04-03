#!/usr/bin/env ruby

require 'scalpel'
require_relative 'json_extensions'
require_relative 'pace_utils'
require_relative 'spec/test_utils'
require 'msgpack'

$LIMIT_TO_TEST_WORDS = true # set this to true for testing
$MAX_SENTENCES_PER_DOCUMENT = 1000

$WET_INPUT_FILE_TEMPLATE = "corpus/c4-train.CHUNK_ID-of-01024.json"
# Document-specific and sentence-specific files:
$WET_DOC_SPECIFIC_FILE_TEMPLATE = "index/chunk-CHUNK_ID/_UNIQUIFIER_-LOCAL_DOC_ID.json"
$WET_LOCAL_SENTENCE_INDEX_UNIQUIFIER = "local-sentence-index" # WORD -> local_sentence_ids: the sentences within that document that contain WORD
$WET_LOCAL_DOC_INDEX_UNIQUIFIER = "local-doc-index" # word -> # of occurrences in that document
# Chunk-specific files:
$WET_CHUNK_SPECIFIC_FILE_TEMPLATE = "index/chunk-CHUNK_ID/_UNIQUIFIER_.json"
$WET_METADATA_UNIQUIFIER = 'metadata'
$WET_URLS_UNIQUIFIER = 'urls' # [local_doc_id] -> url
$WET_DOC_SENTENCE_COUNTS_UNIQUIFIER = 'doc-sentence-counts' # local_doc_id -> # of sentences in that document
$WET_SENTENCE_WORD_COUNTS_UNIQUIFIER = 'sentence-word-counts' # local_sentence_id -> # of words in that sentence
$WET_DOC_WORD_COUNTS_UNIQUIFIER = 'doc-word-counts' # local_doc_id -> # of words in that document
$WET_CHUNK_SENTENCE_COUNT_UNIQUIFIER = 'chunk-total-sentence-count'
$WET_CHUNK_WORD_COUNT_UNIQUIFIER = 'chunk-total-word-count'
# Global files:
$WET_GLOBAL_WORD_COUNTS_FILENAME = 'index/global-word-counts.json' # word -> total # of occurrences
$WET_GLOBAL_SENTENCE_INDEX_FILENAME = 'index/global-sentence-index.json' # word -> sentence_ids
$WET_GLOBAL_DOC_INDEX_FILENAME = 'index/global-doc-index.json' # word -> doc_ids
$WET_GLOBAL_SENTENCE_WORD_COUNTS_FILENAME = 'index/global-sentence-word-counts.msgpack' # [doc_id][local_sentence_id] -> # of words in that sentence in that document
$WET_GLOBAL_DOC_SENTENCE_COUNTS_FILENAME = 'index/global-doc-sentence-counts.msgpack'
$WET_GLOBAL_DOC_WORD_COUNTS_FILENAME = 'index/global-doc-word-counts.msgpack'
$WET_GLOBAL_URLS_FILENAME = 'index/global-urls.msgpack'
$WET_TOTAL_SENTENCE_COUNT_FILENAME = 'index/total-sentence-count.json' # total # of sentences in the entire corpus
$WET_TOTAL_DOC_COUNT_FILENAME = 'index/total-doc-count.json' # total # of documents in the entire corpus

def construct_chunk_specific_filename(chunk_id, uniquifier)
  filename = $WET_CHUNK_SPECIFIC_FILE_TEMPLATE
  filename = filename.gsub('CHUNK_ID', chunk_id.to_s.rjust(5, "0"))
  filename = filename.gsub('_UNIQUIFIER_', uniquifier)
  return filename
end

def construct_document_specific_filename(doc_id, uniquifier)
  chunk_id, local_doc_id = split_doc_id(doc_id)
  construct_document_specific_filename(chunk_id, local_doc_id, uniquifier)
end

def construct_document_specific_filename(chunk_id, local_doc_id, uniquifier)
  filename = $WET_DOC_SPECIFIC_FILE_TEMPLATE
  filename = filename.gsub('CHUNK_ID', chunk_id.to_s.rjust(5, "0"))
  filename = filename.gsub('_UNIQUIFIER_', uniquifier)
  filename = filename.gsub('LOCAL_DOC_ID', local_doc_id.to_s.rjust(6, "0"))
  return filename
end

# Assumes no more than a million documents per chunk
def compute_doc_id(chunk_id, local_doc_id)
  return chunk_id * 1000000 + local_doc_id
end

# Return 0 chunk_id
# Return 1 local_doc_id
def split_doc_id(doc_id)
  doc_id.divmod(1000000)
end

# Assumes no more than a thousand sentences per document
def compute_sentence_id(chunk_id, local_doc_id, local_sentence_id)
  doc_id = compute_doc_id(chunk_id, local_doc_id)
  if local_sentence_id >= $MAX_SENTENCES_PER_DOCUMENT
    raise "sentence ID #{local_sentence_id} exceeded max sentences per document threshold (#{$MAX_SENTENCES_PER_DOCUMENT}) for document #{doc_id}"
  end
  return doc_id * $MAX_SENTENCES_PER_DOCUMENT + local_sentence_id
end

# Return 0 doc_id
# Return 1 local_sentence_id
def split_sentence_id(sentence_id)
  sentence_id.divmod($MAX_SENTENCES_PER_DOCUMENT)
end

# Filter out 'sentences' like 'B.'
def non_trivial_sentence?(str)
  str.length > 2 and str.count_alpha > 1
end

def tokenize_by_sentence(text)
  Scalpel.cut(text).select { |s| non_trivial_sentence?(s) }
end

#
# Limit to test words
#

$all_test_words = nil
def all_test_words
  $all_test_words ||= compute_all_test_words
end

def compute_all_test_words
  results = Set.new
#  for file in `ls spec/spec_*.rb`.split
  for file in `ls spec/spec_related.rb`.split
    results.merge(all_test_words_in_rb_file file)
  end
  for file in `ls spec/*.csv`.split
    results.merge(all_test_words_in_csv_file file)
  end
  results.reject! { |w| stop_word?(w) }
  return results
end

def all_test_words_in_csv_file(filename)
  results = Set.new
  for c in load_relatedness_test_cases
    results.add(c['word1'])
    results.add(c['word2'])
  end
  return results
end

def all_test_words_in_rb_file(filename)
  results = Set.new
  for line in IO.readlines(filename, encoding: 'UTF-8')
    if line.include?("ought")
      tokens = line.split /\s+|,\s*/
      for token in tokens
        if token[0] == "'" and token[-1] == "'" and !token.include?('#')
          results.add token[1..-2]
        end
      end
    end
  end
  return results
end

def exclude_word?(word)
  stop_word?(word) || explicitly_forbidden?(word)
end
  
def words_we_care_about_internal
  $LIMIT_TO_TEST_WORDS ? all_test_words : word_dict.keys
end

def word_we_care_about?(word)
   !exclude_word?(word) && words_we_care_about_internal.include?(word)
end

def words_we_care_about
  words_we_care_about_internal.reject { |w| exclude_word? (w) }
end

#
# Chunk-specific
#

def chunk_ids
  `ls -d index/chunk-*`.split.map { |chunk_dir| chunk_dir[-5..-1].to_i }
end
  
def save_chunk_specific_file(filename_uniquifier, object, chunk_id)
  unless object.respond_to?('empty?') and object.empty?
    filename = construct_chunk_specific_filename(chunk_id, filename_uniquifier)
    FileUtils.ensure_file_directory_exists(filename)
    JSON.save(filename, object)
  end
end

# Combine a bunch of files that are stored in chunk directories indexed by local doc_id
# into one big array indexed by doc_id
def load_chunk_specific_doc_files(dir, uniquifier)
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
  
def sum_chunk_specific_files(dir, uniquifier)
  key_count = 0
  value_sum = 0
  for chunk_id in chunk_ids
    chunk_result = JSON.load!(construct_chunk_specific_filename(chunk_id, uniquifier))
    for value in chunk_result
      key_count += 1
      value_sum += value
    end
  end
  return key_count, value_sum
end

#
# Document-specific
#

def save_document_specific_file(filename_uniquifier, object, chunk_id, local_doc_id)
  unless object.respond_to?('empty?') and object.empty?
    filename = construct_document_specific_filename(chunk_id, local_doc_id, filename_uniquifier)
    FileUtils.ensure_file_directory_exists(filename)
    JSON.save(filename, object)
  end
end
