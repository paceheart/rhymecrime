# encoding: utf-8
# frozen_string_literal: true

# CMU ingest, ARPAbet normalization, syllabification, Wiktionary pronunciation merge.

require_relative "utils_rhyme"
require_relative "phoneme.rb"
require_relative "pronunciation.rb"
require_relative "constants"

def delete_explicitly_forbidden_keys_from_hash(cmudict)
  count = 0
  for bad_word in forbid_list
    if(cmudict.delete(bad_word.chomp))
      count = count + 1
    end
  end
  puts "Removed #{count} explicitly_forbidden words from the dictionary"
end

# Incomplete / artifact headwords (e.g. truncated compounds); not useful as lookup keys.
def delete_headwords_with_edge_hyphen!(hash)
  n = 0
  hash.keys.each do |w|
    next unless w.start_with?("-") || w.end_with?("-")
    hash.delete(w)
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
  # (+normalize_flat_arphabet_pronunciation+).
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

  line
end

# Suffix replacements for imperfect-rhyme conflation; order must match +conflate_imperfect_rhyme_phoneme_string+.
CONFLATE_IMPERFECT_RHYME_SUFFIX_RULES = [
  [%w[L S], %w[L T S]], # else / melts
  [%w[M T], %w[M P T]], # dreamt / tempt
  [%w[N D Z], %w[N Z]], # funds / tons
  [%w[N S], %w[N T S]], # fence / scents
  [%w[T CH], %w[CH]],
  [%w[ZH], %w[JH]], # massage / lodge
  [%w[ZH AH0 Z], %w[JH AH0 Z]], # massages / lodges
  [%w[ZH D], %w[JH D]], # massaged / lodged
  [%w[ZH IY0 NG], %w[JH IY0 NG]], # massaging / lodging
  [%w[ZH AH0 R], %w[JH AH0 R]], # massager / lodger
  [%w[ZH AH0 R Z], %w[JH AH0 R Z]], # massagers / lodgers
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

# Flat phoneme lists for +stem+ (each stored pronunciation, dots stripped).
def flat_pron_sequences_for_word(flat_by_word, stem)
  (flat_by_word[stem] || []).map { |p| p.phonemes.reject { |ph| ph == "." } }
end

# If +word+ starts with a +COMMON_PREFIXES+ string and the stem exists in +flat_by_word+ with a
# flat pronunciation equal to the tail of +word+'s phones, insert one syllable boundary between
# prefix and stem. MOP alone often merges the last consonant of the prefix into the stem syllable
# (e.g. AH0 P EH1 N D → ə|ˈpend instead of ʌp|ˈɛnd). Do not call +syllabify+ on the merged string
# (avoids re-splitting and double dots). If no prefix+stem tail match, fall back to +syllabify+.
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
      return Pronunciation.new(prefix_flat + ["."] + stem_flat)
    end
  end
  normalized_flat_pron.syllabify
end

def conflate_imperfect_rhyme_phoneme_string(phoneme_space_string)
  conflate_imperfect_rhyme_phoneme_tokens(phoneme_space_string.split).join(" ")
end

def load_cmudict()
  # word => [pronunciation1, pronunciation2 ...]
  # pronunciation = [syllable1, syllable1, ...]
  hash = Hash.new {|h,k| h[k] = [] } # hash of arrays
  File.foreach(CMUDICT_FILENAME, encoding: "UTF-8") { |line|
    if(useful_cmudict_line?(line))
      line = preprocess_cmudict_line(line)
      tokens = line.split
      word = tokens.shift.downcase # now TOKENS contains only syllables
      pron = Pronunciation.new(tokens)
      word = word.desanitize
      if(word =~ /\([0-9]\)\Z/)
        word = word[0...-3]
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

def ignore_cmudict_word?(word, cmudict)
  # ignore words containing digits, except w00t
  (word =~ /\d/) && (word != "w00t")
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

def redundant_apostrophe_word?(word, cmudict)
  if word.include?("'") && !stop_word?(word)
    root = word.tr("'", "")
    if(cmudict.key?(root) && (cmudict[root].sort == cmudict[word].sort)) # if pronunciations are the same (ignoring order)
      return true
    end
  end
  false
end

def merge_wiktionary!(cmudict, wiktionary)
  added = 0
  wiktionary.each do |word, prons|
    next if cmudict.key?(word)
    next if ignore_cmudict_word?(word, cmudict)
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
    cmudict[word] = dedupe_pronunciations(
      valid_prons.map { |p| syllabify_with_common_prefix_split(word, normalize_flat_arphabet_pronunciation(p), cmudict) }
    )
    added += 1
  end
  puts "Merged #{added} new words from Wiktionary into pronunciation dict"
end
