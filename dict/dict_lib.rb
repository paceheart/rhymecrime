# encoding: utf-8
#
# RhymeCrime dictionary compiler: CMU + Wiktionary/kaikki + frequency phases → dict/generated/*.
# Loaded by dict.rb (CLI). Use require_relative 'dict_lib' with process cwd = dict/ so relative
# paths (cmudict/, WordNet3.1/, etc.) resolve. Defines rebuild_rhymecrime_dictionaries (no side
# effects on require).
#
# Change this to a string to display detailed output for a particular word
TRACE_WORD = nil

# Preprocess the cmudict data into a format that's efficient for looking up rhyming words.
# Reads from CMUDICT_FILENAME; writes generated caches under dict/generated/ (see utils_rhyme).
#
# cmudict is the CMU Pronouncing Dictionary, a text file with lines like this:
#  KITTEN  K IH1 T AH0 N
#  KITTENS  K IH1 T AH0 N Z
#  KITTERMAN  K IH1 T ER0 M AH0 N
#
# A word's rime (see Pronunciation#rime / #rime_array in pronunciation.rb).
# RhymeCrime uses a two-step lookup process to avoid storing lots of redundant data, e.g. all 500+ "-ation" rhymes as values for "elation", "consternation", etc.
# Step 1: Given a word, use the CMU Pronouncing Data to get its pronunciation.
# Step 1.1: Tweak the given pronunciation to deal with quirks of cmudict.
# Step 1.5: Get the word's rime (underscore-joined ARPABET key).
# Step 2: Given the rime, look up all words that rhyme with it (including itself)
# Step 2.5: Filter out bad rhymes, like the word itself and subwords (e.g. important rhyming with unimportant)
# build_rime_dict builds the dictionary used in Step 2.
#
# We could improve performance even more by assigning an arbitrary index 0..N
# to each rime, having a list of those be the keys for Dict 1, and
# having Step 2 be an array lookup instead of a hash lookup.

require 'rwordnet'
require 'json'
require 'set'
require_relative 'utils_rhyme'
require_relative 'phoneme.rb'
require_relative 'pronunciation.rb'
require_relative 'wiktionary'
require_relative 'inflect'

CMUDICT_FILENAME = "cmudict/cmudict-0.7c.txt"
RARE_WORDS_FILENAME = "rare_words.txt"
COMMON_WORDS_FILENAME = "common_words.txt"

WordNet::DB.path = "WordNet3.1/"
SUBTLEX_FILENAME = "subtlex/SUBTLEXus.tsv"
SUBTLEX_PRESENCE_BONUS = 4

WORDFREQ_FILENAME = "wordfreq/wordfreq.tsv"
WORDFREQ_COMMON_ZIPF = 3.0
WORDFREQ_RARE_ZIPF = 2.0
# SUBTLEX FREQlow this high means sustained lowercase dialogue use — used with weak_lemma_anchor
# and with two-letter all-proper handling below.
SUBTLEX_OVERRIDE_PROPER_MIN = 12
# Two-letter all-proper, single synset: only clear "all proper" when SUBTLEX FREQlow falls in
# this band — high enough for real dialogue (bi ~32) but below nickel-style fragment spam (ni)
# and above iron Fe appearing as dialogue junk (~17).
SUBTLEX_SINGLE_PROPER_OVERRIDE_MIN = 28
SUBTLEX_SINGLE_PROPER_OVERRIDE_MAX = 40
# Phase 11: minimum raw SUBTLEX FREQlow on a base before it may promote non-list inflections.
MORPH_CORPUS_SUBTLEX_MIN = 40
# Plural :s only: allow WN noun-only bases below the corpus floor when still attested in subtitles
# (e.g. gramophone SUBTLEX 15 → gramophones).
MORPH_LEXICAL_NOUN_PLURAL_SUBTLEX_MIN = 10
# Phase 6: skip weak Zipf for 4-letter tokens with no WordNet entry (surname spam ~2.3) but keep neologisms ≥ this (yeet ~2.51).
WIKT_FLOOR_4L_WEAK_ZIPF_BELOW = 2.5
RIME_DICT_HEADER = "# RhymeCrime's rime dictionary
# https://github.com/paceheart/rhymecrime
#
# Built by dict_lib.rb (CLI: dict/dict.rb).
#
# Each line is of the form:
#
# RIME  WORD1 WORD2 WORD3 ...
#
# where RIME is an underscore-concatenated ARPABET encoding of phonemes
# from the head vowel of the prosodic head through word end (see Pronunciation#rime_array).
#
# This data is automatically distilled from a forked version of the
# CMU Pronouncing Dictionary, with some manual tweaks and some
# programmatic preprocessing as described in dict_lib.rb.
#
# Singleton rimes are excluded.
#"

WORD_DICT_HEADER = "# RhymeCrime's word info dictionary
# https://github.com/paceheart/rhymecrime
#
# Built by dict_lib.rb (CLI: dict/dict.rb).
#
# Each line is of the form:
#
# WORD,FREQUENCY,PRONUNCIATION1|PRONUNCIATION2...
#
"

#
# parse cmudict
#

def delete_explicitly_forbidden_keys_from_hash(cmudict)
  count = 0
  for bad_word in forbid_list
    if(cmudict.delete(bad_word.chomp))
      count = count + 1
    end
  end
  puts "Removed #{count} explicitly_forbidden words from the dictionary"
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
  if TRACE_WORD && line.include?(TRACE_WORD) && line != original_line
    puts "TRACE Preprocessed #{original_line} to #{line}"
  end
  line
end

def gsub_unless_followed_by_r(line, old, new)
  # substitute OLD for NEW unless OLD is followed by " R"
  
  # Protect R from the upcoming gsub.
  line.gsub!(old + " R", "fubarduckR")

  line.gsub!(old, new)
  
  # put R back the way it was
  line.gsub!("fubarduckR", old + " R")
  return line
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
  line = gsub_unless_followed_by_r(line, " AO0", " AA0")
  line = gsub_unless_followed_by_r(line, " AO1", " AA1")
  line = gsub_unless_followed_by_r(line, " AO2", " AA2")

  line
end

# Flat ARPAbet pronunciation (no syllable dots): same pipeline as CMU phoneme tail after the headword.
def normalize_flat_arphabet_pronunciation(pron)
  return pron if pron.nil? || pron.empty?
  flat = pron.phonemes.reject { |p| p == "." }
  return pron if flat.empty?

  s = apply_shared_arphabet_phoneme_string_normalizations(flat.join(" "))
  p = Pronunciation.new(s.split).with_dwimmed_schwas
  s2 = conflate_imperfect_rhyme_phoneme_string(p.phonemes.join(" "))
  Pronunciation.new(s2.split).with_flapped_t
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
  # @todo allow this to be toggleable at runtime instead of dictionary-building time
  line = phoneme_space_string.dup
  line.gsub!(/ L S$/, ' L T S') # false / malts, else / melts. Sure I guess? Otherwise 'false' and 'else' won't rhyme with anything at all.
  line.gsub!(/ M T$/, ' M P T') # dreamt / tempt
  line.gsub!(/ N D Z$/, ' N Z') # tons [T AH1 N Z] / funds [F AH1 N D Z]
  line.gsub!(/ N S$/, ' N T S') # dance / ants
  line.gsub!(/ T CH$/, ' CH') # blotch / watch
  line.gsub!(/ ZH$/, ' JH') # massage [M AH0 S AA1 ZH] / dodge [D AA1 JH]
  line.gsub!(/ ZH AH0 Z$/, ' JH AH0 Z') # massages [M AH0 S AA1 ZH AH0 Z] / dodges [D AA1 JH IH0 Z]
  line.gsub!(/ ZH D$/, ' JH D') # massaged / dodged
  line.gsub!(/ ZH IY0 NG$/, ' JH IY0 NG') # massaging / dodging
  line.gsub!(/ ZH AH0 R$/, ' JH AH0 R') # massager / dodger
  line.gsub!(/ ZH AH0 R Z$/, ' JH AH0 R Z') # massagers / dodgers
  line
end

def load_cmudict()
  # word => [pronunciation1, pronunciation2 ...]
  # pronunciation = [syllable1, syllable1, ...]
  hash = Hash.new {|h,k| h[k] = [] } # hash of arrays
  IO.readlines(CMUDICT_FILENAME, encoding: 'UTF-8').each{ |line|
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
          if(word == TRACE_WORD)
            puts "TRACE Loaded #{word} flat as #{pron}"
          end
        end
      else
        puts "Ignoring word: #{word}"
      end
    else
      puts "Ignoring cmudict line: #{line}"
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

#
# SUBTLEX-US (movie subtitle corpus, 51M words, 74K unique word forms)
# Source: Brysbaert & New (2009), full TSV from openlexicon.fr
# We use FREQlow (lowercase occurrences only) to avoid counting
# sentence-initial capitalization and proper noun uses.
#

def load_subtlex()
  subtlex_hash = Hash.new(0)
  first = true
  IO.readlines(SUBTLEX_FILENAME, encoding: 'UTF-8').each do |line|
    if first
      first = false
      next
    end
    fields = line.chomp.split("\t")
    word_lower = fields[0].downcase
    freq_low = fields[3].to_i
    subtlex_hash[word_lower] = freq_low if freq_low > subtlex_hash[word_lower]
  end
  puts "Loaded #{subtlex_hash.length} words from SUBTLEX-US"
  return subtlex_hash
end

def subtlex_frequency(word, subtlex_hash)
  count = subtlex_hash[word]
  return 0 if count == 0
  SUBTLEX_PRESENCE_BONUS + Math.log2(count).round
end

#
# wordfreq (frozen 2021, aggregates Wikipedia/Reddit/Twitter/OpenSubtitles/Common Crawl)
#

def load_wordfreq()
  wordfreq_hash = Hash.new
  unless File.exist?(WORDFREQ_FILENAME)
    puts "Warning: #{WORDFREQ_FILENAME} not found, skipping wordfreq"
    return wordfreq_hash
  end
  File.foreach(WORDFREQ_FILENAME, encoding: 'UTF-8') do |line|
    word, zipf_str = line.chomp.split("\t")
    next if word.nil? || zipf_str.nil?
    wordfreq_hash[word] = zipf_str.to_f
  end
  puts "Loaded #{wordfreq_hash.length} words from wordfreq"
  wordfreq_hash
end

#
# WordNet
#

def wn_all_proper?(word)
  lemmas = WordNet::Lemma.find_all(word)
  lookup_word = word
  return false if lemmas.empty?
  found_any_word = false
  lemmas.each { |l|
    l.synsets.each { |synset|
      matching = synset.words.select { |w| w.downcase.tr('_', ' ') == lookup_word }
      next if matching.empty?
      found_any_word = true
      return false unless matching.all? { |w| w[0] != w[0].downcase }
    }
  }
  found_any_word
end

def wn_frequency(word)
  all_proper = wn_all_proper?(word)
  if(word == TRACE_WORD)
    puts "TRACE wn_frequency: all_proper=#{all_proper}"
  end
  return 0, all_proper
end

# 2-3 letter lowercase tokens are often initialisms (BBC, NBA). For Zipf>=3 we also treat
# 4-letter all-alpha tokens as acronym-like (IMAX-style in corpora) when there is no SUBTLEX
# and no WordNet lemma. 5-letter words are excluded — they are often real lexemes missing
# from older resources (e.g. emoji). (Four-letter policy may be revisited separately.)
def short_initialism_shape?(word)
  word.match?(/\A[a-z]{2,3}\z/)
end

def two_letter_alpha?(word)
  word.match?(/\A[a-z]{2}\z/)
end

def four_letter_alpha?(word)
  word.match?(/\A[a-z]{4}\z/)
end

def wn_synset_count(word)
  lemmas = WordNet::Lemma.find_all(word)
  return 0 if lemmas.empty?
  lemmas.sum { |l| l.synsets.size }
end

def acronym_shape_wordfreq_only?(word)
  word.match?(/\A[a-z]{2,4}\z/)
end

def wn_has_entry?(word)
  !WordNet::Lemma.find_all(word).empty?
end

# True if WordNet lists the base as a verb (any sense). Used to avoid Phase 8 giving
# noun-only stems a bogus verbal -ing frequency (kitchening, crotching, jealousing).
# Bases with no WordNet entry still return true so modern verbs (twerk) can inherit.
def wn_base_has_verb?(base)
  lemmas = WordNet::Lemma.find_all(base)
  return true if lemmas.empty?
  lemmas.any? { |l| l.pos == "v" }
end

def wn_base_has_adjective?(base)
  lemmas = WordNet::Lemma.find_all(base)
  return true if lemmas.empty?
  lemmas.any? { |l| l.pos == "a" }
end

def wn_base_has_noun?(base)
  lemmas = WordNet::Lemma.find_all(base)
  return true if lemmas.empty?
  lemmas.any? { |l| l.pos == "n" }
end

# WordNet lemma +pos+ codes → strings stored with Kaikki data (part_of_speech.json).
WN_POS_TO_LEXICAL_POS = {
  "n" => "noun",
  "v" => "verb",
  "a" => "adj",
  "s" => "adj", # satellite adjective
  "r" => "adv",
}.freeze

# Kaikki-style POS tags WordNet lists for this spelling (coarse noun / verb / adj / adv).
def wordnet_lexical_pos_set(word)
  lemmas = WordNet::Lemma.find_all(word)
  return Set.new if lemmas.empty?
  out = Set.new
  lemmas.each do |lem|
    mapped = WN_POS_TO_LEXICAL_POS[lem.pos]
    out.add(mapped) if mapped
  end
  out
end

# Layer A: intersect Kaikki’s POS union with WordNet’s coarse POS for the same surface form.
# Words with no WordNet lemmas keep the full Kaikki set (OOV / neologisms). Morph phases use the
# same +pos_map+ after this pass.
def apply_lexical_pos_layer_a!(pos_map)
  pos_map.each do |word, kaikki_set|
    next if kaikki_set.nil? || kaikki_set.empty?
    next unless wn_has_entry?(word)
    wn_set = wordnet_lexical_pos_set(word)
    next if wn_set.empty?
    pos_map[word] = kaikki_set & wn_set
  end
  nil
end

def morph_part_of_speech_tags(pos_map, base)
  s = pos_map[base]
  return [] if s.nil? || s.empty?
  s.to_a
end

# Kaikki listed this exact surface as an inflected form of +base+ (+collect_inflected_forms+).
def wiktionary_surface_form_attested?(forms_map, base, inflected)
  pairs = forms_map[base]
  return false if pairs.nil? || pairs.empty?
  pairs.any? { |form, b| form == inflected && b == base }
end

# -ed/-ing: Kaikki +verb+ when present; cross-check WordNet so noun-only lemmas do not inherit
# verbal junk (FP-4). When both Kaikki and WordNet agree the base is a verb, require a Kaikki
# surface row. If Kaikki also lists +adj+ on the lemma, require Wordfreq Zipf on the inflected
# surface so lexicon rows for marginal verbs (e.g. *taboo*) do not promote rare *tabooed* when
# corpus use is negligible. OOV bases (no WordNet entry) keep the legacy open policy.
def morph_base_allows_verb_forms?(base, inflected, pos_map, forms_map, zipf_inf)
  sk = Inflect.send(:match_suffix_kind, base, inflected)
  return true unless sk == :ed || sk == :ing

  tags = morph_part_of_speech_tags(pos_map, base)
  wn_in = wn_has_entry?(base)
  wn_v = wn_base_has_verb?(base)

  if tags.any?
    return false unless tags.include?("verb")
    return false if wn_in && !wn_v
    if wn_in && wn_v
      return false unless wiktionary_surface_form_attested?(forms_map, base, inflected)
      return zipf_inf >= WORDFREQ_RARE_ZIPF if tags.include?("adj")
      return true
    end
    return true
  end
  wn_v
end

def pronunciation_vowel_phoneme_count(pron)
  return 0 if pron.nil? || pron.empty?
  pron.phonemes.count { |ph| !ph.syllable_boundary? && ph.vowel? }
end

def silent_e_stem_plus_er?(base, w)
  bl = base.bytesize
  return false unless base.end_with?("e") && bl >= 2 && !base.end_with?("ee")
  w == base.byteslice(0, bl - 1) + "er"
end

# Blocks *happyer; allows *happier. Non-+y+: adjective (Kaikki or WN) with phonological / attestation
# rules. Silent-e stem+*er* (*service*→*servicer*) is allowed when the base is verbal and the
# derived form has independent Zipf (blocks *oranger*-style junk while keeping attested agents).
def morph_base_allows_comparative_er_est?(base, w, pos_map, base_first_pron, forms_map, zipf_w)
  sk = Inflect.send(:match_suffix_kind, base, w)
  return true unless sk == :er || sk == :est

  bl = base.bytesize
  if base.end_with?("y") && bl >= 2
    stem = base.byteslice(0, bl - 1)
    return false if w == base + "er" || w == base + "est"
    return true if w == stem + "ier" || w == stem + "iest"
    return false
  end

  if sk == :er && silent_e_stem_plus_er?(base, w)
    tags = morph_part_of_speech_tags(pos_map, base)
    zip_ok = zipf_w >= WORDFREQ_RARE_ZIPF
    verbal_nouny = if tags.any?
      tags.include?("verb") && tags.include?("noun")
    else
      wn_base_has_verb?(base) && wn_base_has_noun?(base)
    end
    if verbal_nouny && (!tags.any? || !tags.include?("adj") || zip_ok)
      return true if zip_ok || wiktionary_surface_form_attested?(forms_map, base, w)
    end
  end

  tags = morph_part_of_speech_tags(pos_map, base)
  adj_ok = tags.any? ? tags.include?("adj") : wn_base_has_adjective?(base)
  return false unless adj_ok

  vc = pronunciation_vowel_phoneme_count(base_first_pron)
  attested = wiktionary_surface_form_attested?(forms_map, base, w)
  if tags.any?
    return true if vc <= 1
    attested
  else
    return true if vc <= 2
    attested
  end
end

# Plural *:s*: Kaikki +noun+ when present; WordNet noun cross-check. When Kaikki lists both +adj+
# and +noun+ on the same lemma, require a Kaikki form row for that plural (blocks *impromptus*
# while keeping productive plurals for noun-only Kaikki rows like *gramophone*→*gramophones*).
def morph_base_allows_plural_s?(base, pos_map, forms_map, plural_word)
  tags = morph_part_of_speech_tags(pos_map, base)
  if tags.any?
    return false unless tags.include?("noun")
    return false if wn_has_entry?(base) && !wn_base_has_noun?(base)
    if tags.include?("adj")
      return wiktionary_surface_form_attested?(forms_map, base, plural_word)
    end
    return true
  end
  true
end

#
# put it all together
#

def build_rime_dict(cmudict)
  rdict = Hash.new {|h,k| h[k] = [] } # hash of arrays, each element of which is a Pronunciation
  i = 0;
  for word, prons in cmudict
    for pron in prons
      rime = pron.rime
      rdict[rime].push(word)
    end
    i = i + 1;
  end
  # sort, and remove duplicate words
  for rime, words in rdict
    new_words = words.sort.uniq
    if(new_words.nil?)
      rdict.delete(rime)
    else
      rdict[rime] = new_words
    end
  end
  print "Identified #{rdict.length} unique rimes, "
  rdict = rdict.reject!{|rime, words| words.length <= 1 }
  puts "#{rdict.length} of which are nonempty"
  return rdict
end

# Word_dict gains pronunciations from frequency phases (e.g. morph promotion) that never appear in
# cmudict; runtime rhyme lookup uses rdict, so those words must be indexed here too.
def merge_word_dict_pronunciations_into_rdict!(rdict, word_dict)
  word_dict.each do |word, (_freq, prons)|
    next if prons.empty?
    prons.each do |pron|
      rime = pron.rime
      next if rime.empty?
      (rdict[rime] ||= []) << word
    end
  end
  rdict.each do |rime, words|
    rdict[rime] = words.sort.uniq
  end
  rdict.reject! { |_rime, words| words.length <= 1 }
  rdict
end

def filter_cmudict(cmudict, rdict)
  # filter out words that differ only in apostrophes, and pronunciations with no rhymes
  filtered_cmudict = Hash.new
  proncount = 0
  total = 0
  for word, prons in cmudict
    filtered_cmudict[word] = Array.new # we still want entries for words with no pronunciations, though, in case they have frequency data
    if(word == TRACE_WORD)
      puts "TRACE prons = #{prons}"
    end
    for pron in prons
      total += 1
      rime = pron.rime
      if(!rdict[rime].empty?)
        proncount += 1
        filtered_cmudict[word].push(pron)
        if(word == TRACE_WORD)
          puts "TRACE #{pron} passed filters because it rhymes with #{rdict[rime]}"
        end
      end
    end
  end
  puts "#{proncount} out of #{total} pronunciations remain in the dictionary after removing pronunciations with no rhymes"
  return filtered_cmudict
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

def filter_word_dict(word_dict)
  filtered_word_dict = Hash.new
  for word, entry in word_dict
    freq, prons = entry
    if(!prons.empty? || freq > 0)
      filtered_word_dict[word] = entry
      if(word == TRACE_WORD)
        puts "TRACE freq #{freq} passed filters"
      end
    end
  end
  puts "#{filtered_word_dict.length} out of #{word_dict.length} entries remain in the dictionary after removing words with no rhymes and zero frequency"
  return filtered_word_dict
end

def compute_frequency(word, subtlex_hash, wordfreq_hash)
  _, wn_all_proper = wn_frequency(word)
  in_wordnet = wn_has_entry?(word)
  sub_raw = subtlex_hash[word] || 0
  zipf = wordfreq_hash[word] || 0
  syn_n = wn_synset_count(word)

  # Two-letter all-proper: usually chemical/state abbreviations in WordNet (Al, Bi, AL).
  # Multiple synsets → keep 0 (al, ba). Single synset → only trust subtitles below a ceiling
  # so bi can score as dialogue while ni stays 0 despite fragment counts.
  if wn_all_proper && two_letter_alpha?(word)
    return 0 if syn_n >= 2
    return 0 if syn_n == 1 && sub_raw >= SUBTLEX_SINGLE_PROPER_OVERRIDE_MAX
    if syn_n == 1 && sub_raw >= SUBTLEX_SINGLE_PROPER_OVERRIDE_MIN && sub_raw < SUBTLEX_SINGLE_PROPER_OVERRIDE_MAX
      wn_all_proper = false
    elsif syn_n == 1
      return 0
    end
  end

  return 0 if wn_all_proper

  # e.g. atm: WordNet lemma + high Zipf but almost no lowercase subtitle hits — encyclopedic initialism.
  weak_lexical_anchor = short_initialism_shape?(word) && in_wordnet && sub_raw < SUBTLEX_OVERRIDE_PROPER_MIN && zipf >= WORDFREQ_COMMON_ZIPF

  lexically_anchored = in_wordnet && !weak_lexical_anchor

  subtlex_freq = subtlex_frequency(word, subtlex_hash)
  if zipf > 0 && zipf < WORDFREQ_RARE_ZIPF && subtlex_freq > 4
    subtlex_freq = 4
  end

  # Without a lexical anchor, high Zipf often reflects encyclopedic/person-name hits; do not let
  # SUBTLEX alone push past the rare threshold (e.g. nam ~ Viet Nam fragments in subtitles).
  if !lexically_anchored && zipf >= WORDFREQ_COMMON_ZIPF
    subtlex_freq = [subtlex_freq, 4].min
  end

  block_short_initialism_wordfreq = acronym_shape_wordfreq_only?(word) && subtlex_freq == 0 && !in_wordnet
  wordfreq_boost = (zipf >= WORDFREQ_COMMON_ZIPF && !block_short_initialism_wordfreq) ? 5 : 0

  # Zipf-only boost with no anchor and zero SUBTLEX FREQlow: usually Wikipedia names (graeme, platt).
  if !lexically_anchored && sub_raw == 0
    wordfreq_boost = 0
  end

  # Short initialism-shaped strings with high Zipf but no anchor: treat Zipf as noisy.
  if !lexically_anchored && short_initialism_shape?(word) && zipf >= WORDFREQ_COMMON_ZIPF
    wordfreq_boost = 0
  end

  freq = [subtlex_freq, wordfreq_boost].max

  if(word == TRACE_WORD)
    puts "TRACE compute_frequency: subtlex=#{subtlex_freq} zipf=#{zipf} wordfreq_boost=#{wordfreq_boost} block_short_init=#{block_short_initialism_wordfreq} all_proper=#{wn_all_proper} => #{freq}"
  end
  return freq
end

def add_frequency_info(cmudict, subtlex_hash, wordfreq_hash, wiktionary_words, pos_map, forms_map)
  count = 0
  hash = Hash.new
  rare_words = IO.readlines(RARE_WORDS_FILENAME, chomp: true, encoding: 'UTF-8')
  common_words = IO.readlines(COMMON_WORDS_FILENAME, chomp: true, encoding: 'UTF-8')
  for word, prons in cmudict
    if(stop_word?(word))
      freq = 999999
    elsif(common_words.include?(word))
      freq = 99
    elsif(rare_words.include?(word))
      freq = 0
    else
      freq = compute_frequency(word, subtlex_hash, wordfreq_hash)
    end
    if(freq > 0)
      count += 1
    end
    hash[word] = [freq, prons]
  end
  puts "#{count} of those entries have frequency data (from cmudict/wiktionary words)"

  # Phase 4: add words from SUBTLEX that aren't in cmudict.
  extra = 0
  subtlex_hash.each_key do |word|
    next if hash.key?(word)
    next unless word.match?(/\A[a-z]([a-z'\-]*[a-z])?\z/)
    if(stop_word?(word))
      freq = 999999
    elsif(common_words.include?(word))
      freq = 99
    elsif(rare_words.include?(word))
      freq = 0
    else
      freq = compute_frequency(word, subtlex_hash, wordfreq_hash)
    end
    if freq > 0
      hash[word] = [freq, []]
      extra += 1
    end
  end
  puts "#{extra} extra words added from SUBTLEX (not in cmudict)"

  # Phase 5: add words from common_words.txt not already in the dict.
  common_extra = 0
  common_words.each do |word|
    next if hash.key?(word)
    hash[word] = [99, []]
    puts "  Added #{word} to the dictionary with frequency 99"
    common_extra += 1
  end
  puts "#{common_extra} extra words added from common_words.txt" if common_extra > 0

  # Phase 6: Wiktionary floor for modern words absent from all traditional corpora, e.g. throuple, yeet.
  # Require Zipf >= RARE to avoid junk words
  floor_applied = 0
  hash.each do |word, entry|
    next if entry[0] > 4
    next if rare_words.include?(word)
    next unless wiktionary_words.include?(word)
    zipf = wordfreq_hash[word] || 0
    next unless zipf >= WORDFREQ_RARE_ZIPF
    next if subtlex_hash[word] > 0
    next if wn_has_entry?(word)
    # Four-letter Wiktionary junk: Zipf in [RARE, 2.5) with no WN/SUBTLEX — surnames (~stam);
    # at/above 2.5 keep the floor for neologisms (yeet).
    next if four_letter_alpha?(word) && zipf >= WORDFREQ_RARE_ZIPF && zipf < WIKT_FLOOR_4L_WEAK_ZIPF_BELOW
    next if short_initialism_shape?(word) && subtlex_hash[word] <= 0
    # 2-4 letter strings with strong wordfreq but no lexical anchor: skip floor so
    # IMAX/DVD-style tokens stay rare; Zipf < 3 keeps yeet
    next if acronym_shape_wordfreq_only?(word) && subtlex_hash[word] <= 0 && !wn_has_entry?(word) && zipf >= WORDFREQ_COMMON_ZIPF
    entry[0] = 5
    floor_applied += 1
  end
  puts "#{floor_applied} words received Wiktionary existence floor" if floor_applied > 0

  # Phase 7: Hyphenated word existence floor.
  # SUBTLEX and wordfreq tokenize on hyphens, so hyphenated words systematically score 0.
  # Grant floor when the compound is attested (Wiktionary headword or WordNet MWE) and
  # the final segment is not independently useful for rhyming: no WordNet lemma, and raw SUBTLEX < 12.
  # Skip inflected forms of hyphenated bases — those are handled by Phase 8 (or blocked).
  hyp_floor = 0
  hash.each do |word, entry|
    next if entry[0] > 4
    next if rare_words.include?(word)
    next unless word.include?('-')
    next if $inflection_base_words.key?(word) && $inflection_base_words[word].include?('-')
    next unless wiktionary_words.include?(word) || wn_has_entry?(word)
    final = word.split('-').last
    next if wn_has_entry?(final)
    next if subtlex_hash[final] >= 12
    entry[0] = 5
    hyp_floor += 1
  end
  puts "#{hyp_floor} hyphenated words received existence floor" if hyp_floor > 0

  # Phase 8: frequency inheritance for inflected forms.
  # Inherit from any common base word. Skip only when wordfreq shows the inflection itself
  # as independently common (Zipf >= COMMON); a mere corpus key with low Zipf still inherits
  # (yeeted, twerks) so slang bases propagate.
  # Skip -ing → base when WordNet has the base but only as noun/adj/etc.: prevents
  # spurious "kitchening" inheriting from "kitchen" (FP-4). Verbal -ing still inherits
  # when the base has a verb lemma, or when the base is absent from WordNet (slang).
  inherited = 0
  $inflection_base_words.each do |inflected, base|
    next unless hash.key?(inflected)
    next if hash[inflected][0] > 0
    # Do not copy frequency from hyphenated base to hyphenated inflection (hoity-toity → hoity-toities).
    next if inflected.include?("-") && base.include?("-")
    base_freq = hash.key?(base) ? hash[base][0] : 0
    next unless base_freq > 4
    wf_inf = wordfreq_hash[inflected]
    next if wf_inf && wf_inf >= WORDFREQ_COMMON_ZIPF
    sk8 = Inflect.send(:match_suffix_kind, base, inflected)
    next if sk8 == :s && !morph_base_allows_plural_s?(base, pos_map, forms_map, inflected)
    zf_w = wordfreq_hash[inflected] || 0
    next if (sk8 == :ed || sk8 == :ing) && !morph_base_allows_verb_forms?(base, inflected, pos_map, forms_map, zf_w)
    if sk8 == :er || sk8 == :est
      base_p0 = hash[base]&.dig(1)&.first
      next unless morph_base_allows_comparative_er_est?(base, inflected, pos_map, base_p0, forms_map, zf_w)
    end
    hash[inflected][0] = base_freq
    inherited += 1
  end
  puts "#{inherited} inflected forms inherited frequency from base words" if inherited > 0

  # Phase 9: suffix inheritance from common_words.txt (Inflect spelling patterns).
  # Phase 8 only fills entries with frequency 0; listed headwords still leave plurals / -ing, etc.
  # in the rare bins (1–4). Match forward (listed + suffix = word) or reverse (word + suffix = listed,
  # e.g. regionalize… ← regionalized). No wordfreq / WN verb guards here — the list is authoritative.
  cw_sorted = common_words.uniq.sort_by { |b| -b.length }
  cw_inherited = 0
  # Multiple rounds: e.g. regionalized → regionalize → regionalizing in one build.
  loop do
    round = 0
    hash.each do |word, entry|
      next if entry[0] > 4
      next if rare_words.include?(word)
      cw_sorted.each do |listed|
        next if listed == word
        forward = Inflect.inflection_of_base?(listed, word)
        reverse = !forward && Inflect.inflection_of_base?(word, listed)
        next unless forward || reverse
        listed_freq = hash.key?(listed) ? hash[listed][0] : 0
        donor = listed_freq > 4 ? listed_freq : 99
        entry[0] = donor
        round += 1
        cw_inherited += 1
        break
      end
    end
    break if round == 0
  end
  puts "#{cw_inherited} forms inherited frequency from common_words.txt bases" if cw_inherited > 0

  # Phase 10: morphological extensions from common_words.txt headwords only (Inflect matcher).
  # Unlike an “any freq>4 lemma” scan, this avoids promoting foxed/gooses/bruisers from ordinary
  # common nouns and avoids hyphenated blast (topsy-turvy → topsy-turvys).
  # OOV rows: list headwords are authoritative (no SUBTLEX/Wikt gate). Existing keys may be raised.
  # -ing from a base requires a WordNet verb lemma (same FP-4 guard as Phase 8).
  morph_inherited = 0
  loop do
    round = 0
    # Snapshot keys so new OOV entries do not disturb this pass; multi-round picks them up as donors.
    hash.keys.each do |base|
      bent = hash[base]
      next unless bent && bent[0] > 4
      next unless common_words.include?(base)
      next if stop_word?(base)
      next if rare_words.include?(base)
      next if base.include?("-")
      donor = bent[0] > 4 ? bent[0] : 99
      base_prons = bent[1]
      Inflect.each_derivable_form(base) do |w|
        next if w == base
        next if w.include?("-")
        next if rare_words.include?(w)
        next unless Inflect.inflection_of_base?(base, w)
        sk10 = Inflect.send(:match_suffix_kind, base, w)
        wf = wordfreq_hash[w] || 0
        next if sk10 == :s && !morph_base_allows_plural_s?(base, pos_map, forms_map, w)
        next if (sk10 == :ed || sk10 == :ing) && !morph_base_allows_verb_forms?(base, w, pos_map, forms_map, wf)
        if sk10 == :er || sk10 == :est
          next unless morph_base_allows_comparative_er_est?(base, w, pos_map, base_prons&.first, forms_map, wf)
        end
        next if wf >= WORDFREQ_COMMON_ZIPF
        if hash.key?(w)
          next if hash[w][0] > 4
          hash[w][0] = donor
          if hash[w][1].empty?
            promo = morph_derived_prons_for_promotion(base_prons, base, w)
            hash[w][1] = promo unless promo.empty?
          end
        else
          hash[w] = [donor, morph_derived_prons_for_promotion(base_prons, base, w)]
        end
        round += 1
        morph_inherited += 1
      end
    end
    break if round == 0
  end
  puts "#{morph_inherited} morphological extensions inherited from freq>4 bases" if morph_inherited > 0

  # Phase 11: non-list bases with strong SUBTLEX dialogue use may promote attested inflections.
  # Tighter than old “any freq>4”: no hyphen, min length; plural :s can also use a lower SUBTLEX
  # floor when WordNet has the base as noun-only (gramophone → gramophones); blocks gooses-style
  # verbal plurals via wn_base_has_verb?. Non-plural suffixes still require MORPH_CORPUS_SUBTLEX_MIN.
  morph_corpus = 0
  loop do
    round = 0
    hash.keys.each do |base|
      next if common_words.include?(base)
      next if base.include?("-")
      bent = hash[base]
      next unless bent && bent[0] > 4
      next if stop_word?(base) || rare_words.include?(base)
      next if base.bytesize < 5
      sub_raw = subtlex_hash[base] || 0
      corpus_ok = sub_raw >= MORPH_CORPUS_SUBTLEX_MIN
      lexical_plural_ok = wn_has_entry?(base) && !wn_base_has_verb?(base) &&
        sub_raw >= MORPH_LEXICAL_NOUN_PLURAL_SUBTLEX_MIN
      next unless corpus_ok || lexical_plural_ok
      donor = bent[0] > 4 ? bent[0] : 99
      base_prons = bent[1]
      Inflect.each_derivable_form(base) do |w|
        next if w == base || w.include?("-") || rare_words.include?(w)
        next unless Inflect.inflection_of_base?(base, w)
        sk = Inflect.send(:match_suffix_kind, base, w)
        next unless sk
        wf = wordfreq_hash[w] || 0
        next if sk == :s && !morph_base_allows_plural_s?(base, pos_map, forms_map, w)
        next if (sk == :ed || sk == :ing) && !morph_base_allows_verb_forms?(base, w, pos_map, forms_map, wf)
        if sk == :er || sk == :est
          next unless morph_base_allows_comparative_er_est?(base, w, pos_map, base_prons&.first, forms_map, wf)
        end
        next if wf >= WORDFREQ_COMMON_ZIPF
        if sk == :s
          next unless hash.key?(w)
          next if wn_base_has_verb?(base)
          next if hash[w][0] > 4
          next unless corpus_ok || lexical_plural_ok
          hash[w][0] = donor
          if hash[w][1].empty?
            promo = morph_derived_prons_for_promotion(base_prons, base, w)
            hash[w][1] = promo unless promo.empty?
          end
        elsif corpus_ok
          if hash.key?(w)
            next if hash[w][0] > 4
            hash[w][0] = donor
            if hash[w][1].empty?
              promo = morph_derived_prons_for_promotion(base_prons, base, w)
              hash[w][1] = promo unless promo.empty?
            end
          else
            hash[w] = [donor, morph_derived_prons_for_promotion(base_prons, base, w)]
          end
        else
          next
        end
        round += 1
        morph_corpus += 1
      end
    end
    break if round == 0
  end
  puts "#{morph_corpus} morphological extensions from strong-corpus bases (not in common_words list)" if morph_corpus > 0

  forbidden_scrub = 0
  hash.keys.each do |word|
    next unless explicitly_forbidden?(word)
    hash.delete(word)
    forbidden_scrub += 1
  end
  puts "#{forbidden_scrub} explicitly forbidden surface forms removed after frequency phases" if forbidden_scrub > 0

  puts "#{count + extra + common_extra + floor_applied + hyp_floor + inherited + cw_inherited + morph_inherited + morph_corpus} total entries with frequency data"
  return hash
end

def build_word_dict(cmudict, rdict, subtlex_hash, wordfreq_hash, wiktionary_words, pos_map, forms_map)
  cmudict = filter_cmudict(cmudict, rdict)
  word_dict = add_frequency_info(cmudict, subtlex_hash, wordfreq_hash, wiktionary_words, pos_map, forms_map)
  return filter_word_dict(word_dict)
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

# Syllabified pronunciation for +inflected_word+ from +base_word+'s first CMU pron, or nil.
# Same final-cluster whitelist gate as merge_inflected_forms! (Phase 10/11 morph promotion).
def morph_derived_syllabified_pronunciation(base_pron, base_word, inflected_word)
  derived = Inflect.derive(base_pron, base_word, inflected_word)
  return nil if derived.nil? || derived.empty?
  return nil unless derived.phonemes.any?(&:vowel?)
  syllabified = normalize_flat_arphabet_pronunciation(derived).syllabify
  unless WHITELIST.include?(inflected_word)
    return nil unless final_consonant_cluster_ok?(syllabified.final_consonant_cluster_array)
  end
  syllabified
end

def morph_derived_prons_for_promotion(base_prons, base_word, inflected_word)
  return [] if base_prons.nil? || base_prons.empty?
  syll = morph_derived_syllabified_pronunciation(base_prons.first, base_word, inflected_word)
  syll ? [syll] : []
end

def merge_inflected_forms!(cmudict, forms_map)
  added = 0
  forms_map.each do |base_word, form_pairs|
    base_prons = cmudict[base_word]
    next if base_prons.nil? || base_prons.empty?

    base_pron = base_prons.first
    form_pairs.each do |inflected_word, _|
      next if cmudict.key?(inflected_word)
      next if ignore_cmudict_word?(inflected_word, cmudict)

      syllabified = morph_derived_syllabified_pronunciation(base_pron, base_word, inflected_word)
      next if syllabified.nil?

      cmudict[inflected_word] = [syllabified]
      added += 1
    end
  end
  puts "Generated #{added} inflected-form pronunciations"
end

# Suffixes on +stem+us+ for *us → *al promotion (Latin/medical morphology). Not every *us word: we
# exclude coincidences like campus/campal by requiring +campus+ only when +stem_us+ != "campus"
# (e.g. hippocampus → hippocampal).
US_TO_AL_STEM_US_SUFFIXES = %w[
  itus
  atus
  icus
  virus
  coccus
  iscus
].freeze

def stem_us_eligible_for_us_to_al_promotion?(stem_us)
  return true if US_TO_AL_STEM_US_SUFFIXES.any? { |sfx| stem_us.end_with?(sfx) }
  stem_us.end_with?("ampus") && stem_us != "campus"
end

# For lemmas like +coital+ attested in frequency data but missing from CMU/Kaikki: if +stem+us+ is
# already pronounceable and the final segment is /s/, derive +stem+al+ by replacing that /s/ with /l/
# (coitus → coital). Only runs for +al+ spellings that appear in +attested_words+ (SUBTLEX/wordfreq)
# and when +stem_us+ matches +US_TO_AL_STEM_US_SUFFIXES+ (or compound *ampus except campus).
def promote_us_to_al_pronunciations!(cmudict, attested_words)
  added = 0
  seen = Set.new
  Array(attested_words).each do |raw|
    w = raw.to_s.downcase.strip
    next if w.empty? || seen.include?(w)
    seen.add(w)
    next unless w.end_with?("al")
    stem_al = w.sub(/al\z/, "")
    stem_us = stem_al + "us"
    next unless stem_us_eligible_for_us_to_al_promotion?(stem_us)
    next if cmudict.key?(w)
    base_prons = cmudict[stem_us]
    next if base_prons.nil? || base_prons.empty?

    derived = []
    base_prons.each do |syl_pron|
      flat = syl_pron.phonemes.reject { |p| p == "." }
      next if flat.empty?
      last = flat.last
      next unless last.tr("0-2", "") == "S"
      new_flat = flat[0..-2] + ["L"]
      p = Pronunciation.new(new_flat)
      norm = normalize_flat_arphabet_pronunciation(p).syllabify
      next unless norm.phonemes.any?(&:vowel?)
      unless WHITELIST.include?(w)
        next unless final_consonant_cluster_ok?(norm.final_consonant_cluster_array)
        next unless initial_consonant_cluster_ok?(norm.initial_consonant_cluster_array)
      end
      derived << norm
    end
    derived = dedupe_pronunciations(derived)
    next if derived.empty?

    cmudict[w] = derived
    added += 1
  end
  puts "Promoted #{added} *us→*al pronunciations for attested *al lemmas" if added.positive?
end

$inflection_base_words = {}

def rebuild_rhymecrime_dictionaries()
  cmudict = load_cmudict
  wiktionary_prons, forms_map, pos_map = load_wiktionary
  apply_lexical_pos_layer_a!(pos_map)
  save_part_of_speech_map(pos_map)
  merge_wiktionary!(cmudict, wiktionary_prons)
  merge_inflected_forms!(cmudict, forms_map)
  subtlex_hash = load_subtlex
  wordfreq_hash = load_wordfreq
  promote_us_to_al_pronunciations!(cmudict, subtlex_hash.keys.to_a + wordfreq_hash.keys.to_a)
  # Track which words are inflected forms for frequency inheritance
  forms_map.each do |base_word, form_pairs|
    form_pairs.each do |inflected_word, base|
      $inflection_base_words[inflected_word] = base if cmudict.key?(inflected_word)
    end
  end
  # Build set of all words with Wiktionary presence (for existence floor)
  wiktionary_words = Set.new(wiktionary_prons.keys)
  forms_map.each do |base_word, form_pairs|
    wiktionary_words.add(base_word)
    form_pairs.each do |inflected_word, _|
      wiktionary_words.add(inflected_word) if cmudict.key?(inflected_word)
    end
  end
  delete_explicitly_forbidden_keys_from_hash(cmudict)
  rdict = build_rime_dict(cmudict)
  word_dict = build_word_dict(cmudict, rdict, subtlex_hash, wordfreq_hash, wiktionary_words, pos_map, forms_map)
  merge_word_dict_pronunciations_into_rdict!(rdict, word_dict)
  save_string_hash(rdict, generated_dict_path_under_dict_dir(RIME_DICT_FILENAME), RIME_DICT_HEADER)
  save_word_dict(word_dict)
end
