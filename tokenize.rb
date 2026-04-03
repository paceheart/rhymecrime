#!/usr/bin/env ruby

# creates:
#   @url: # array DOC_ID -> the URL for that document, just for efficiency to avoid passing long strings around
#   @doc_sentence_counts: array LOCAL_DOC_ID -> the total number of sentences in the document
#   @doc_word_counts: array LOCAL_DOC_ID -> the total number of relevant words in the document
#   for each DOC_ID, a file containing a hash WORD -> COUNT # the number of times WORD appears in that document
#   @sentence_word_counts: array LOCAL_DOC_ID, LOCAL_SENTENCE_ID -> the total number of relevant words in that sentence

require_relative 'WetCorpus'
require_relative 'json_extensions'
require_relative 'fileutils_extensions'
require_relative 'pace_utils'
require_relative 'dict/utils_rhyme'

# We assume the data has already been deduped
$urls = Array.new
def note_url_local_doc_id(url)
  $urls.push(url)
  return $urls.length-1
end

$sentence_word_counts = ArrayOfIntegerArrays.new
def note_sentence_word_count(local_doc_id, local_sentence_id, word_count)
  $sentence_word_counts[local_doc_id][local_sentence_id] = word_count
end

$doc_sentence_counts = []
def note_doc_sentence_count(local_doc_id, sentence_count)
  $doc_sentence_counts[local_doc_id] = sentence_count
end

$doc_word_counts = []
def note_doc_word_count(local_doc_id, word_count)
  $doc_word_counts[local_doc_id] = word_count
end

def save_local_sentence_index(local_sentence_index, chunk_id, local_doc_id)
  save_document_specific_file($WET_LOCAL_SENTENCE_INDEX_UNIQUIFIER, local_sentence_index, chunk_id, local_doc_id)
end

def save_local_doc_index(local_doc_index, chunk_id, local_doc_id)
  save_document_specific_file($WET_LOCAL_DOC_INDEX_UNIQUIFIER, local_doc_index, chunk_id, local_doc_id)
end

def save_urls(chunk_id)
  save_chunk_specific_file($WET_URLS_UNIQUIFIER, $urls, chunk_id)
end

def save_doc_sentence_counts(chunk_id)
  save_chunk_specific_file($WET_DOC_SENTENCE_COUNTS_UNIQUIFIER, $doc_sentence_counts, chunk_id)
end

def save_sentence_word_counts(chunk_id)
  save_chunk_specific_file($WET_SENTENCE_WORD_COUNTS_UNIQUIFIER, $sentence_word_counts, chunk_id)
end

def save_doc_word_counts(chunk_id)
  save_chunk_specific_file($WET_DOC_WORD_COUNTS_UNIQUIFIER, $doc_word_counts, chunk_id)
end

def save_chunk_sentence_count(chunk_id)
  save_chunk_specific_file($WET_CHUNK_SENTENCE_COUNT_UNIQUIFIER, $doc_sentence_counts.sum, chunk_id)
end

def save_chunk_word_count(chunk_id)
  save_chunk_specific_file($WET_CHUNK_WORD_COUNT_UNIQUIFIER, $doc_word_counts.sum, chunk_id)
end

def compute_and_save_metadata(chunk_id, input_file)
  metadata = ""
  metadata += "Input file: #{input_file}\n"
  metadata += "Relevant words: "
  if $LIMIT_TO_TEST_WORDS
    metadata += "#{all_test_words.length}, namely #{all_test_words.to_a}"
  else
    metadata += "all"
  end
  metadata += "\n"
  filename = construct_chunk_specific_filename(chunk_id, $WET_METADATA_UNIQUIFIER).gsub('.json', '.txt')
  FileUtils.ensure_file_directory_exists(filename)
  File.write(filename, metadata)
  print metadata
end

def tokenize_json_doc(json, chunk_id)
  text = json["text"]
  url = json["url"]
  local_doc_id = note_url_local_doc_id(url)
  doc_word_count = 0
  local_sentence_index = Hash.new_hash_of_integer_arrays
  local_doc_index = Hash.new(0)
  local_sentence_id = 0
  for sentence in tokenize_by_sentence(text)
    if local_sentence_id < $MAX_SENTENCES_PER_DOCUMENT
      sentence_word_count = 0
      for word in sentence.scan(/[\w'-]+|[[:punct:]]+/)
        word = word.downcase
        if word_we_care_about?(word)
          local_sentence_index.push(word, local_sentence_id)
          local_doc_index[word] += 1
          doc_word_count += 1
          sentence_word_count += 1
        end
      end
      note_sentence_word_count(local_doc_id, local_sentence_id, sentence_word_count)
    end
    local_sentence_id += 1
  end
  if local_sentence_id > $MAX_SENTENCES_PER_DOCUMENT
    print "Document #{local_doc_id} in chunk #{chunk_id} contains #{local_sentence_id} sentences; truncating to #{$MAX_SENTENCES_PER_DOCUMENT} "
  end
  note_doc_sentence_count(local_doc_id, local_sentence_id)
  note_doc_word_count(local_doc_id, doc_word_count)
  return local_sentence_index, local_doc_index, local_doc_id
end

# saves sentence and word indexes in passing
def tokenize_jsonl_chunk(file)
  line_num = 0
  chunk_id = file[/.*\.(.+)-of-.*/,1].to_i # implicitly relies on $WET_INPUT_FILE_TEMPLATE
  total_lines = `wc -l < "#{file}"`.strip.to_i
  puts "Tokenizing chunk #{chunk_id} (#{total_lines} docs)"
  compute_and_save_metadata(chunk_id, file)
  start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  File.foreach(file, chomp: true, encoding: 'UTF-8') do |line|
    next if line.empty?
    local_sentence_index, local_doc_index, local_doc_id = tokenize_json_doc(JSON.parse!(line), chunk_id)
    save_local_sentence_index(local_sentence_index, chunk_id, local_doc_id)
    save_local_doc_index(local_doc_index, chunk_id, local_doc_id)
    line_num += 1
    if line_num % 10000 == 0
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
      rate = (line_num / elapsed).round
      pct = total_lines > 0 ? (100.0 * line_num / total_lines).round(1) : '?'
      eta_s = rate > 0 ? ((total_lines - line_num) / rate).round : '?'
      print "\r  #{line_num}/#{total_lines} docs (#{pct}%) | ETA #{eta_s}s   "
    end
  end
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
  puts "\r  #{line_num}/#{total_lines} docs in #{elapsed.round(1)}s (#{(line_num / elapsed).round} docs/s)        "
  save_chunk_sentence_count(chunk_id)
  save_chunk_word_count(chunk_id)
  puts "Chunk #{chunk_id} done!"
  return chunk_id
end

def tokenize_wet_chunk(input_jsonl_file)
  if input_jsonl_file.nil?
    raise "Must specify file to tokenize."
  end
  chunk_id = tokenize_jsonl_chunk(input_jsonl_file)
  save_urls(chunk_id)
  save_doc_sentence_counts(chunk_id)
  save_sentence_word_counts(chunk_id)
  save_doc_word_counts(chunk_id)
end

tokenize_wet_chunk(ARGV[0])
