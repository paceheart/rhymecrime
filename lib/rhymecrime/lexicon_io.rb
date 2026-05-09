# frozen_string_literal: true

require "msgpack"
require_relative "io_utils"

# Msgpack read/write for dictionary artifacts (word_dict, rime_dict, lemma maps, glosses).
class MessagePackUtils
  def self.load_and_unpack(filename)
    bytes = IoUtils.binread(filename, hint: "MessagePackUtils.load_and_unpack")
    MessagePack.unpack(bytes)
  end

  def self.pack_and_save(filename, object)
    IoUtils.binwrite(filename, object.to_msgpack, hint: "MessagePackUtils.pack_and_save")
  end
end

#
# file utilities
#

def load_string_hash(filename)
  # each line is of the form:
  # KEY  STRING1 STRING2 ...
  # substitutes "_" with " " in keys after loading
  hash = Hash.new # hash of strings
  IoUtils.foreach(filename, encoding: "UTF-8", hint: "load_string_hash") do |line|
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
  IoUtils.foreach(pathname, encoding: "UTF-8", hint: "load_word_dict") do |line|
    next unless useful_line?(line)

    parts = line.chomp.split(",", 5)
    word = parts[0].desanitize
    freq = parts[1].to_i
    pronunciations_str = parts[2] || ""
    lemma_raw = parts[3]
    prefix_allows_raw = parts[4]
    prons = Array.new
    pronunciation_strings = pronunciations_str.split("|")
    for pronstr in pronunciation_strings
      phonemes = pronstr.split(" ")
      pron = Pronunciation.new(phonemes)
      push_pronunciation_unless_duplicate!(prons, pron)
    end
    lemma = (lemma_raw && !lemma_raw.strip.empty?) ? lemma_raw.strip.desanitize : word
    word_info = [freq, prons, lemma]
    if prefix_allows_raw && !prefix_allows_raw.strip.empty?
      bases = prefix_allows_raw.split("|").map(&:strip).reject(&:empty?).map(&:desanitize)
      word_info << bases unless bases.empty?
    end
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

# Overridden in query.rb after load (same shape; crime uses lazy word_dict()).
# Dict-build never loads query.rb — use $word_dict when the word_dict helper
# is not defined (see preferred_form_frequency_lookup).
def lexicon_word_entry(word)
  wd = defined?(word_dict) ? word_dict : $word_dict
  return nil if wd.nil?
  wd[word]
end

# Optional 4th column of word_dict: headword bases for which the prefix classifier
# allowed (word, base) as a rhyme. nil or empty => no override (rule-based filter only).
def lexicon_word_prefix_allow_bases(word)
  e = lexicon_word_entry(word)
  return nil unless e && e.size > 3
  bases = e[3]
  bases.is_a?(Array) && !bases.empty? ? bases : nil
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
    next unless entry.is_a?(Array)

    freq = entry[0]
    pron_strs = entry[1]
    stored_lemma = entry[2]
    allow_bases = entry.size > 3 ? entry[3] : nil
    prons = []
    (pron_strs || []).each do |pronstr|
      phonemes = pronstr.split(" ")
      next if phonemes.empty?
      push_pronunciation_unless_duplicate!(prons, Pronunciation.new(phonemes))
    end
    row = [freq.to_i, prons, stored_lemma || word]
    row << allow_bases if allow_bases.is_a?(Array) && !allow_bases.empty?
    word_dict[word] = row
  end
  clear_spelling_variant_hyphen_caches!
  $lemma_to_words = nil
  $word_to_lemma = nil
  $word_to_semantic_base = nil
  $wiktionary_glosses = nil
  $thematically_related_memo = nil
  word_dict
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
# query.rb, combined_glosses_for in bin/dump-sense-glosses) consult these helpers
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

# Loads the prefix gate precomputed by bin/precompute-prefix-gate.
# Returns a Hash { word => Set<base> } of :allow verdicts (filter is the default
# when a pair is absent). Returns false (falsy) if the msgpack is missing so
# callers can fall back gracefully to the rule-based prefix filter.
# Returns Array<String> of Wiktionary glosses for word (one entry per definitional sense
# in the filtered Kaikki dump), or [] when the headword has no Wiktionary glosses, the
# msgpack isn't on disk yet, or RHYMECRIME_GLOSS_SOURCE excludes Wiktionary. Same
# conservative no-signal contract as gloss_tokens_for_word in query.rb: callers fall
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

#
# rime (ARPABET key for rhyme lookup; see Pronunciation#rime)
#

def single_consonant?(phoneme_cluster)
  return phoneme_cluster.length == 1 && !phoneme_cluster[0].vowel?
end
