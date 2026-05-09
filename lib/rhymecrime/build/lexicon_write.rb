# frozen_string_literal: true

# Dictionary artifact writers and corpus-cache orchestration for dict-build / setup-corpora.
# Loaded after ../utils and corpus_caches via build_utils (not part of the Lambda runtime graph).
require "fileutils"
require "json"
require "msgpack"
require_relative "../paths"

# Cue → {target => fsg} map built from the USF Cue_Target_Pairs.* shards. Used
# by rarity_signals (build-time) and relatedness/signals (runtime). Mirrors
# bin/build-usf-associations — lives here next to ensure_usf_associations_cache!.
USF_LEMMA_RE = /\A[a-z][a-z0-9'-]*\z/.freeze

def save_string_hash(hash, filename, header="")
  # sanitizes spaces into underscores
  FileUtils.mkdir_p(File.dirname(filename))
  IoUtils.open(filename, "w", encoding: "UTF-8", hint: "save_string_hash") do |fh|
    fh.puts(header) unless header.empty?
    hash.each do |key, values|
      key = key.sanitize
      fh.print "#{key} "
      for value in values do
        value = value.sanitize
        fh.print " #{value}"
      end
      fh.puts
    end
  end
end

def build_usf_associations!(out_path = nil)
  out_path ||= generated_root_path(USF_ASSOCIATIONS_FILENAME)
  shards = usf_corpus_shards
  raise "no Cue_Target_Pairs.* shards under #{File.join(REPO_ROOT, 'corpora', 'usf')}" if shards.empty?

  graph = Hash.new { |h, k| h[k] = {} }
  pair_count = 0
  shards.each do |path|
    IoUtils.foreach(path, encoding: "UTF-8", hint: "build_usf_associations") do |line|
      line = line.scrub
      next if line.include?("CUE,")
      next unless line.match?(/\A[A-Z]/)

      parts = line.split(",")
      next if parts.length < 6

      cue = parts[0].strip.downcase
      target = parts[1].strip.downcase
      fsg = parts[5].to_s.strip
      next unless cue.match?(USF_LEMMA_RE) && target.match?(USF_LEMMA_RE)
      next if fsg.empty?

      f = fsg.to_f
      next unless f.positive?

      graph[cue][target] = f
      pair_count += 1
    end
  end
  FileUtils.mkdir_p(File.dirname(out_path))
  IoUtils.write(out_path, JSON.generate(graph), hint: "build_usf_associations")
  puts "wrote #{graph.size} cues / #{pair_count} pairs to #{out_path}"
  graph
end

def usf_associations_cache_rebuild_reason
  shards = usf_corpus_shards
  return nil if shards.empty?

  out_path = generated_root_path(USF_ASSOCIATIONS_FILENAME)
  return "missing #{out_path}" unless File.exist?(out_path)

  newest_shard_mtime = shards.map { |p| File.mtime(p) }.max
  return "stale (USF shard newer than cache)" if File.mtime(out_path) < newest_shard_mtime

  nil
end

def ensure_usf_associations_cache!
  reason = usf_associations_cache_rebuild_reason
  return unless reason

  out_path = generated_root_path(USF_ASSOCIATIONS_FILENAME)
  if reason.start_with?("missing ")
    puts "USF associations cache build: #{out_path}"
  else
    puts "USF associations cache rebuild: #{reason}"
  end
  build_usf_associations!
end

def numberbatch_vectors_cache_rebuild_reason
  out_path = generated_root_path(NUMBERBATCH_VECTORS_FILENAME)
  return "missing #{out_path}" unless File.exist?(out_path)

  txt_path = numberbatch_txt_path
  if txt_path && File.mtime(out_path) < File.mtime(txt_path)
    return "stale (corpus newer than cache)"
  end

  begin
    IoUtils.stream_read(out_path, hint: "numberbatch_vectors header_check") do |io|
      header = MessagePack::Unpacker.new(io).read
      return nil if header.is_a?(Hash) && header["format"] == NUMBERBATCH_STREAM_FORMAT

      return "old format (header=#{header.inspect}); current format=#{NUMBERBATCH_STREAM_FORMAT.inspect}"
    end
  rescue StandardError => e
    return "unreadable header: #{e.class}: #{e.message}"
  end
end

def ensure_numberbatch_vectors_cache!
  reason = numberbatch_vectors_cache_rebuild_reason
  return unless reason

  out_path = generated_root_path(NUMBERBATCH_VECTORS_FILENAME)
  if reason.start_with?("missing ")
    puts "Numberbatch vectors cache build: #{out_path}"
  else
    puts "Numberbatch vectors cache rebuild: #{reason}"
  end
  save_numberbatch_vectors!
end

def require_numberbatch_vectors_cache!
  out_path = generated_root_path(NUMBERBATCH_VECTORS_FILENAME)
  reason = if File.exist?(out_path)
             numberbatch_vectors_cache_rebuild_reason
           else
             "missing #{out_path}"
           end
  return unless reason

  raise "Numberbatch vectors cache is not ready: #{reason}. Run ./bin/setup-corpora " \
        "to create #{NUMBERBATCH_VECTORS_FILENAME}; bin/build intentionally does not " \
        "rebuild corpus mirrors."
end

def save_word_semantic_base_map!(word_dict, semantic_base_map, transform_for: nil)
  ensure_generated_dict_dir!
  msgpack_path = generated_dict_path_under_dict_dir(WORD_SEMANTIC_BASE_MAP_FILENAME)
  txt_path = generated_dict_path_under_dict_dir(WORD_SEMANTIC_BASE_MAP_TXT_FILENAME)

  obj = {}
  semantic_base_map.each do |w, target|
    next unless target && target != w
    next unless word_dict.key?(w) && word_dict.key?(target)
    obj[w] = target
  end
  MessagePackUtils.pack_and_save(msgpack_path, obj)
  puts "Wrote #{obj.size} word→semantic_base entries to #{msgpack_path} (#{File.size(msgpack_path)} bytes)"

  IoUtils.open(txt_path, "w", encoding: "UTF-8", hint: "save_word_semantic_base_map txt") do |f|
    f.puts "# word\tsemantic_base\ttransform"
    obj.keys.sort.each do |w|
      transform = transform_for ? transform_for[w] : ""
      f.puts "#{w}\t#{obj[w]}\t#{transform}"
    end
  end
  puts "Wrote sorted dump to #{txt_path}"
end

def save_word_dict(word_dict, lemma_map = nil)
  ensure_generated_dict_dir!
  path = generated_dict_path_under_dict_dir(WORD_DICT_FILENAME)
  f = IoUtils.open(path, "w", encoding: "UTF-8", hint: "save_word_dict")
  f.puts(WORD_DICT_HEADER)
  for word, word_info in word_dict
    sanitized = word.sanitize
    f.print(sanitized)
    f.print(',')
    frequency, prons = word_info
    f.print(frequency)
    f.print(',')
    isFirstPron = true
    for pron in prons
      unless isFirstPron
        f.print('|')
      end
      isFirstPron = false
      f.print(pron)
    end
    lemma = lemma_map ? lemma_map[word] : word_info[2]
    bases = word_info[3]
    has_bases = bases.is_a?(Array) && !bases.empty?
    lemma_neq = lemma_map && lemma && lemma != word
    if lemma_neq
      f.print(',')
      f.print(lemma.sanitize)
    elsif has_bases
      # Empty lemma column when lemma is omitted but PREFIX_ALLOWS follows (split(",", 5)).
      f.print(',')
    end
    if has_bases
      f.print(',')
      f.print(bases.map(&:sanitize).join('|'))
    end
    f.puts
  end
  f.close
end

def save_word_dict_msgpack!(word_dict, lemma_map = nil)
  ensure_generated_dict_dir!
  path = generated_dict_path_under_dict_dir(WORD_DICT_MSGPACK_FILENAME)
  obj = {}
  word_dict.each do |word, info|
    freq, prons = info
    lem = lemma_map ? lemma_map[word] : (info[2] || word)
    pron_strs = (prons || []).map(&:to_s)
    stored_lemma = (lem && lem != word) ? lem : nil
    row = [freq.to_i, pron_strs, stored_lemma]
    bases = info[3]
    row << bases if bases.is_a?(Array) && !bases.empty?
    obj[word] = row
  end
  MessagePackUtils.pack_and_save(path, obj)
  size_mb = (File.size(path).to_f / 1024 / 1024).round(2)
  puts "Wrote #{obj.size} word_dict entries to #{WORD_DICT_MSGPACK_FILENAME} (#{size_mb} MB)"
end

def save_rime_dict_msgpack!(rime_dict)
  ensure_generated_dict_dir!
  path = generated_dict_path_under_dict_dir(RIME_DICT_MSGPACK_FILENAME)
  obj = {}
  rime_dict.each do |rime, words|
    obj[rime.to_s] = (words || []).map(&:to_s)
  end
  MessagePackUtils.pack_and_save(path, obj)
  size_mb = (File.size(path).to_f / 1024 / 1024).round(2)
  puts "Wrote #{obj.size} rime_dict buckets to #{RIME_DICT_MSGPACK_FILENAME} (#{size_mb} MB)"
end

def save_wiktionary_glosses!(glosses_map)
  ensure_generated_dict_dir!
  path = generated_dict_path_under_dict_dir(WIKTIONARY_GLOSSES_FILENAME)
  obj = {}
  glosses_map.each do |word, glosses|
    next if word.nil? || word.empty?
    next if glosses.nil? || glosses.empty?
    obj[word] = glosses
  end
  MessagePackUtils.pack_and_save(path, obj)
  size_mb = (File.size(path).to_f / 1024 / 1024).round(2)
  total_glosses = obj.each_value.sum(&:size)
  puts "Wrote #{obj.size} headwords (#{total_glosses} glosses) to #{WIKTIONARY_GLOSSES_FILENAME} (#{size_mb} MB)"
end

def save_word_lemma_map!(word_dict, lemma_map)
  ensure_generated_dict_dir!
  path = generated_dict_path_under_dict_dir(WORD_LEMMA_MAP_FILENAME)
  obj = {}
  word_dict.each_key do |word|
    lem = lemma_map ? lemma_map[word] : word_dict[word][2]
    obj[word] = lem if lem && lem != word
  end
  MessagePackUtils.pack_and_save(path, obj)
  puts "Wrote #{obj.size} word→lemma entries to #{path} (#{File.size(path)} bytes)"
end

def save_part_of_speech_map(pos_map)
  ensure_generated_dict_dir!
  path = generated_dict_path_under_dict_dir(PART_OF_SPEECH_FILENAME)
  obj = pos_map.keys.sort.to_h { |w| [w, pos_map[w].to_a.sort] }
  IoUtils.write(path, JSON.generate(obj), encoding: "UTF-8", hint: "save_part_of_speech_map")
end
