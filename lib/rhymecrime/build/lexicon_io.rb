# frozen_string_literal: true

#
# file utilities
#

def load_string_hash(filename)
  # each line is of the form:
  # KEY  STRING1 STRING2 ...
  # substitutes "_" with " " in keys after loading
  hash = Hash.new # hash of strings
  BuildIoUtils.foreach(filename, encoding: "UTF-8", hint: "load_string_hash") do |line|
    if useful_line?(line)
      tokens = line.split
      key = tokens.shift # now TOKENS contains only the value strings
      key = key.sanitize
      hash[key] = tokens.map { |str| str.desanitize }
    else
      dict_utils_debug "Ignoring #{filename} line: #{line}"
    end
  end
  dict_utils_debug "Loaded #{hash.length} entries from #{filename}"
  hash
end
def save_string_hash(hash, filename, header="")
  # sanitizes spaces into underscores
  FileUtils.mkdir_p(File.dirname(filename))
  BuildIoUtils.open(filename, "w", encoding: "UTF-8", hint: "save_string_hash") do |fh|
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

def useful_line?(line)
  # ignore entries that start with ; or #
  return !(line =~ /\A;/ || line =~ /\A#/)
end

#
# pronunciation lists (dict build + load)
#

# Appends PRON to PRONS unless an equal Pronunciation is already present.
def push_pronunciation_unless_duplicate!(prons, pron)
  return if prons.any? { |existing| existing == pron }
  prons.push(pron)
end

# Returns a new array with duplicate pronunciations removed (first occurrence kept).
def dedupe_pronunciations(prons)
  result = []
  prons.each { |p| push_pronunciation_unless_duplicate!(result, p) }
  result
end

#
# word info dictionary
#

def load_word_dict()
  pathname = generated_dict_path_under_dict_dir(WORD_DICT_FILENAME)
  unless File.exist?(pathname)
    raise "First run ./bin/dict-build to populate #{GENERATED_DIR}/"
  end
  word_dict = Hash.new
  BuildIoUtils.foreach(pathname, encoding: "UTF-8", hint: "load_word_dict") do |line|
    next unless useful_line?(line)

    parts = line.chomp.split(",", 4)
    word = parts[0].desanitize
    freq = parts[1].to_i
    pronunciations_str = parts[2] || ""
    lemma_raw = parts[3]
    prons = Array.new
    pronunciation_strings = pronunciations_str.split("|")
    for pronstr in pronunciation_strings
      phonemes = pronstr.split(" ")
      pron = Pronunciation.new(phonemes)
      push_pronunciation_unless_duplicate!(prons, pron)
    end
    lemma = (lemma_raw && !lemma_raw.strip.empty?) ? lemma_raw.strip.desanitize : word
    word_info = [freq, prons, lemma]
    word_dict[word] = word_info
  end
  clear_spelling_variant_hyphen_caches!
  $lemma_to_words = nil
  $word_to_lemma = nil
  $word_to_semantic_base = nil
  $wiktionary_glosses = nil
  $thematically_related_memo = nil
  word_dict
end

# Overridden in crime.rb after load (same shape; crime uses lazy word_dict()).
# Dict-build never loads crime.rb — use $word_dict when the word_dict helper
# is not defined (see preferred_form_frequency_lookup).
def lexicon_word_entry(word)
  wd = defined?(word_dict) ? word_dict : $word_dict
  return nil if wd.nil?
  wd[word]
end

# Flat {word => lemma} lookup loaded from WORD_LEMMA_MAP_FILENAME (built by
# dict-build). Only stores word != lemma pairs to keep the file small
# (~40% of headwords have a non-self lemma); every missing key means "lemma
# is the word itself", matching the nil-collapse rule in save_word_dict and
# lexicon_word_entry.
#
# Outside dict-build, missing on disk is fatal (raises) — that used to silently
# degrade relatedness/rarity to a self-lemma-everywhere regime. Inside dict-build
# (RHYMECRIME_BUILD_MODE set by bin/dict-build / bin/build), the file legitimately
# may not exist yet — load_cmudict → semantically_promiscuous? → lemma() runs
# before save_word_lemma_map! at the bottom of rebuild_rhymecrime_dictionaries.
# In that window, an empty hash gives identity lemma() which is fine for
# dict-build's own bootstrap consumers.
#
# Must stay a top-level global (not a module constant) so load_word_dict
# can reset it as part of its invalidation handshake.
$word_to_lemma = nil
def load_word_to_lemma!
  path = generated_dict_path_under_dict_dir(WORD_LEMMA_MAP_FILENAME)
  if File.exist?(path)
    $word_to_lemma = MessagePackUtils.load_and_unpack(path)
    return
  end
  if ENV["RHYMECRIME_BUILD_MODE"].to_s.empty?
    raise "word→lemma map not found at #{path}. Run ./bin/dict-build (or ./bin/build) " \
          "to generate it."
  end
  $word_to_lemma = {}
end

# Hot-path inner loop for RelatedWords pair lookups (called thousands of
# times per page render while coloring set_related tuples). The $word_to_
# lemma global is checked inline rather than via a helper method so the
# common warm-path case is one Hash lookup plus one nil check, not two method
# dispatches. Missing-key collapse to `word` matches the in-memory representation
# (only word != lemma pairs are stored). load_word_to_lemma! raises on missing
# disk file unless we're inside dict-build (pre-save bootstrap window).
def lemma(word)
  load_word_to_lemma! if $word_to_lemma.nil?
  $word_to_lemma[word] || word
end

# Lazy $word_to_semantic_base load mirroring load_word_to_lemma!. Map keys
# are self-lemmas (lookup composes lemma(w) first), values are derivational
# roots. Outside dict-build, missing on disk is fatal — was silently degrading
# relatedness to inflectional-lemma-only previously. Inside dict-build, allow
# empty so semantic_base() falls back to lemma() (identity in the same window).
$word_to_semantic_base = nil
def load_word_to_semantic_base!
  path = generated_dict_path_under_dict_dir(WORD_SEMANTIC_BASE_MAP_FILENAME)
  if File.exist?(path)
    $word_to_semantic_base = MessagePackUtils.load_and_unpack(path)
    return
  end
  if ENV["RHYMECRIME_BUILD_MODE"].to_s.empty?
    raise "semantic-base map not found at #{path}. Run ./bin/dict-build (or ./bin/build) " \
          "to generate it."
  end
  $word_to_semantic_base = {}
end

# Hot path for relatedness lookups (R3). Returns the derivational root when
# WordNet pointed to one and the suffix-allowlist gates passed during
# compute_semantic_base_map; otherwise falls back to the inflectional
# lemma(w). Composes the two normalization layers in one call so callers
# don't have to memorize the order. Layered with RELATED_SKIP_LEMMA=1 at
# the call sites — that knob skips this entirely (passes the raw surface).
def semantic_base(word)
  base = lemma(word)
  map = $word_to_semantic_base
  load_word_to_semantic_base! if map.nil?
  map = $word_to_semantic_base
  m = map[base]
  m || base
end

# Stream loader for the Numberbatch cosine guard in compute_semantic_base_map.
# Returns Hash<String, Numo::SFloat> keyed on hyphens-to-underscores word.
# The cache file is corpus-derived (every Numberbatch token has a row), so we
# filter by keep_words at load time so the guard only materializes vectors
# for words actually in the build's word_dict. semantic_base_nb_cosine
# accepts both Array<Float> and Numo::SFloat values (it dispatches on
# `respond_to?(:dot)`); Numo is preferred — a single BLAS dot is faster
# than the per-word fallback loop.
#
# Raises if the cache is missing — setup-corpora creates the corpus mirror
# before bin/build / dict-build consume it.
def load_numberbatch_vectors_for_semantic_base_guard(keep_words = nil)
  path = generated_root_path(NUMBERBATCH_VECTORS_FILENAME)
  unless File.exist?(path)
    raise "Numberbatch vectors not found at #{path} for semantic-base guard. " \
          "Run ./bin/setup-corpora to create #{NUMBERBATCH_VECTORS_FILENAME} " \
          "from corpora/numberbatch/numberbatch-en-19.08.txt."
  end

  keep = keep_words && keep_words.each_with_object(Set.new) { |w, s| s.add(hyphens_to_underscores(w)) }
  load_numberbatch_vectors_streaming(path, keep_underscored: keep)
end

# Locate sorted USF Cue_Target_Pairs.* shards under corpora/usf/. Returns []
# when corpora/usf isn't on disk (USF data is optional but build-usf-associations
# fails loudly if invoked anyway).
def usf_corpus_shards
  Dir.glob(File.join(REPO_ROOT, "corpora", "usf", "Cue_Target_Pairs.*")).sort
end

# Cue → {target => fsg} map built from the USF Cue_Target_Pairs.* shards. Used
# by rarity_signals (build-time) and relatedness/signals (runtime). Mirrors the
# bin/build-usf-associations script — kept inside utils_rhyme so
# ensure_usf_associations_cache! can rebuild without spawning a subprocess.
USF_LEMMA_RE = /\A[a-z][a-z0-9'-]*\z/.freeze

def build_usf_associations!(out_path = nil)
  out_path ||= generated_root_path(USF_ASSOCIATIONS_FILENAME)
  shards = usf_corpus_shards
  raise "no Cue_Target_Pairs.* shards under #{File.join(REPO_ROOT, 'corpora', 'usf')}" if shards.empty?

  graph = Hash.new { |h, k| h[k] = {} }
  pair_count = 0
  shards.each do |path|
    BuildIoUtils.foreach(path, encoding: "UTF-8", hint: "build_usf_associations") do |line|
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
  BuildIoUtils.write(out_path, JSON.generate(graph), hint: "build_usf_associations")
  puts "wrote #{graph.size} cues / #{pair_count} pairs to #{out_path}"
  graph
end

# Decide whether the USF associations cache needs (re)building. Returns a
# reason string, or nil if the cache is fresh.
def usf_associations_cache_rebuild_reason
  shards = usf_corpus_shards
  return nil if shards.empty? # no source data; let downstream raise its own clear error

  out_path = generated_root_path(USF_ASSOCIATIONS_FILENAME)
  return "missing #{out_path}" unless File.exist?(out_path)

  newest_shard_mtime = shards.map { |p| File.mtime(p) }.max
  return "stale (USF shard newer than cache)" if File.mtime(out_path) < newest_shard_mtime

  nil
end

# Idempotent precondition: rebuild generated/usf_associations.json from the
# corpora/usf/* shards when missing or stale. Cheap mtime check in steady
# state. Called from rebuild_rhymecrime_dictionaries so a single
# ./bin/dict-build self-heals after `rm -rf generated/`.
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

# Decide whether the Numberbatch cache needs (re)building. Returns a string
# describing the reason, or nil if the cache is fresh and in the current
# streaming format.
def numberbatch_vectors_cache_rebuild_reason
  out_path = generated_root_path(NUMBERBATCH_VECTORS_FILENAME)
  return "missing #{out_path}" unless File.exist?(out_path)

  txt_path = numberbatch_txt_path
  if txt_path && File.mtime(out_path) < File.mtime(txt_path)
    return "stale (corpus newer than cache)"
  end

  begin
    BuildIoUtils.stream_read(out_path, hint: "numberbatch_vectors header_check") do |io|
      header = MessagePack::Unpacker.new(io).read
      return nil if header.is_a?(Hash) && header["format"] == NUMBERBATCH_STREAM_FORMAT

      return "old format (header=#{header.inspect}); current format=#{NUMBERBATCH_STREAM_FORMAT.inspect}"
    end
  rescue StandardError => e
    return "unreadable header: #{e.class}: #{e.message}"
  end
end

# Idempotent setup-time precondition for any code path that loads
# numberbatch_vectors: rebuild from corpora/numberbatch/*.txt only when the
# cache is missing, stale (corpus mtime > cache mtime), or in an older on-disk
# format. Cheap mtime + header probe in the steady state. Called from
# bin/setup-corpora, not dict-build.
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

  BuildIoUtils.open(txt_path, "w", encoding: "UTF-8", hint: "save_word_semantic_base_map txt") do |f|
    f.puts "# word\tsemantic_base\ttransform"
    obj.keys.sort.each do |w|
      transform = transform_for ? transform_for[w] : ""
      f.puts "#{w}\t#{obj[w]}\t#{transform}"
    end
  end
  puts "Wrote sorted dump to #{txt_path}"
end

# Reverse map: lemma → array of all word_dict headwords that share that lemma (including the lemma
# itself when it is in word_dict). Built lazily on first access; cleared when word_dict is reloaded.
$lemma_to_words = nil
def lemma_to_words
  return $lemma_to_words unless $lemma_to_words.nil?
  # Force word_dict to load before we allocate $lemma_to_words; load_word_dict nils out
  # $lemma_to_words as part of its invalidation handshake, so allocating first would make the
  # first loop iteration crash with nil.
  wd = word_dict
  $lemma_to_words = Hash.new { |h, k| h[k] = [] }
  wd.each_key do |w|
    base = lemma(w)
    $lemma_to_words[base] << w
  end
  $lemma_to_words
end

def save_word_dict(word_dict, lemma_map = nil)
  ensure_generated_dict_dir!
  path = generated_dict_path_under_dict_dir(WORD_DICT_FILENAME)
  f = BuildIoUtils.open(path, "w", encoding: "UTF-8", hint: "save_word_dict")
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
    if lemma_map
      lemma = lemma_map[word]
      if lemma && lemma != word
        f.print(',')
        f.print(lemma.sanitize)
      end
    end
    f.puts
  end
  f.close
end

# Emit the runtime-canonical word_dict.msgpack — same [freq, prons, lemma]
# triple shape as the in-memory hash returned by load_word_dict, with two
# storage tweaks:
#
#   * prons on disk is an Array of space-joined ARPABET strings (e.g.
#     ["K AE1 T", "K AE2 T"]) rather than an Array of Pronunciation
#     objects — keeps the file ~30% smaller than the equivalent nested array
#     of phoneme strings (one msgpack string header per pronunciation rather
#     than per phoneme) and matches the pron1|pron2 wire format we already
#     use in word_dict.txt, so load_word_dict_msgpack can pass each
#     element straight to pronstr.split → Pronunciation.new.
#   * lemma is stored as nil when it equals the headword (matches
#     save_word_lemma_map!'s "drop self-lemmas" policy). load_word_dict_
#     msgpack resolves nil back to the headword so the runtime contract
#     ("entry[2] is always a non-nil string equal to lemma or word") holds.
#
# Called right after save_word_dict in rebuild_rhymecrime_dictionaries so
# a single dict-build refreshes both the human-readable .txt and the
# runtime-loaded .msgpack. The Pronunciation#to_s join is cheap (~200K
# entries × 1-2 prons of 4-8 phonemes), well under the rest of the build.
def save_word_dict_msgpack!(word_dict, lemma_map = nil)
  ensure_generated_dict_dir!
  path = generated_dict_path_under_dict_dir(WORD_DICT_MSGPACK_FILENAME)
  obj = {}
  word_dict.each do |word, info|
    freq, prons = info
    lem = lemma_map ? lemma_map[word] : (info[2] || word)
    pron_strs = (prons || []).map(&:to_s)
    stored_lemma = (lem && lem != word) ? lem : nil
    obj[word] = [freq.to_i, pron_strs, stored_lemma]
  end
  MessagePackUtils.pack_and_save(path, obj)
  size_mb = (File.size(path).to_f / 1024 / 1024).round(2)
  puts "Wrote #{obj.size} word_dict entries to #{WORD_DICT_MSGPACK_FILENAME} (#{size_mb} MB)"
end

# Runtime mirror of load_word_dict that reads word_dict.msgpack instead
# of streaming the .txt file. Reconstitutes Pronunciation instances and
# resolves nil lemmas back to the headword so the returned hash is
# byte-for-byte equivalent to what load_word_dict would have produced from
# the .txt surface — every downstream consumer (lexicon_word_entry,
# pronunciations, lemma fallback, etc.) is shape-agnostic between the
# two loaders.
#
# Returns nil when the msgpack doesn't exist (caller falls back to the
# .txt loader for fresh checkouts pre-dict-build); raises through the
# usual MessagePack errors otherwise.
def load_word_dict_msgpack
  path = generated_dict_path_under_dict_dir(WORD_DICT_MSGPACK_FILENAME)
  return nil unless File.exist?(path)
  raw = MessagePackUtils.load_and_unpack(path)
  word_dict = {}
  raw.each do |word, entry|
    freq, pron_strs, stored_lemma = entry
    prons = []
    (pron_strs || []).each do |pronstr|
      phonemes = pronstr.split(" ")
      next if phonemes.empty?
      push_pronunciation_unless_duplicate!(prons, Pronunciation.new(phonemes))
    end
    word_dict[word] = [freq.to_i, prons, stored_lemma || word]
  end
  clear_spelling_variant_hyphen_caches!
  $lemma_to_words = nil
  $word_to_lemma = nil
  $word_to_semantic_base = nil
  $wiktionary_glosses = nil
  $thematically_related_memo = nil
  word_dict
end

# Emit the runtime-canonical rime_dict.msgpack — same {rime => [word, ...]}
# shape as load_string_hash(rime_dict.txt), but native MessagePack for fast
# Lambda cold-start load and an order-of-magnitude smaller bundle hit than
# the txt + .sanitize round-trip. Keys / values are stored verbatim (the txt
# surface uses .sanitize to fold " " → "_" for the whitespace-delimited
# format; msgpack doesn't need the fold so we keep raw spaces). Called from
# rebuild_rhymecrime_dictionaries alongside save_string_hash(... rime_dict
# ...).
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

# Runtime mirror of load_rime_dict_as_hash. Returns {rime => [word, ...]}
# or nil when the msgpack isn't on disk (caller falls back to the .txt
# loader for fresh checkouts pre-dict-build).
def load_rime_dict_msgpack
  path = generated_dict_path_under_dict_dir(RIME_DICT_MSGPACK_FILENAME)
  return nil unless File.exist?(path)
  raw = MessagePackUtils.load_and_unpack(path)
  out = {}
  raw.each { |rime, words| out[rime.to_s] = (words || []).map(&:to_s) }
  out
end

# Source-selection ablation gate. Env var RHYMECRIME_GLOSS_SOURCE ∈ {wordnet, wiktionary,
# both} (default both); the four gloss-using code paths (gloss_word_token_set /
# sense_vectors / sense_vectors_morphy in signals.rb, gloss_tokens_for_word in
# crime.rb, combined_glosses_for in bin/dump-sense-glosses) consult these helpers
# before walking either corpus, so flipping the env var produces a clean A/B without code
# edits. Used to retrain WN-only or WK-only baselines for direct classifier comparisons —
# see bin/diagnose-gloss-coverage and the experimental program around the Wiktionary-
# glosses extension. Memoized at first call: changing the env var mid-process won't take
# effect (the four paths cache token sets and sense-vector matrices keyed on word, not on
# source — a fresh process is the boundary).
$gloss_source_set = nil
def gloss_source_set
  $gloss_source_set ||= begin
    raw = ENV["RHYMECRIME_GLOSS_SOURCE"].to_s.strip.downcase
    case raw
    when "", "both" then Set[:wordnet, :wiktionary]
    when "wordnet", "wn" then Set[:wordnet]
    when "wiktionary", "wk", "kaikki" then Set[:wiktionary]
    else
      warn "RHYMECRIME_GLOSS_SOURCE=#{raw.inspect} not recognized; defaulting to both"
      Set[:wordnet, :wiktionary]
    end
  end
end

def gloss_source_use_wordnet?
  gloss_source_set.include?(:wordnet)
end

def gloss_source_use_wiktionary?
  gloss_source_set.include?(:wiktionary)
end

# Source ordering for the cap-bounded sense-vector / MPNet-item paths
# (sense_vectors, sense_vectors_morphy in signals.rb, combined_glosses_for
# in bin/dump-sense-glosses): WordNet first, Wiktionary fills remaining
# slots. Token-union and pooled-definition paths (gloss_word_token_set,
# gloss_tokens_for_word, def_cos) consume both sources fully rather than
# bumping into a cap.

# Lazy $wiktionary_glosses load. Map shape is { headword => [gloss_text, ...] } where
# each entry is one Kaikki sense's first gloss (alt-of / form-of pointer senses excluded
# at build time by load_wiktionary so only definitional text survives). Missing-file
# collapse to a false sentinel so callers don't pay a stat on every lookup; the
# read accessor wiktionary_glosses_for unwraps the sentinel back to an empty array.
$wiktionary_glosses = nil
def load_wiktionary_glosses!
  path = generated_dict_path(WIKTIONARY_GLOSSES_FILENAME)
  $wiktionary_glosses = File.exist?(path) ? MessagePackUtils.load_and_unpack(path) : false
end

# Returns Array<String> of Wiktionary glosses for word (one entry per definitional sense
# in the filtered Kaikki dump), or [] when the headword has no Wiktionary glosses, the
# msgpack isn't on disk yet, or RHYMECRIME_GLOSS_SOURCE excludes Wiktionary. Same
# conservative no-signal contract as gloss_tokens_for_word in crime.rb: callers fall
# back to WordNet-only behavior when this returns empty.
def wiktionary_glosses_for(word)
  return [] if word.nil? || word.to_s.empty?
  return [] unless gloss_source_use_wiktionary?
  load_wiktionary_glosses! if $wiktionary_glosses.nil?
  map = $wiktionary_glosses
  return [] unless map
  map[word.to_s] || []
end

# Source-agnostic Wiktionary accessor: bypasses RHYMECRIME_GLOSS_SOURCE entirely.
# Used by the wn_/wk_ split features (wn_gloss_match?, wk_sv_max, ...) which
# always read each source independently to study its individual contribution. The
# regular wiktionary_glosses_for above is the gate-respecting reader for the
# combined gloss_match? / sense_vectors paths and the runtime hot path.
def wiktionary_glosses_raw_for(word)
  return [] if word.nil? || word.to_s.empty?
  load_wiktionary_glosses! if $wiktionary_glosses.nil?
  map = $wiktionary_glosses
  return [] unless map
  map[word.to_s] || []
end

# Save the headword → [gloss, ...] map as WIKTIONARY_GLOSSES_FILENAME. Called from
# rebuild_rhymecrime_dictionaries alongside the other generated/-msgpack writers.
# Drops empty headword entries so the file size is bounded by the headword count that
# actually carries gloss text.
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

# Emit the runtime word → canonical_lemma msgpack consumed by word_to_lemma.
# Called right after save_word_dict in dict-build; only stores entries where
# the lemma differs from the word (matches lemma(w)'s "unknown → word"
# collapse and keeps the file small — ~40% of headwords have a non-self lemma).
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
  # word => sorted list of Kaikki-style POS strings (noun, verb, adj, …) after Layer A ∩ WordNet.
  obj = pos_map.keys.sort.to_h { |w| [w, pos_map[w].to_a.sort] }
  BuildIoUtils.write(path, JSON.generate(obj), encoding: "UTF-8", hint: "save_part_of_speech_map")
end

#
# rime (ARPABET key for rhyme lookup; see Pronunciation#rime)
#

def single_consonant?(phoneme_cluster)
  return phoneme_cluster.length == 1 && !phoneme_cluster[0].vowel?
end
