#!/usr/bin/env ruby

# collator: for each word, sum all counts, append all doc_id
#   then we have tables:
#     word, count
#     word, doc_ids (for a back-index)

# NOTE: this is not scalable - it'll have to be rearchitected to work on EMR or something

require_relative 'json_extensions'
require_relative 'pace_utils'
require_relative 'WetCorpus'
require 'msgpack'

$global_word_counts = Hash.new(0)
$global_sentence_index = Hash.new_hash_of_arrays
$global_doc_index = Hash.new_hash_of_arrays

def note_word_mentioned_in_sentence(word, chunk_id, local_doc_id, local_sentence_id)
  sentence_id = compute_sentence_id(chunk_id, local_doc_id, local_sentence_id)
  $global_sentence_index.push(word, sentence_id)
end

def note_word_mentioned_in_doc(word, chunk_id, local_doc_id)
  doc_id = compute_doc_id(chunk_id, local_doc_id)
  $global_doc_index.push(word, doc_id)
end

def collate_sentence_index(json_filename, chunk_id)
  sentence_index = JSON.parse!(IO.read(json_filename, encoding: 'UTF-8')) # hash[word] -> local_sentence_ids
  local_doc_id = json_filename[-11..-6].to_i
  doc_id = compute_doc_id(chunk_id, local_doc_id)
  for word, local_sentence_ids in sentence_index
    for local_sentence_id in local_sentence_ids
      note_word_mentioned_in_sentence(word, chunk_id, local_doc_id, local_sentence_id)
    end
  end
end

def collate_doc_index(json_filename, chunk_id)
  word_counts = JSON.parse!(IO.read(json_filename, encoding: 'UTF-8')) # hash[WORD] -> # of occurrences of WORD in that document
  $global_word_counts.hash_increment_all(word_counts)
  local_doc_id = json_filename[-11..-6].to_i
  for word, count in word_counts
    # ignore count
    note_word_mentioned_in_doc(word, chunk_id, local_doc_id)
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

def collate_chunk_dir(chunk_dir)
  chunk_id = chunk_dir[6..].to_i
  chunk_path = 'index/' + chunk_dir
  files = Dir.children(chunk_path)
  total = files.size
  puts "Collating #{chunk_dir} (#{total} files)"
  start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  files.each_with_index do |filename, i|
    if filename.include?($WET_LOCAL_SENTENCE_INDEX_UNIQUIFIER)
      collate_sentence_index(chunk_path + "/" + filename, chunk_id)
    elsif filename.include?($WET_LOCAL_DOC_INDEX_UNIQUIFIER)
      collate_doc_index(chunk_path + "/" + filename, chunk_id)
    end
    if (i + 1) % 10000 == 0
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
      rate = ((i + 1) / elapsed).round
      pct = (100.0 * (i + 1) / total).round(1)
      eta_s = rate > 0 ? ((total - i - 1) / rate).round : '?'
      print "\r  #{i + 1}/#{total} files (#{pct}%) | ETA #{eta_s}s   "
    end
  end
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
  puts "\r  #{total}/#{total} files in #{elapsed.round(1)}s                              "
end

def collate_everything
  chunk_dirs = Dir.children('index').select { |d| d.include?('chunk') }.sort
  puts "Collating #{chunk_dirs.size} chunk(s)..."
  chunk_dirs.each { |chunk_dir| collate_chunk_dir(chunk_dir) }
  print "Saving global sentence index... "; save_global_sentence_index; puts "done"
  print "Saving global word counts... "; save_global_word_counts; puts "done"
  print "Saving global doc index... "; save_global_doc_index; puts "done"
end

# Next, add up the total number of sentences and documents in the entire corpus,
# then save those totals.

def save_total_sentence_count(count)
  puts "Total sentence count: #{count}"
  JSON.save($WET_TOTAL_SENTENCE_COUNT_FILENAME, count)
end

def save_total_doc_count(count)
  puts "Total document count: #{count}"
  JSON.save($WET_TOTAL_DOC_COUNT_FILENAME, count)
end

def total_everything
  total_doc_count, total_sentence_count = sum_chunk_specific_files('.', $WET_DOC_SENTENCE_COUNTS_UNIQUIFIER)
  save_total_sentence_count(total_sentence_count)
  save_total_doc_count(total_doc_count)
end

# Next, append all the chunk-specific indexes into a global index

def append_and_save_chunk_specific_doc_file(dir, uniquifier, global_filename)
  MessagePackUtils.pack_and_save(global_filename, load_chunk_specific_doc_files(dir, uniquifier))
end

def append_everything(dir)
  append_and_save_chunk_specific_doc_file(dir, $WET_SENTENCE_WORD_COUNTS_UNIQUIFIER, $WET_GLOBAL_SENTENCE_WORD_COUNTS_FILENAME)
  append_and_save_chunk_specific_doc_file(dir, $WET_DOC_SENTENCE_COUNTS_UNIQUIFIER, $WET_GLOBAL_DOC_SENTENCE_COUNTS_FILENAME)
  append_and_save_chunk_specific_doc_file(dir, $WET_DOC_WORD_COUNTS_UNIQUIFIER, $WET_GLOBAL_DOC_WORD_COUNTS_FILENAME)
  append_and_save_chunk_specific_doc_file(dir, $WET_URLS_UNIQUIFIER, $WET_GLOBAL_URLS_FILENAME)
end

# Next, convert JSON to msgpack for speed

# tbp
def json2msgpack(file)
  File.binwrite(file.gsub(".json", ".msgpack"), JSON.load!(file).to_msgpack)
end

def msgpack_everything
  print "Converting to msgpack: sentence index... "
  json2msgpack($WET_GLOBAL_SENTENCE_INDEX_FILENAME); print "doc index... "
  json2msgpack($WET_GLOBAL_DOC_INDEX_FILENAME); print "word counts... "
  json2msgpack($WET_GLOBAL_WORD_COUNTS_FILENAME); puts "done"
end

# Now do it!
overall_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
collate_everything
print "Totaling... "; total_everything
print "Appending... "; append_everything("."); puts "done"
msgpack_everything
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - overall_start
puts "All done in #{elapsed.round(1)}s"
