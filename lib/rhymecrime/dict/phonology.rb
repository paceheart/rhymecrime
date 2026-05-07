# encoding: utf-8
# frozen_string_literal: true

# CMU ingest, ARPAbet normalization, syllabification, Wiktionary pronunciation merge.

require_relative "utils_rhyme"
require_relative "phoneme.rb"
require_relative "pronunciation.rb"
require_relative "constants"

def delete_explicitly_forbidden_keys_from_hash(pronunciation_map)
  count = 0
  for bad_word in forbid_list
    if(pronunciation_map.delete(bad_word.chomp))
      count = count + 1
    end
  end
  puts "Removed #{count} explicitly_forbidden words from the dictionary"
end

# Sibling of delete_explicitly_forbidden_keys_from_hash that drops every
# entry in curated/unrhymable_stop_words.txt from hash. Same shape, same
# call sites: the early scrub on raw pronunciation_map in dict.rb and the late
# forbidden_scrub pass in frequency.rb. Two scrubs because SUBTLEX /
# wiktionary expansion can re-introduce a word like "the" between the two
# passes; the late scrub catches anything that snuck back in.
def delete_unrhymable_stop_words_from_hash(hash)
  count = 0
  unrhymable_stop_words.each do |w|
    count += 1 if hash.delete(w)
  end
  puts "Removed #{count} unrhymable stop words from the dictionary"
end

# Incomplete / artifact headwords (e.g. truncated compounds); not useful as lookup keys.
# Called twice: early on raw pronunciation_map (values are pron arrays — hash.delete
# removes the row outright) and late on word_dict mid-build, where values
# are BuildEntry instances and deletion is deferred to the terminal reducer.
# The BuildEntry branch calls mark_tombstoned! so the entry stays
# in the map (skipped by subsequent phases via tombstoned?) until
# finalize_build_entries! drops it.
def delete_headwords_with_edge_hyphen!(hash)
  n = 0
  hash.keys.each do |w|
    next unless w.start_with?("-") || w.end_with?("-")
    entry = hash[w]
    if defined?(BuildEntry) && entry.is_a?(BuildEntry)
      next if entry.tombstoned?
      entry.mark_tombstoned!(phase: :edge_hyphen_scrub, reason: :leading_or_trailing_hyphen)
    else
      hash.delete(w)
    end
    n += 1
  end
  n
end

def useful_cmudict_line?(line)
  # ignore entries that start with comment characters, punctuation, or numbers
  if(line =~ /\A'/)
    whitelisted_apostrophe_words = ["'allo", "'bout", "'cause", "'em", "'til", "'tis", "'twas", "'kay", "'gain"] # most of the words in cmudict that begin with an apostrophe are shit, but these are okay.
    whitelisted_apostrophe_words.include?(line.split.shift.downcase)
  else
    line =~ /\A[[A-Z]]/
  end
rescue ArgumentError => error
  false
end

def preprocess_cmudict_line(line)
  # Step 1.1: Tweak the given pronunciation to deal with quirks of cmudict.
  # Phoneme-level rules are shared with Wiktionary/kaikki and Inflect-derived prons
  # (normalize_flat_arphabet_pronunciation).
  line = line.chomp
  original_line = line.clone
  parts = line.split
  return line if parts.length <= 1

  word_token = parts.shift
  pron = normalize_flat_arphabet_pronunciation(Pronunciation.new(parts))
  line = "#{word_token} #{pron.phonemes.join(" ")}"
  if dict_trace_preprocess_line?(original_line, line)
    focus = TRACE_WORDS.find { |tw| original_line.downcase.include?(tw) || line.downcase.include?(tw) }
    dict_trace_puts(focus, "Preprocessed #{original_line} to #{line}")
  end
  line
end

# Placeholder must not appear in ARPAbet text; avoids allocating "old + \" R\"" on every call.
GSUB_UNLESS_R_PLACEHOLDER = "fubarduckR"

# Prebuilt " AO{n} R" / " AO{n}" / " AA{n}" triples — no per-call string concat.
GSUB_AO_NOT_BEFORE_R = [
  [" AO0 R", " AO0", " AA0"],
  [" AO1 R", " AO1", " AA1"],
  [" AO2 R", " AO2", " AA2"],
].freeze

def gsub_unless_followed_by_r(line, old_followed_by_r, old_plain, new_plain)
  line.gsub!(old_followed_by_r, GSUB_UNLESS_R_PLACEHOLDER)
  line.gsub!(old_plain, new_plain)
  line.gsub!(GSUB_UNLESS_R_PLACEHOLDER, old_followed_by_r)
  line
end

# ARPAbet string normalizations historically run only on CMU lines; they also apply to Wikt/kaikki
# IPA→ARPAbet output and Inflect-derived phoneme lists so rhyme buckets stay consistent.
def apply_shared_arphabet_phoneme_string_normalizations(phoneme_space_string)
  line = phoneme_space_string.dup

  # this one comes first because it splits ER into two phonemes
  # curry [K AH1 R IY0] / hurry [HH ER1 IY0]
  line.gsub!("ER0 R", "AH0 R") # avoid R R
  line.gsub!("ER1 R", "AH1 R")
  line.gsub!("ER2 R", "AH2 R")
  line.gsub!("ER0", "AH0 R")
  line.gsub!("ER1", "AH1 R")
  line.gsub!("ER2", "AH2 R")

  # ear [IY R] / beer [B IH R]
  line.gsub!("IH0 R", "IY0 R")
  line.gsub!("IH1 R", "IY1 R")
  line.gsub!("IH2 R", "IY2 R")

  # faring [F EH1 R IY0 NG] / glaring [G L EH1 R IH0 NG]
  line.gsub!("IH0 NG", "IY0 NG")
  line.gsub!("IH1 NG", "IY1 NG")
  line.gsub!("IH2 NG", "IY2 NG")

  # poor [P UW1 R] / tour [T UH1 R]
  line.gsub!("UW0 R", "UH0 R")
  line.gsub!("UW1 R", "UH1 R")
  line.gsub!("UW2 R", "UH2 R")

  # caught [K AA1 T] / fought [F AO1 T]; not before R (bar / score)
  GSUB_AO_NOT_BEFORE_R.each do |old_r, old_plain, new_plain|
    line = gsub_unless_followed_by_r(line, old_r, old_plain, new_plain)
  end

  # Globally conflate ZH with JH for rhyme bucketing. CMU / Wikt treat the
  # voiceless postalveolar fricative (occasion, measure) and the voiced
  # affricate's fricative release (cajun, lodge) under different ARPAbet
  # symbols, but for imperfect rhymes users expect them in the same cohort
  # (cajun / occasion). Normalizing here keeps CMU ingest, Wikt IPA→ARPAbet,
  # and word_dict exports aligned — no ZH tokens survive into rime keys.
  line.gsub!(/\bZH\b/, "JH")

  line
end

# Suffix replacements for imperfect-rhyme conflation; order must match conflate_imperfect_rhyme_phoneme_string.
CONFLATE_IMPERFECT_RHYME_SUFFIX_RULES = [
  [%w[L S], %w[L T S]], # else / melts
  [%w[M T], %w[M P T]], # dreamt / tempt
  [%w[N D Z], %w[N Z]], # funds / tons
  [%w[N S], %w[N T S]], # fence / scents
  [%w[T CH], %w[CH]],
  [%w[AY1 AH0 R], %w[AY1 R]], # compress word-final disyllabic "TYE-er" into monosyllabic "TYRE"
  [%w[AY1 AH0 R Z], %w[AY1 R Z]], # same for tires
  [%w[AY1 AH0 R D], %w[AY1 R D]], # same for tired
].freeze

# Array-native conflate (avoids an extra join/split vs string-only path).
def conflate_imperfect_rhyme_phoneme_tokens(tokens)
  t = tokens.dup
  CONFLATE_IMPERFECT_RHYME_SUFFIX_RULES.each do |from, to|
    n = from.length
    next if t.length < n
    next unless t[-n, n] == from

    t[-n, n] = to
  end
  t
end

# Flat ARPAbet pronunciation (no syllable dots): same pipeline as CMU phoneme tail after the headword.
def normalize_flat_arphabet_pronunciation(pron)
  return pron if pron.nil? || pron.empty?
  flat = pron.phonemes.reject { |p| p == "." }
  return pron if flat.empty?

  s = apply_shared_arphabet_phoneme_string_normalizations(flat.join(" "))
  p = Pronunciation.new(s.split).with_dwimmed_schwas
  tok = conflate_imperfect_rhyme_phoneme_tokens(p.phonemes)
  Pronunciation.new(tok).with_flapped_t
end

# Flat phoneme lists for stem (each stored pronunciation, dots stripped).
def flat_pron_sequences_for_word(flat_by_word, stem)
  (flat_by_word[stem] || []).map { |p| p.phonemes.reject { |ph| ph == "." } }
end

# If word starts with a COMMON_PREFIXES string and the stem exists in flat_by_word with a
# flat pronunciation equal to the tail of word's phones, insert one syllable boundary between
# prefix and stem. MOP alone often merges the last consonant of the prefix into the stem syllable
# (e.g. AH0 P EH1 N D → ə|ˈpend instead of ʌp|ˈɛnd). Do not call syllabify on the merged string
# (avoids re-splitting and double dots). If no prefix+stem tail match, fall back to syllabify.
def syllabify_with_common_prefix_split(word, normalized_flat_pron, flat_by_word)
  flat = normalized_flat_pron.phonemes.reject { |ph| ph == "." }
  COMMON_PREFIXES.sort_by(&:length).reverse.each do |prefix|
    next if word.length <= prefix.length
    next unless word.start_with?(prefix)
    stem = word[prefix.length..-1]
    next if stem.length < 2
    flat_pron_sequences_for_word(flat_by_word, stem).each do |stem_flat|
      next if stem_flat.empty? || flat.length <= stem_flat.length
      next unless flat[-stem_flat.length..-1] == stem_flat
      prefix_flat = flat[0...-stem_flat.length]
      next if prefix_flat.empty?
      # A morphological prefix must carry its own vowel — otherwise inserting a
      # syllable boundary right after it produces a vowelless "syllable" (beau =
      # be + au flat-prons as B . OW1, leaving B as syllable 1; cooperate's
      # alt pron K W AA1 P AH0 R EY2 T similarly leaves K W standing alone).
      # When that happens we're not really seeing a prefix derivation at the
      # phonological level — fall through to plain syllabify.
      next unless prefix_flat.any?(&:vowel?)
      # Re-syllabify both halves: stem_flat comes from flat_pron_sequences_for_word
      # which strips . from the stem's stored pron, so without this the stem half
      # collapses into one giant vowel-stuffed syllable (illegitimate → IH2 . L AH0 JH
      # IH1 D AH0 M AH0 T, four vowels in syllable 2). The prefix half is short enough
      # that syllabify is a no-op for native prefixes, but doing it symmetrically
      # also handles tele/supe/inte etc.
      prefix_syl = Pronunciation.new(prefix_flat).syllabify.phonemes
      stem_syl   = Pronunciation.new(stem_flat).syllabify.phonemes
      result = Pronunciation.new(prefix_syl + ["."] + stem_syl)
      check_syllable_vowel_invariant!(result, word, "syllabify_with_common_prefix_split")
      return result
    end
  end
  result = normalized_flat_pron.syllabify
  check_syllable_vowel_invariant!(result, word, "syllabify")
  result
end

# Build-time invariant: a well-syllabified ARPAbet pronunciation has exactly
# one vowel per syllable (CMU encodes syllabic consonants as a vowel symbol,
# so this is universal — see Pronunciation#syllable_vowel_invariant_ok?).
# Violations indicate a bug in whatever produced the syllabification (e.g.
# concatenating an un-syllabified stem onto a prefix without re-running
# syllabify, the historical illegitimate → IH2 . L AH0 JH IH1 D AH0 M
# AH0 T regression).
#
# Default mode is raise — the dict has been audited clean (see
# bin/audit-syllable-vowel-invariant), so any new violation is a bug we
# want to surface loudly during bin/dict-build. Set
# RHYMECRIME_SYLL_INVARIANT=warn to demote to a stderr warning while
# debugging, =off to silence entirely.
def check_syllable_vowel_invariant!(pron, word, source)
  return if pron.nil? || pron.empty?
  return if pron.syllable_vowel_invariant_ok?
  mode = ENV.fetch("RHYMECRIME_SYLL_INVARIANT", "raise").to_s.downcase

  msg = "syllable-vowel invariant violated for #{word.inspect} via #{source}: " \
        "#{pron.syllable_vowel_invariant_violation} (full: #{pron})"
  case mode
  when "off", ""
    # silenced
  when "warn"
    warn msg
  else
    raise msg
  end
end

def conflate_imperfect_rhyme_phoneme_string(phoneme_space_string)
  conflate_imperfect_rhyme_phoneme_tokens(phoneme_space_string.split).join(" ")
end

# CMUDict sometimes lists an abbreviation's *expanded* form as an alternate pronunciation:
# e.g. TV(1) = T EH2 L AH0 V IH1 JH AH0 N (the pronunciation of "television") or
# CORP(1) = K AO1 R P ER0 EY1 SH AH0 N (pronunciation of "corporation"). These bogus
# alternates cause abbreviations to rhyme with words they don't actually sound like
# (e.g. tv sharing a rime with vision).
#
# We detect them with a tight, conservative heuristic: an alternate is dropped only if
#   (a) its phoneme count is at least 2x the primary's AND at least 3 more phonemes, AND
#   (b) after stripping stress digits, it exactly matches some *other* word's primary
#       pronunciation.
# Legit alternate pronunciations (stress variants, vowel shifts, homophones, spelling
# variants of roughly-equal length) all pass through untouched. As of CMUDict 0.7c, this
# filter drops exactly 11 entries: AL., CONN., CORP family, GA, JAN., MASS., REP, TV.
def drop_abbreviation_expansion_alternates!(cmudict_flat_prons)
  strip_stress = ->(pron) { pron.phonemes.map { |ph| ph.to_s.gsub(/\d/, "") }.join(" ") }
  primary_pron_fingerprint_to_words = Hash.new { |h, k| h[k] = [] }
  cmudict_flat_prons.each do |word, prons|
    next if prons.empty?
    primary_pron_fingerprint_to_words[strip_stress.call(prons.first)] << word
  end
  dropped = 0
  cmudict_flat_prons.each do |word, prons|
    next if prons.size < 2
    primary = prons.first
    primary_len = primary.phonemes.length
    filtered = [primary]
    prons.drop(1).each do |alt|
      alt_len = alt.phonemes.length
      fp = strip_stress.call(alt)
      other_word_match = (primary_pron_fingerprint_to_words[fp] - [word]).any?
      if other_word_match && alt_len >= 2 * primary_len && alt_len - primary_len >= 3
        dropped += 1
        dict_trace_puts(word, "Dropping abbreviation-expansion alt: #{alt} (matches primary of #{primary_pron_fingerprint_to_words[fp] - [word]})") if dict_trace_word?(word)
      else
        filtered << alt
      end
    end
    cmudict_flat_prons[word] = filtered
  end
  dropped
end

AUTHORITATIVE_PRONUNCIATIONS_PATH = File.join(CURATED_DIR, "authoritative_pronunciations.txt")

# Hand-curated pronunciation overrides. Loaded before CMUdict (and merged ahead
# of Wiktionary/Kaikki/Inflect) so that when we have a better pronunciation for
# a word than any corpus provides, it wins uncontested.
#
# File format: same as CMUdict ("WORD  PH PH PH" lines, ";;;" comments
# ignored). Multiple lines per word allowed (alternate prons). Missing file
# is a silent no-op — the file is optional.
#
# Contract: for any word listed here, the downstream loaders skip adding
# pronunciations from any other source:
#   * load_cmudict                          — early next on authoritative hit
#   * merge_wiktionary!                     — next if pronunciation_map.key?(word)
#   * merge_inflected_forms!                — next if pronunciation_map.key?(inflected_word)
#   * merge_gdropped_in_apostrophe_forms!   — next if pronunciation_map.key?(in_prime)
# (The last three already guard on pronunciation_map.key?, which is now true for
# authoritative words because we populate hash ahead of the CMUdict load.)
#
# Cluster / consonant filters are *not* applied to authoritative entries: they
# are user-vetted by definition.
#
# Returns a Set of the authoritative words (used by load_cmudict to skip
# CMU rows) and mutates hash in place. Also memoizes the set into
# $authoritative_pronunciation_words so downstream phases (the rarity
# classifier in particular) can consult it without re-parsing the file.
def load_authoritative_pronunciations!(hash)
  words = Set.new
  unless File.exist?(AUTHORITATIVE_PRONUNCIATIONS_PATH)
    $authoritative_pronunciation_words = words
    return words
  end

  n_lines = 0
  BuildIo.foreach(AUTHORITATIVE_PRONUNCIATIONS_PATH, encoding: "UTF-8", hint: "load_authoritative_pronunciations") do |line|
    next unless useful_cmudict_line?(line)

    line = preprocess_cmudict_line(line)
    tokens = line.split
    next if tokens.length < 2

    word = tokens.shift.downcase.desanitize
    # CMUdict-style WORD(2) alternate-pron suffix — strip it so multiple
    # authoritative prons for the same word stack cleanly.
    word = word[0...-3] if word =~ /\([0-9]\)\Z/
    pron = Pronunciation.new(tokens)
    push_pronunciation_unless_duplicate!(hash[word], pron)
    words.add(word)
    n_lines += 1
  end
  puts "Loaded #{n_lines} authoritative pronunciations for #{words.size} words from #{File.basename(AUTHORITATIVE_PRONUNCIATIONS_PATH)}" if n_lines > 0
  $authoritative_pronunciation_words = words
  words
end

# Memoized set of headwords listed in authoritative_pronunciations.txt.
# Populated as a side effect of load_authoritative_pronunciations! during
# load_cmudict; if no build has run yet (e.g. an early consumer) we lazy-load
# headwords-only without mutating any pron hash. The set is the canonical
# answer to "did a curator hand-add this word?" — used by the rarity
# classifier to veto :forbidden verdicts on curator-added headwords (so they
# survive long enough for the auto spelling-variant detectors in
# corpus_variants.rb to pair them with sibling forms).
def authoritative_pronunciation_words
  return $authoritative_pronunciation_words if $authoritative_pronunciation_words
  words = Set.new
  if File.exist?(AUTHORITATIVE_PRONUNCIATIONS_PATH)
    BuildIo.foreach(AUTHORITATIVE_PRONUNCIATIONS_PATH, encoding: "UTF-8", hint: "authoritative_pronunciation_words") do |line|
      next unless useful_cmudict_line?(line)
      line = preprocess_cmudict_line(line)
      tokens = line.split
      next if tokens.length < 2
      word = tokens.shift.downcase.desanitize
      word = word[0...-3] if word =~ /\([0-9]\)\Z/
      words.add(word)
    end
  end
  $authoritative_pronunciation_words = words
end

def load_cmudict()
  # word => [pronunciation1, pronunciation2 ...]
  # pronunciation = [syllable1, syllable1, ...]
  hash = Hash.new {|h,k| h[k] = [] } # hash of arrays
  authoritative_words = load_authoritative_pronunciations!(hash)
  cmu_overridden = 0
  BuildIo.foreach(CMUDICT_FILENAME, encoding: "UTF-8", hint: "merge_cmudict") { |line|
    if(useful_cmudict_line?(line))
      line = preprocess_cmudict_line(line)
      tokens = line.split
      word = tokens.shift.downcase # now TOKENS contains only syllables
      pron = Pronunciation.new(tokens)
      word = word.desanitize
      if(word =~ /\([0-9]\)\Z/)
        word = word[0...-3]
      end
      if authoritative_words.include?(word)
        cmu_overridden += 1
        dict_trace_puts(word, "Ignoring CMU pron (authoritative override): #{pron}") if dict_trace_word?(word)
        next
      end
      unless ignore_cmudict_word?(word, hash)
        # ignore nonstandard initial and final consonant clusters. They're mostly names and a handful of loan words, and they'll rhyme with nothing or just each other, so we lose little to nothing by excluding them.
        word_ok = true
        unless WHITELIST.include?(word)
          initial_cluster = pron.initial_consonant_cluster_array
          unless initial_consonant_cluster_ok?(initial_cluster)
            word_ok = false
            # puts "Ignoring weird initial consonant cluster: #{initial_cluster.join(" ")} in #{line}"
          end
          final_cluster = pron.final_consonant_cluster_array
          unless final_consonant_cluster_ok?(final_cluster)
            word_ok = false
            # puts "Ignoring weird final consonant cluster: #{final_cluster.join(" ")} in #{line}"
          end
        end
        if word_ok
          push_pronunciation_unless_duplicate!(hash[word], pron)
          dict_trace_puts(word, "Loaded flat as #{pron}") if dict_trace_word?(word)
        end
      else
        dict_trace_puts(word, "Ignoring word (CMU cluster/filter rejected)") if dict_trace_word?(word)
      end
    else
      puts "Ignoring cmudict line: #{line}" if DICT_BUILD_VERBOSE
    end
  }
  puts "Loaded #{hash.length} words from cmudict"
  dropped_expansions = drop_abbreviation_expansion_alternates!(hash)
  puts "Dropped #{dropped_expansions} abbreviation-expansion alternate pronunciations" if dropped_expansions > 0
  # filter out redundant apostrophe words: if we already have "foo", ignore "foo's" and "foos'"
  newhash = Hash.new
  for word, prons in hash do
    unless redundant_apostrophe_word?(word, hash)
      newhash[word] = prons
    end
  end
  puts "Filtered out #{hash.length - newhash.length} redundant apostrophe words"
  syllabified = Hash.new { |h, k| h[k] = [] }
  for word, flat_prons in newhash
    syllabified[word] = dedupe_pronunciations(
      flat_prons.map { |p| syllabify_with_common_prefix_split(word, p, newhash) }
    )
  end
  syllabified
end

def ignore_cmudict_word?(word, pronunciation_map)
  # ignore words containing digits, except w00t
  return true if (word =~ /\d/) && (word != "w00t")
  # ignore words containing a period anywhere: CMUDict uses dots for abbreviations,
  # both word-final (AL., CONN., CORP., JAN., MASS., REP., ST.) and mid-word (CORP.'S,
  # U.S., U.S.A., etc.). These are abbreviation spellings that shouldn't participate in
  # rhyming; the bare form (e.g. corp, rep) is already indexed when it legitimately rhymes.
  return true if word.include?(".")
  false
end

def initial_consonant_cluster_ok?(cluster)
  if(cluster.length <= 1)
    return true; # not a cluster
  else
    cluster_str = cluster.join(" ")
    return ALL_INITIAL_CONSONANT_CLUSTERS.include?(cluster_str) ||
           WORD_INITIAL_CONSONANT_CLUSTERS.include?(cluster_str)
  end
end

def final_consonant_cluster_ok?(cluster)
  if(cluster.length <= 1)
    return true; # not a cluster
  else
    cluster_str = cluster.join(" ")
    return ALL_FINAL_CONSONANT_CLUSTERS.include?(cluster_str)
  end
end

def redundant_apostrophe_word?(word, pronunciation_map)
  if word.include?("'") && !semantically_promiscuous?(word)
    root = word.tr("'", "")
    if(pronunciation_map.key?(root) && (pronunciation_map[root].sort == pronunciation_map[word].sort)) # if pronunciations are the same (ignoring order)
      return true
    end
  end
  false
end

def merge_wiktionary!(pronunciation_map, wiktionary)
  added = 0
  wiktionary.each do |word, prons|
    next if pronunciation_map.key?(word)
    next if ignore_cmudict_word?(word, pronunciation_map)
    valid_prons = prons.select do |pron|
      next false if pron.empty?
      next false unless pron.phonemes.any?(&:vowel?)
      word_ok = true
      unless WHITELIST.include?(word)
        word_ok = false unless initial_consonant_cluster_ok?(pron.initial_consonant_cluster_array)
        word_ok = false unless final_consonant_cluster_ok?(pron.final_consonant_cluster_array)
      end
      word_ok
    end
    next if valid_prons.empty?
    pronunciation_map[word] = dedupe_pronunciations(
      valid_prons.map { |p| syllabify_with_common_prefix_split(word, normalize_flat_arphabet_pronunciation(p), pronunciation_map) }
    )
    added += 1
  end
  puts "Merged #{added} new words from Wiktionary into pronunciation dict"
end
