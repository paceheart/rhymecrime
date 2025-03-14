#!/usr/bin/env ruby

# creates:
#   @url: # array DOC_ID -> the URL for that document, just for efficiency to avoid passing long strings around
#   @doc_sentence_counts: array DOC_ID -> the total number of sentences in the document
#   @doc_word_counts: array DOC_ID -> the total number of relevant words in the document
#   for each DOC_ID, a file containing a hash WORD -> COUNT # the number of times WORD appears in that document
#   @sentence_word_counts: array DOC_ID, LOCAL_SENTENCE_ID -> the total number of relevant words in that sentence

require_relative 'WetCorpus'
require_relative 'json_extensions'
require_relative 'fileutils_extensions'
require_relative 'pace_utils'
require_relative 'dict/utils_rhyme'

def tokenizer_allowed_word?(word)
  !stop_word?(word) and !explicitly_forbidden?(word) and words_we_care_about.include?(word)
end

# We assume the data has already been deduped
$urls = Array.new
def note_url_local_doc_id(url)
  $urls.push(url)
  return $urls.length-1
end

$sentence_word_counts = ArrayOfIntegerArrays.new
def note_sentence_word_count(doc_id, local_sentence_id, word_count)
  $sentence_word_counts[doc_id][local_sentence_id] = word_count
end

$doc_sentence_counts = []
def note_doc_sentence_count(doc_id, sentence_count)
  chunk_id, local_doc_id = split_doc_id(doc_id)
  $doc_sentence_counts[local_doc_id] = sentence_count
end

$doc_word_counts = []
def note_doc_word_count(doc_id, word_count)
  chunk_id, local_doc_id = split_doc_id(doc_id)
  $doc_word_counts[local_doc_id] = word_count
end

# saves sentence word count dicts and word count dicts in passing
def tokenize_jsonl_chunk(file)
  line_num = 0
  chunk_id = file[/.*\.(.+)-of-.*/,1].to_i # implicitly relies on $WET_INPUT_FILE_TEMPLATE
  print "Tokenizing chunk #{chunk_id}"
  for line in IO.readlines(file)
    sentence_word_count_dict, word_count_dict, doc_id = tokenize_json_doc(JSON.parse!(line), chunk_id)
    save_sentence_word_count_dict(sentence_word_count_dict, doc_id)
    save_word_count_dict(word_count_dict, doc_id)
    line_num += 1
    if line_num % 1000 == 0
      print "."
    end
  end
  puts "done!"
  return chunk_id
end

def tokenize_json_doc(json, chunk_id)
  text = json["text"]
  url = json["url"]
  local_doc_id = note_url_local_doc_id(url)
  doc_id = compute_doc_id(chunk_id, local_doc_id)
  doc_word_count = 0
  sentence_word_count_dict = Hash.new_hash_of_integer_arrays
  word_count_dict = Hash.new(0)
  local_sentence_id = 0
  for sentence in tokenize_by_sentence(text)
    if local_sentence_id < $MAX_SENTENCES_PER_DOCUMENT
      sentence_word_count = 0
      for word in sentence.split
        word = word.downcase
        if tokenizer_allowed_word?(word)
          sentence_word_count_dict.push(word, local_sentence_id)
          word_count_dict[word] += 1
          doc_word_count += 1
          sentence_word_count += 1
        end
      end
      note_sentence_word_count(doc_id, local_sentence_id, sentence_word_count)
    end
    local_sentence_id += 1
  end
  if local_sentence_id > $MAX_SENTENCES_PER_DOCUMENT
    print "Document #{doc_id} contains #{local_sentence_id} sentences; truncating to #{$MAX_SENTENCES_PER_DOCUMENT} "
  end
  note_doc_sentence_count(doc_id, local_sentence_id)
  note_doc_word_count(doc_id, doc_word_count)
  return sentence_word_count_dict, word_count_dict, doc_id
end

def save_chunk_specific_file(filename_uniquifier, object, chunk_id)
  unless object.empty?
    filename = construct_chunk_specific_filename(chunk_id, filename_uniquifier)
    FileUtils.ensure_file_directory_exists(filename)
    JSON.save(filename, object)
  end
end

def save_document_specific_file(filename_uniquifier, object, doc_id)
  unless object.empty?
    filename = construct_document_specific_filename(doc_id, filename_uniquifier)
    FileUtils.ensure_file_directory_exists(filename)
    JSON.save(filename, object)
  end
end

def save_sentence_word_count_dict(sentence_word_count_dict, doc_id)
  save_document_specific_file($WET_SENTENCE_COUNTS_UNIQUIFIER, sentence_word_count_dict, doc_id) # see $WET_SENTENCE_INDEX_FILE_TEMPLATE
end

def save_word_count_dict(word_count_dict, doc_id)
  save_document_specific_file($WET_WORD_COUNTS_UNIQUIFIER, word_count_dict, doc_id) # see $WET_WORD_INDEX_FILE_TEMPLATE
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

def compute_word_counts(input_jsonl_file)
  if input_jsonl_file.nil?
    raise "Must specify file to tokenize."
  end
  if $limit_to_test_words
    puts "Limiting tokenization to only the #{all_test_words.length} words that appear in the tests"
  end
  chunk_id = tokenize_jsonl_chunk(input_jsonl_file)
  save_urls(chunk_id)
  save_doc_sentence_counts(chunk_id)
  save_sentence_word_counts(chunk_id)
  save_doc_word_counts(chunk_id)
end

compute_word_counts(ARGV[0])
