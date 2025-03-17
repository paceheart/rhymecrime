#!/usr/bin/env ruby

# Add up the total number of sentences and documents in the entire corpus,
# then save those totals.

require_relative 'json_extensions'
require_relative 'pace_utils'
require_relative 'WetCorpus'

def save_total_sentence_count(count)
  JSON.save($WET_TOTAL_SENTENCE_COUNT_FILENAME, count)
end

def save_total_doc_count(count)
  JSON.save($WET_TOTAL_DOC_COUNT_FILENAME, count)
end

def total_everything
  total_doc_count, total_sentence_count = sum_chunk_specific_files('.' $WET_DOC_SENTENCE_COUNTS_UNIQUIFIER)
  save_total_sentence_count(total_sentence_count)
  save_total_doc_count(total_doc_count)
end

total_everything
