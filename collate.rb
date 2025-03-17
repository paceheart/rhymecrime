#!/usr/bin/env ruby

# collator: for each word, sum all counts, append all doc_id
#   then we have tables:
#     word, count
#     word, doc_ids (for a back-index)

# NOTE: this is not scalable - it'll have to be rearchitected to work on EMR or something

require_relative 'json_extensions'
require_relative 'pace_utils'
require_relative 'WetCorpus'

$global_word_counts = Hash.new(0)
$global_sentence_index = Hash.new_hash_of_arrays
$global_doc_index = Hash.new_hash_of_arrays

def note_word_mentioned_in_sentence(word, doc_id, local_sentence_id)
  sentence_id = compute_sentence_id(doc_id, local_sentence_id)
  $global_sentence_index.push(word, sentence_id)
end

def note_word_mentioned_in_doc(word, doc_id)
  $global_doc_index.push(word, doc_id)
end

def collate_sentence_word_counts(json_filename, chunk_id)
  sentence_word_counts = JSON.parse!(IO.read(json_filename)) # hash[word] -> local_sentence_ids
  local_doc_id = json_filename[-11..-6].to_i
  doc_id = compute_doc_id(chunk_id, local_doc_id)
  for word, local_sentence_ids in sentence_word_counts
    for local_sentence_id in local_sentence_ids
      note_word_mentioned_in_sentence(word, doc_id, local_sentence_id)
    end
  end
end

def collate_word_counts(json_filename, chunk_id)
  word_counts = JSON.parse!(IO.read(json_filename))
  $global_word_counts.hash_increment_all(word_counts)
  local_doc_id = json_filename[-11..-6].to_i
  doc_id = compute_doc_id(chunk_id, local_doc_id)
  for word, count in word_counts
    # ignore count
    note_word_mentioned_in_doc(word, doc_id)
  end
end

def save_global_word_counts
  JSON.save($WET_GLOBAL_WORD_COUNTS_FILENAME, $global_word_counts)
end

def save_global_sentence_index
  JSON.save($WET_GLOBAL_SENTENCE_INDEX_FILENAME, $global_sentence_index.sort_values)
end

def save_global_doc_index
  JSON.save($WET_GLOBAL_DOC_INDEX_FILENAME, $global_doc_index.sort_values)
end

def collate_everything
  Dir.foreach('index') do |chunk_dir|
    if chunk_dir.include?('chunk')
      print "Collating #{chunk_dir}"
      chunk_id = chunk_dir[6..].to_i
      chunk_path = 'index/' + chunk_dir
      Dir.foreach(chunk_path) do |filename|
        if filename.include?($WET_LOCAL_SENTENCE_INDEX_UNIQUIFIER)
          collate_sentence_word_counts(chunk_path + "/" + filename, chunk_id)
        elsif filename.include?($WET_LOCAL_DOC_INDEX_UNIQUIFIER)
          collate_word_counts(chunk_path + "/" + filename, chunk_id)
        end
        if filename.include?('1000.')
          print "."
        end
      end
      puts "complete!"
    end
  end
  save_global_sentence_index
  save_global_word_counts
  save_global_doc_index
end

collate_everything
