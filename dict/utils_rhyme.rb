#!/usr/bin/env ruby

require "fileutils"
require "json"
require "set"
require_relative "phoneme.rb"

# Rhyming utilities for RhymeCrime
# Used both in preprocessing and at runtime

RIME_DICT_FILENAME = "rime_dict.txt"
WORD_DICT_FILENAME = "word_dict.txt"
PART_OF_SPEECH_FILENAME = "part_of_speech.json"
# Multi-spelling hyphen folds (in-laws/inlaws, …); built in dict.rb, loaded at runtime.
HYPHEN_VARIANT_MAP_FILENAME = "hyphen_variant_map.json"
# ConceptNet-derived edge weights for topical relatedness; built in dict.rb, loaded at runtime.
CONCEPTNET_EDGES_FILENAME = "conceptnet_edges.json"
# Numberbatch word vectors pre-filtered to word_dict keys; built in dict.rb, loaded at runtime.
NUMBERBATCH_VECTORS_FILENAME = "numberbatch_vectors.msgpack"

# Outputs of dict/dict_lib.rb (via dict.rb); not hand-edited. Paths are relative to the dict/
# directory when the build runs with cwd = dict/; loaders use paths from the repository root.
DICT_GENERATED_SUBDIR = "generated"

def generated_dict_path(basename)
  File.join("dict", DICT_GENERATED_SUBDIR, basename)
end

def generated_dict_path_under_dict_dir(basename)
  File.join(DICT_GENERATED_SUBDIR, basename)
end

def ensure_generated_dict_dir!
  FileUtils.mkdir_p(DICT_GENERATED_SUBDIR)
end

#
# stop words
#

STOP_WORDS_TRIVIAL = ["i", "me", "my", "myself", "we", "our", "ours", "ourselves", "you", "your", "yours", "yourself", "yourselves", "he", "him", "his", "himself", "she", "her", "hers", "herself", "it", "its", "itself", "they", "them", "their", "theirs", "themself", "themselves", "what", "which", "who", "whom", "this", "that", "these", "those", "am", "is", "are", "was", "were", "be", "been", "being", "have", "has", "had", "having", "do", "does", "did", "doing", "a", "an", "the", "and", "but", "if", "or", "as", "of", "at", "by", "for", "with", "to", "from", "then", "so", "than", "i'd", "i've", "i'll", "we'd", "we've", "we'll", "you'd", "you've", "you'll", "he'd", "he'll", "she's", "she'd", "she'll", "it's", "it'd", "it'll", "they'd", "they've", "they'll", "that's", "that'd", "that've", "that'll", "what's", "what've", "what'll", "who's", "who'd", "who've", "who'll", "this'd", "this'll", "that's", "that'd", "that've", "that'll"] # added 's 'd 've 'll forms as appropriate

STOP_WORDS_RELATABLE = ["because", "until", "while", "about", "against", "between", "into", "through", "during", "before", "after", "above", "below", "up", "down", "in", "out", "on", "off", "over", "under", "again", "further", "once", "here", "there", "when", "where", "why", "how", "all", "any", "both", "each", "few", "more", "most", "other", "some", "such", "no", "nor", "not", "only", "own", "same", "too", "very", "can", "will", "just", "dont", "should", "now", "else"] # from https://gist.github.com/sebleier/554280, removed "s" "t", added "themself", and changed "don" to "dont", separated out the ones that ought not show up as related words of anything

def stop_word?(word)
  return STOP_WORDS_TRIVIAL.include?(word) || STOP_WORDS_RELATABLE.include?(word)
end

def relatable_word?(word)
  return ! STOP_WORDS_TRIVIAL.include?(word)
end

#
# forbid_list
#

$forbid_list = nil
def forbid_list()
  if $forbid_list.nil?
    $forbid_list = load_forbid_list_as_array
  end
  return $forbid_list
end

def explicitly_forbidden?(word)
  return forbid_list.include?(word)
end

def load_forbid_list_as_array
  if(File.exist?("forbid_list.txt"))
     return IO.readlines("forbid_list.txt", chomp: true, encoding: 'UTF-8')
  else
    return IO.readlines("dict/forbid_list.txt", chomp: true, encoding: 'UTF-8')
  end
end

def delete_explicitly_forbidden_words_from_array(array)
  return array.reject { |word| explicitly_forbidden?(word) }
end

#
# spelling variants
#

$variants = nil

# Cleared when spelling-variant file is reloaded or word_dict is re-read.
def clear_spelling_variant_hyphen_caches!
  @hyphen_multi_fold = nil
end

def variants()
  # hash: word -> [preferred_form alternate_form1 alternate_form2 ...]
  if $variants.nil?
    clear_spelling_variant_hyphen_caches!
    $variants = load_variants
  end
  return $variants
end

# US/UK -ize ↔ -ise (and -yze ↔ -yse) morphology: generate UK (s) from US (z) only.
# UK spellings map back to US as preferred only when that US headword exists in +$word_dict+
# (e.g. compromise has no valid *compromize*, so it is left alone—no blocklist needed).
US_UK_YZE_SUFFIXES = [
  ["yzing", "ysing"],
  ["yzes", "yses"],
  ["yzed", "ysed"],
  ["yze", "yse"],
].freeze

US_UK_IZE_SUFFIXES = [
  ["ization", "isation"],
  ["izations", "isations"],
  ["izable", "isable"],
  ["izer", "iser"],
  ["izers", "isers"],
  ["izing", "ising"],
  ["izes", "ises"],
  ["ized", "ised"],
  ["ize", "ise"],
].freeze

# Real -ize words that are not US verb morphology (avoid analyze→analyse style false path for "size", etc.).
US_UK_IZE_ZONLY_EXCEPTIONS = %w[size seize capsize prize maize].freeze

def word_dict_includes_headword?(w)
  defined?($word_dict) && $word_dict.is_a?(Hash) && !$word_dict.empty? && $word_dict.key?(w)
end

# Headwords to consider when expanding topical relatedness (RhymeCrime lexicon + test extras).
# Requires crime.rb to have defined +word_dict+ and optionally WORDS_NEEDED_FOR_TESTING.
def word_we_care_about?(word)
  w = word.to_s.downcase.strip
  return false if w.empty?
  return false if explicitly_forbidden?(w)
  return true if defined?(WORDS_NEEDED_FOR_TESTING) && WORDS_NEEDED_FOR_TESTING.include?(w)
  word_dict_includes_headword?(w)
end

def words_we_care_about
  keys = word_dict.keys
  keys |= WORDS_NEEDED_FOR_TESTING if defined?(WORDS_NEEDED_FOR_TESTING)
  keys.uniq
end

# Returns UK spelling for a US (z) headword, or nil if not applicable.
def us_to_uk_ize_spelling(us_word)
  w = us_word.to_s
  return nil if w.empty?
  US_UK_YZE_SUFFIXES.each do |us_s, uk_s|
    next unless w.end_with?(us_s)
    return w[0...-us_s.length] + uk_s
  end
  return nil if US_UK_IZE_ZONLY_EXCEPTIONS.include?(w)
  US_UK_IZE_SUFFIXES.each do |us_s, uk_s|
    next unless w.end_with?(us_s)
    stem = w[0...-us_s.length]
    # Not *-isable (UK is "sizeable" with e, not "sisable").
    return "sizeable" if us_s == "izable" && stem == "siz"
    return stem + uk_s
  end
  nil
end

# Inverse of us_to_uk_ize_spelling (for matching a UK surface form); does not validate English.
def uk_to_us_ize_spelling(uk_word)
  w = uk_word.to_s
  return nil if w.empty?
  return "sizable" if w == "sizeable" # TODO: load this from spelling_variants.txt instead of hardcoding it
  US_UK_YZE_SUFFIXES.each do |us_s, uk_s|
    next unless w.end_with?(uk_s)
    return w[0...-uk_s.length] + us_s
  end
  US_UK_IZE_SUFFIXES.each do |us_s, uk_s|
    next unless w.end_with?(uk_s)
    return w[0...-us_s.length] + us_s
  end
  nil
end

# [us_form, uk_form] with US first; nil if not an -ize/-ise pair we handle.
def us_uk_ize_pair(word)
  w = word.to_s
  return nil if w.empty?
  uk = us_to_uk_ize_spelling(w)
  if uk && uk != w
    return [w, uk]
  end
  us = uk_to_us_ize_spelling(w)
  if us && us != w && word_dict_includes_headword?(us) && us_to_uk_ize_spelling(us) == w
    return [us, w]
  end
  nil
end

# US/UK -or ↔ -our (behavior/behaviour, color/colour, …). Longest suffix first; both spellings
# must exist in +$word_dict+ (avoids tor/tour, for/four, contour, …).
US_UK_OR_SUFFIXES = [
  ["iors", "iours"],
  ["ior", "iour"],
  ["orites", "ourites"],
  ["oring", "ouring"],
  ["ored", "oured"],
  ["ors", "ours"],
  ["orite", "ourite"],
  ["orous", "ourous"],
  ["or", "our"],
].freeze

US_UK_OR_MIN_WORD_LENGTH = 5

def us_to_uk_or_spelling(us_word)
  w = us_word.to_s
  return nil if w.length < US_UK_OR_MIN_WORD_LENGTH
  US_UK_OR_SUFFIXES.sort_by { |us_s, _uk| [-us_s.length, us_s] }.each do |us_s, uk_s|
    next unless w.end_with?(us_s)
    return w[0...-us_s.length] + uk_s
  end
  nil
end

def uk_to_us_or_spelling(uk_word)
  w = uk_word.to_s
  return nil if w.length < US_UK_OR_MIN_WORD_LENGTH
  US_UK_OR_SUFFIXES.sort_by { |_us, uk_s| [-uk_s.length, uk_s] }.each do |us_s, uk_s|
    next unless w.end_with?(uk_s)
    return w[0...-uk_s.length] + us_s
  end
  nil
end

def us_uk_or_pair(word)
  w = word.to_s
  return nil if w.length < US_UK_OR_MIN_WORD_LENGTH
  uk = us_to_uk_or_spelling(w)
  if uk && uk != w && uk.length >= US_UK_OR_MIN_WORD_LENGTH && word_dict_includes_headword?(w) && word_dict_includes_headword?(uk) && uk_to_us_or_spelling(uk) == w
    return [w, uk]
  end
  us = uk_to_us_or_spelling(w)
  if us && us != w && us.length >= US_UK_OR_MIN_WORD_LENGTH && word_dict_includes_headword?(w) && word_dict_includes_headword?(us) && us_to_uk_or_spelling(us) == w
    return [us, w]
  end
  nil
end

# US/UK -er ↔ -re (center/centre, fiber/fibre, …). Longest suffix first; both spellings in +$word_dict+;
# stem before the matched suffix must end in a consonant and have length ≥ 3 (avoids acre/acer, etc.).
US_UK_ER_RE_SUFFIXES = [
  ["ering", "ring"],
  ["ered", "red"],
  ["ers", "res"],
  ["er", "re"],
].freeze

US_UK_ER_RE_MIN_WORD_LENGTH = 5

def us_to_uk_er_re_spelling(us_word)
  w = us_word.to_s
  return nil if w.length < US_UK_ER_RE_MIN_WORD_LENGTH
  US_UK_ER_RE_SUFFIXES.sort_by { |us_s, _uk| [-us_s.length, us_s] }.each do |us_s, uk_s|
    next unless w.end_with?(us_s)
    stem = w[0...-us_s.length]
    next unless stem.match?(/[bcdfghjklmnpqrstvwxyz]\z/i)
    next if stem.length < 3
    return stem + uk_s
  end
  nil
end

def uk_to_us_er_re_spelling(uk_word)
  w = uk_word.to_s
  return nil if w.length < US_UK_ER_RE_MIN_WORD_LENGTH
  US_UK_ER_RE_SUFFIXES.sort_by { |_us, uk_s| [-uk_s.length, uk_s] }.each do |us_s, uk_s|
    next unless w.end_with?(uk_s)
    stem = w[0...-uk_s.length]
    next unless stem.match?(/[bcdfghjklmnpqrstvwxyz]\z/i)
    next if stem.length < 3
    return stem + us_s
  end
  nil
end

def us_uk_er_re_pair(word)
  w = word.to_s
  return nil if w.length < US_UK_ER_RE_MIN_WORD_LENGTH
  uk = us_to_uk_er_re_spelling(w)
  if uk && uk != w && uk.length >= US_UK_ER_RE_MIN_WORD_LENGTH && word_dict_includes_headword?(w) && word_dict_includes_headword?(uk) && uk_to_us_er_re_spelling(uk) == w
    return [w, uk]
  end
  us = uk_to_us_er_re_spelling(w)
  if us && us != w && us.length >= US_UK_ER_RE_MIN_WORD_LENGTH && word_dict_includes_headword?(w) && word_dict_includes_headword?(us) && us_to_uk_er_re_spelling(us) == w
    return [us, w]
  end
  nil
end

def us_uk_morphology_pair(word)
  us_uk_ize_pair(word) || us_uk_or_pair(word) || us_uk_er_re_pair(word)
end

def us_uk_morphology_variant_forms(word)
  pair = us_uk_morphology_pair(word)
  return nil unless pair
  u, k = pair
  k == u ? [u] : [u, k]
end

# Fold for grouping hyphen-insensitive spellings (in-laws ↔ inlaws).
def spelling_variant_hyphen_fold(w)
  w.to_s.downcase.delete("-")
end

# Only folds with 2+ distinct surface forms (tiny hash vs. one entry per word).
VALID_HYPHEN_LEXEME_RE = /\A[[:alpha:]][[:alnum:]_'-]*\z/.freeze
NON_HYPHEN_PREF_RE = /\Anon-[[:alnum:]]/i.freeze

# First segment of phrasal-style hyphen compounds (in-laws, on-site, hand-out). Longest token first in the regex.
HYPHEN_COMPOUND_LEADING_PARTICLES = %w[down in off on out up].freeze
PARTICLE_HYPHEN_PREF_RE = Regexp.new(
  "\\A(?:#{HYPHEN_COMPOUND_LEADING_PARTICLES.sort_by { |t| [-t.length, t] }.join('|')})-[[:alpha:]]",
  Regexp::IGNORECASE
).freeze

# e.g. okey-dokey / low-key over okeydokey / lowkey when both are in the same hyphen fold.
REDUP_STYLE_SINGLE_HYPHEN_RE = /\A[[:alpha:]]{2,}-[[:alpha:]]{2,}\z/.freeze
# Second-segment matches here → prefer solid spelling (handout not hand-out). Omits +on+ (no common *-on tail).
HYPHEN_COMPOUND_TRAILING_PARTICLES_SOLID_PREF =
  (HYPHEN_COMPOUND_LEADING_PARTICLES - %w[on]).freeze

def hyphen_redup_prefers_hyphenated_form?(f)
  return false unless REDUP_STYLE_SINGLE_HYPHEN_RE.match?(f)
  left, right = f.split("-", 2)
  return false if COMMON_PREFIXES.include?(left.downcase)
  !HYPHEN_COMPOUND_TRAILING_PARTICLES_SOLID_PREF.include?(right.downcase)
end

def ingest_word_into_hyphen_fold_buckets!(buckets, w)
  return if w.nil? || w.empty?
  return unless w.match?(VALID_HYPHEN_LEXEME_RE)
  fold = w.downcase.delete("-")
  (buckets[fold] ||= Set.new) << w
end

# Build { fold => [form, ...] } only where multiple spellings share a fold.
# +explicit_word_keys+: enumerable of headwords (e.g. word_dict.keys) when building during dict.rb;
# otherwise uses +$word_dict+ or scans word_dict.txt (fallback when JSON cache is missing).
def build_hyphen_multi_fold_map(explicit_word_keys = nil)
  buckets = {}
  load_variants_raw.each do |line|
    next unless line =~ /\A[[:alpha:]]/
    line.split.each { |w| ingest_word_into_hyphen_fold_buckets!(buckets, w) }
  end
  if explicit_word_keys
    explicit_word_keys.each { |w| ingest_word_into_hyphen_fold_buckets!(buckets, w) }
  elsif defined?($word_dict) && $word_dict.is_a?(Hash) && !$word_dict.empty?
    $word_dict.each_key { |w| ingest_word_into_hyphen_fold_buckets!(buckets, w) }
  else
    path = generated_dict_path(WORD_DICT_FILENAME)
    if File.exist?(path)
      IO.foreach(path, encoding: "UTF-8") do |line|
        next if line =~ /\A;/ || line =~ /\A#/
        tok = line.split(",", 2).first
        next if tok.nil? || tok.empty?
        ingest_word_into_hyphen_fold_buckets!(buckets, tok.desanitize)
      end
    end
  end
  out = {}
  buckets.each do |fold, set|
    next if set.size < 2
    out[fold] = set.to_a.freeze
  end
  out.freeze
end

def save_hyphen_variant_map!(word_keys)
  map = build_hyphen_multi_fold_map(word_keys)
  in_dict = word_keys.to_set
  map = map.reject { |_fold, forms| forms.none? { |w| in_dict.include?(w) } }
  ensure_generated_dict_dir!
  path = generated_dict_path_under_dict_dir(HYPHEN_VARIANT_MAP_FILENAME)
  sorted = {}
  map.keys.sort.each { |k| sorted[k] = map[k].sort }
  File.write(path, "#{JSON.generate(sorted)}\n", encoding: "UTF-8")
  puts "Wrote #{sorted.size} hyphen-variant folds to #{HYPHEN_VARIANT_MAP_FILENAME}"
end

# --- ConceptNet edge map build ---
# Source: conceptnet-assertions-5.7.0.csv.gz (CC-BY-SA 4.0)
# Kept relations: RelatedTo, Synonym, IsA, HasA, PartOf, UsedFor, CapableOf, AtLocation,
# Causes, HasProperty, HasSubevent, DerivedFrom, FormOf, SimilarTo, HasPrerequisite,
# HasContext, MannerOf, ReceivesAction, HasFirstSubevent, HasLastSubevent, DefinedAs
CONCEPTNET_ASSERTIONS_GZ = "conceptnet-assertions-5.7.0.csv.gz"
CONCEPTNET_KEEP_RELATIONS = %w[
  /r/RelatedTo /r/Synonym /r/IsA /r/HasA /r/PartOf /r/UsedFor /r/CapableOf
  /r/AtLocation /r/Causes /r/HasProperty /r/HasSubevent /r/DerivedFrom /r/FormOf
  /r/SimilarTo /r/HasPrerequisite /r/HasContext /r/MannerOf /r/ReceivesAction
  /r/HasFirstSubevent /r/HasLastSubevent /r/DefinedAs
].to_set.freeze
CONCEPTNET_EN_NODE_RE = %r{\A/c/en/([a-z][a-z]*)\z}

def save_conceptnet_edge_map!(word_keys)
  require 'zlib'
  gz_path = CONCEPTNET_ASSERTIONS_GZ
  unless File.exist?(gz_path)
    puts "Skipping ConceptNet edge map: #{gz_path} not found"
    return
  end
  dict_set = word_keys.to_set
  edges = {}
  lines = 0
  Zlib::GzipReader.open(gz_path, encoding: "UTF-8") do |gz|
    gz.each_line do |line|
      lines += 1
      print "." if lines % 5_000_000 == 0
      parts = line.chomp.split("\t")
      next if parts.size < 5
      relation = parts[1]
      next unless CONCEPTNET_KEEP_RELATIONS.include?(relation)
      m1 = CONCEPTNET_EN_NODE_RE.match(parts[2])
      m2 = CONCEPTNET_EN_NODE_RE.match(parts[3])
      next unless m1 && m2
      w1, w2 = m1[1], m2[1]
      next if w1 == w2
      next unless dict_set.include?(w1) || dict_set.include?(w2)
      weight = begin
        JSON.parse(parts[4])["weight"] || 1.0
      rescue
        1.0
      end
      key = [w1, w2].sort.join("|")
      edges[key] = weight if weight > (edges[key] || 0)
    end
  end
  ensure_generated_dict_dir!
  path = generated_dict_path_under_dict_dir(CONCEPTNET_EDGES_FILENAME)
  File.write(path, JSON.generate(edges), encoding: "UTF-8")
  puts "\nWrote #{edges.size} ConceptNet edges to #{CONCEPTNET_EDGES_FILENAME}"
end

# --- Numberbatch vector build ---
# Source: numberbatch-en-19.08.txt (CC-BY-SA 4.0, pre-normalized)
NUMBERBATCH_TXT = "numberbatch-en-19.08.txt"

def save_numberbatch_vectors!(word_keys)
  txt_path = NUMBERBATCH_TXT
  unless File.exist?(txt_path)
    puts "Skipping Numberbatch vectors: #{txt_path} not found"
    return
  end
  dict_set = word_keys.to_set
  vectors = {}
  first = true
  File.foreach(txt_path, encoding: "UTF-8") do |line|
    if first
      first = false
      next
    end
    parts = line.rstrip.split(" ")
    word = parts[0]
    next unless word.match?(/\A[a-z]+\z/)
    next unless dict_set.include?(word)
    vec = parts[1..].map(&:to_f)
    mag = Math.sqrt(vec.sum { |v| v * v })
    next if mag == 0
    vec.map! { |v| (v / mag).round(5) }
    vectors[word] = vec
  end
  ensure_generated_dict_dir!
  path = generated_dict_path_under_dict_dir(NUMBERBATCH_VECTORS_FILENAME)
  File.binwrite(path, vectors.to_msgpack)
  size_mb = File.size(path) / 1024.0 / 1024.0
  puts "Wrote #{vectors.size} Numberbatch vectors to #{NUMBERBATCH_VECTORS_FILENAME} (#{size_mb.round(1)} MB)"
end

def load_hyphen_multi_fold_map_from_disk
  path = generated_dict_path(HYPHEN_VARIANT_MAP_FILENAME)
  return nil unless File.exist?(path)
  raw = JSON.parse(File.read(path, encoding: "UTF-8"))
  out = {}
  raw.each do |fold, arr|
    out[fold] = arr.freeze
  end
  out.freeze
rescue JSON::ParserError, SystemCallError
  nil
end

def hyphen_multi_fold_map
  @hyphen_multi_fold ||= (load_hyphen_multi_fold_map_from_disk || build_hyphen_multi_fold_map)
end

def preferred_among_hyphen_equivalents(forms)
  n = forms.length
  return forms[0] if n <= 1
  nons = []
  i = 0
  while i < n
    f = forms[i]
    nons << f if NON_HYPHEN_PREF_RE.match?(f)
    i += 1
  end
  return nons.min if nons.any?
  parts = []
  i = 0
  while i < n
    f = forms[i]
    parts << f if PARTICLE_HYPHEN_PREF_RE.match?(f)
    i += 1
  end
  return parts.min if parts.any?
  redups = []
  i = 0
  while i < n
    f = forms[i]
    redups << f if hyphen_redup_prefers_hyphenated_form?(f)
    i += 1
  end
  return redups.min if redups.any?
  forms.min_by { |f| [f.count("-"), f.downcase] }
end

def preferred_form(word)
  vf = variants[word]
  if vf
    debug "The preferred form of '#{word}' is '#{vf[0]}'" unless vf[0] == word
    return vf[0]
  end
  morph = us_uk_morphology_pair(word)
  if morph
    return morph[0]
  end
  forms = hyphen_multi_fold_map[spelling_variant_hyphen_fold(word)]
  return word if forms.nil? || forms.length < 2
  preferred_among_hyphen_equivalents(forms)
end

def all_forms(word)
  vf = variants[word]
  forms = hyphen_multi_fold_map[spelling_variant_hyphen_fold(word)]
  forms = nil if forms.nil? || forms.length < 2
  morph = us_uk_morphology_variant_forms(word)
  if vf
    unless forms
      if morph
        merged = vf.dup
        morph.each { |x| merged << x unless merged.include?(x) }
        return merged.uniq
      end
      return vf
    end
    merged = vf.dup
    morph&.each { |x| merged << x unless merged.include?(x) }
    forms.each { |x| merged << x unless merged.include?(x) }
    return merged.uniq
  end
  if morph
    unless forms
      return morph
    end
    merged = morph.dup
    forms.each { |x| merged << x unless merged.include?(x) }
    return merged.uniq
  end
  if forms
    pref = preferred_among_hyphen_equivalents(forms)
    rest = forms.reject { |w| w == pref }.sort
    return [pref] + rest
  end
  [word]
end

def load_variants_raw
  if(File.exist?("spelling_variants.txt"))
     return IO.readlines("spelling_variants.txt", chomp: true, encoding: 'UTF-8')
  else
     return IO.readlines("dict/spelling_variants.txt", chomp: true, encoding: 'UTF-8')
  end
end

def load_variants
  variants_array = load_variants_raw
  hash = Hash.new
  for line in variants_array
    if line =~ /\A[[:alpha:]]/ # ignore lines that start with comment characters, punctuation, or numbers
      all_forms = line.split
      for word in all_forms
        hash[word] = all_forms
      end
    end
  end
  hash
end

#
# prefixes (crime.rb prefix_words; dict_lib syllabification). Order: longer before shorter where one
# contains another (+inter+ before +in+). Overlaps +HYPHEN_COMPOUND_LEADING_PARTICLES+ only on +in+,
# +out+, +up+ — those serve different rules; do not merge arrays without checking both call sites.
#

COMMON_PREFIXES = [
  'ante',
  'anti',
  'auto',
  'bi',
  'co',
  'com',
  'con',
  'contra',
  'de',
  'dis',
  'en',
  'ex',
  'extra',
  'hetero',
  'homeo',
  'homo',
  'hyper',
  'in',
  'inter',
  'intra',
  'macro',
  'micro',
  'mis',
  'mono',
  'non',
  'omni',
  'out',
  'over',
  'post',
  'pre',
  'pro',
  're',
  'sub',
  'super',
  'sym',
  'syn',
  'tele',
  'trans',
  'tri',
  'un',
  'under',
  'uni',
  'up',
]

#
# consonant clusters and syllabification
#

ALL_INITIAL_CONSONANT_CLUSTERS = [
  'B L', # blue
  'B R', # bread
  'B W', # bueno
  'B Y', # bugle
  'F Y', # few
  'D R', # draw
  'D W', # dwell
  'D Y', # due(1)
  'F L', # flaw
  'F R', # free
  'G L', # glow
  'G R', # grow
  'G W', # guava
  'HH Y', # hue
  'K L', # claw
  'K R', # crow
  'K W', # quick
  'K Y', # cue
  'M Y', # mute
  'P L', # play
  'P R', # pray
  'P W', # pueblo
  'P Y', # pupil
  'S F', # sphere
  'S K', # sky
  'S K L', # sclera
  'S K R', # scrub
  'S K W', # squall
  'S K Y', # skew
  'S P Y', # spume
  'S L', # sled
  'S M', # small
  'S N', # snow
  'S P', # speech
  'S P L', # split
  'S P R', # spray
  'S T', # stay
  'S T R', # straw
  'S W', # sway
  'SH L', # schlock
  'SH M', # schmooze
  'SH R', # shred
  'SH T', # schtick
  'SH W', # schwa
  'T R', # tree
  'T W', # twig
  'TH R', # throw
  'TH W', # thwack
  'V Y', # view
  'ZH W', # joie
] # ARPABET format. source: John Algeo, https://www.tandfonline.com/doi/pdf/10.1080/00437956.1978.11435661 + original work

# Onset clusters legal only at the true start of a word (forward order). Not consulted for medial
# syllabification, so e.g. L AY1 V L IY0 (lively) keeps V in the preceding coda instead of merging V+L.
WORD_INITIAL_CONSONANT_CLUSTERS = [
  'V L', # Vlad, Vladimir; Slavic Vl- names
].freeze

ALL_FINAL_CONSONANT_CLUSTERS = [
  'B D', # grabbed
  'B Z', # cubs
  'CH T', # patched
  'D TH', # width
  'D TH S', # widths
  'D S T', # midst, rare
  'D Z', # adze
  'DH D', # clothed
  'DH Z', # clothes
  'F S', # graphs
  'F T', # soft
  'F T S', # lifts
  'F TH', # fifth
  'F TH S', # fifths
  'G D', # bogged
  'G Z', # eggs
  'JH D', # bulged
  'K S', # fix
  'K S T', # fixed
  'K S T S', # texts
  'K T', # act
  'K T S', # acts
  'L B', # bulb
  'L B Z', # bulbs
  'L CH', # belch
  'L CH T', # belched
  'L D', # build
  'L D Z', # builds
  'L F', # gulf
  'L F S', # gulfs
  'L F T', # engulfed
  'L F TH', # twelfth, rare
  'L F TH S', # twelfths, rare
  'L JH', # bulge
  'L JH D', # bulged
  'L K', # silk
  'L K S', # silks
  'L K T', # milked
  'L M', # film
  'L M D', # filmed
  'L M Z', # films
  'L N', # kiln, rare
  'L N Z', # kilns, rare
  'L P', # help
  'L P S', # helps
  'L P T', # helped
  'L P T S', # sculpts, rare
  'L S', # else
  'L S T', # pulsed
  'L T', # salt
  'L T S', # salts
  'L TH', # wealth
  'L TH S', # wealths
  # 'L TH T', # wealthed? theoretically possible, but doesn't occur
  'L V', # valve
  'L V D', # solved
  'L V Z', # valves
  'L Z', # feels
  'M D', # framed
  'M F', # triumph
  'M F S', # triumphs
  'M F T', # triumphed
  'M P', # jump
  'M P S', # jumps
  'M P S T', # glimpsed
  'M P T', # jumped
  'M P T S', # tempts
  'M T', # dreamt
  'M Z', # dooms
  'N CH', # punch
  'N CH T', # punched
  'N D', # send
  'N D Z', # sends
  'N JH', # change
  'N JH D', # changed
  'N S', # fence
  'N S T', # fenced
  'N T', # cent
  'N T S', # cents
  'N T S T', # incensed (?)
  'N TH', # tenth
  'N TH S', # tenths
  # 'N TH T', # tenthed? theoretically possible, but doesn't occur
  'N Z', # bronze
  'N Z D', # bronzed
  'NG D', # wronged
  'NG K', # ink
  'NG K S', # inks
  'NG K T', # inked
  'NG K T S', # instincts
  'NG K TH', # length
  'NG K TH S', # lengths
  # 'NG TH T', # lengthed? theoretically possible, but doesn't occur
  'NG Z', # things
  'P S', # lapse
  'P S T', # lapsed
  'P T', # apt
  'P T S', # opts
  'P TH', # depth
  'P TH S', # depths
  'R B', # curb
  'R B D', # curbed
  'R B Z', # curbs
  'R CH T', # arched
  'R CH', # arch
  'R D', # beard
  'R D Z', # beards
  'R DH Z', # berths
  'R F', # scarf
  'R F S', # scarfs
  'R F T', # scarfed
  'R G', # morgue
  # 'R G D', # morgued? theoretically possible, but doesn't occur
  'R G Z', # morgues
  'R JH', # merge
  'R JH D', # merged
  'R K', # mark
  'R K T', # marked
  'R K S', # marks
  'R L D', # world
  'R L D Z', # worlds
  'R L', # curl
  'R L Z', # curls
  'R M', # storm
  'R M D', # stormed
  'R M TH', # warmth
  # 'R M TH S', # warmths? theoretically possible, but doesn't occur
  'R M Z', # storms
  'R N', # earn
  'R N D', # earned
  'R N T', # burnt
  'R N Z', # burns
  'R P', # harp
  'R P S', # harps
  'R P T', # excerpt
  'R P T S', # excerpts
  'R S', # force
  'R S T', # forced
  'R S T S', # bursts
  'R SH', # marsh
  'R SH T', # borscht
  'R T', # part
  'R T S', # parts
  'R TH', # north
  'R TH S', # births
  'R TH T', # unearthed, rare
  'R V', # curve
  'R V D', # curved
  'R V Z', # curves
  'R Z', # furs
  'S K', # mask
  'S K S', # masks
  'S K T', # masked
  'S P', # clasp
  'S P S', # clasps
  'S P T', # clasped
  'S T', # chest
  'S T S', # chests
  'SH T', # mashed
  'T S', # eats
  'T S T', # blitzed
  'TH S', # breaths
  'TH T', # bequeathed
  'V D', # caved
  'V Z', # drives
  'Z D', # dozed
  'ZH D', # camouflaged
] # ARPABET format. source: John Algeo, https://www.tandfonline.com/doi/pdf/10.1080/00437956.1978.11435661 + original work

# Words with weird initial/final consonant clusters that should be included anyway
WHITELIST = [
  'dvorak',
  'neuroscience',
  'neuroscientist',
  'nyet',
  'sbarro',
  'schneider',
  'svelte',
  'tsetse',
  'tsunami',
  'vlad',
  'vladimir',
  'vroom',
  'voila',
  'zloty',
  'zlotys',
]

#
# file utilities
#

def load_string_hash(filename)
  # each line is of the form:
  # KEY  STRING1 STRING2 ...
  # substitutes "_" with " " in keys after loading
  hash = Hash.new # hash of strings
  IO.readlines(filename, encoding: 'UTF-8').each{ |line|
    if(useful_line?(line))
      tokens = line.split
      key = tokens.shift # now TOKENS contains only the value strings
      key = key.sanitize
      hash[key] = tokens.map{ |str| str.desanitize }
    else
      debug "Ignoring #{filename} line: #{line}"
    end
  }
  debug "Loaded #{hash.length} entries from #{filename}"
  return hash
end
def save_string_hash(hash, filename, header="")
  # sanitizes spaces into underscores
  FileUtils.mkdir_p(File.dirname(filename))
  @fh = File.open(filename, "w", encoding: "UTF-8")
  unless header.empty?
    @fh.puts(header)
  end
  hash.each do |key, values|
    key = key.sanitize
    @fh.print "#{key} "
    for value in values do
      value = value.sanitize
      @fh.print " #{value}"
    end
    @fh.puts
  end
  @fh.close
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
  pathname = generated_dict_path(WORD_DICT_FILENAME)
  unless File.exist?(pathname)
    die "First run dict/dict.rb from dict/ to generate dictionary caches"
  end
  word_dict = Hash.new
  IO.readlines(pathname, encoding: 'UTF-8').each{ |line|
    if(useful_line?(line))
      word, freq, pronunciations_str = line.split(",")
      word = word.desanitize
      freq = freq.to_i
      prons = Array.new
      pronunciation_strings = pronunciations_str.split("|")
      for pronstr in pronunciation_strings
        phonemes = pronstr.split(" ")
        pron = Pronunciation.new(phonemes)
        push_pronunciation_unless_duplicate!(prons, pron)
      end
      word_info = [freq, prons]
      word_dict[word] = word_info
    end
  }
  clear_spelling_variant_hyphen_caches!
  word_dict
end

def save_word_dict(word_dict)
  ensure_generated_dict_dir!
  path = generated_dict_path_under_dict_dir(WORD_DICT_FILENAME)
  f = File.open(path, "w", encoding: "UTF-8")
  f.puts(WORD_DICT_HEADER)
  for word, word_info in word_dict
    word = word.sanitize
    f.print(word)
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
    f.puts
  end
  f.close
end

def save_part_of_speech_map(pos_map)
  ensure_generated_dict_dir!
  path = generated_dict_path_under_dict_dir(PART_OF_SPEECH_FILENAME)
  # word => sorted list of Kaikki-style POS strings (noun, verb, adj, …) after Layer A ∩ WordNet.
  obj = pos_map.keys.sort.to_h { |w| [w, pos_map[w].to_a.sort] }
  File.write(path, JSON.generate(obj), encoding: "UTF-8")
end

#
# rime (ARPABET key for rhyme lookup; see Pronunciation#rime)
#

def single_consonant?(phoneme_cluster)
  return phoneme_cluster.length == 1 && !phoneme_cluster[0].vowel?
end
