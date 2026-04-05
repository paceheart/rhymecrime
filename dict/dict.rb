#!/usr/bin/env ruby

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
# A word's "rhyme signature" 
# RhymeCrime uses a two-step lookup process to avoid storing lots of redundant data. For exa e.g. all 500+ "-ation" rhymes as values for "elation", "consternation", etc.
# Step 1: Given a word, use the CMU Pronouncing Data to get its pronunciation.
# Step 1.1: Tweak the given pronunciation to deal with quirks of cmudict.
# Step 1.5: Get the word's rhyme signature
# Step 2: Given the rhyme signature, look up all words that rhyme with it (including itself)
# Step 2.5: Filter out bad rhymes, like the word itself and subwords (e.g. important rhyming with unimportant)
# build_rhyme_signature_dict builds the dictionary used in Step 2.
#
# We could improve performance even more by assigning an arbitrary index 0..N
# to each rhyme signature, having a list of those be the keys for Dict 1, and
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
# Phase 5.5: skip weak Zipf for 4-letter tokens with no WordNet entry (surname spam ~2.3) but keep neologisms ≥ this (yeet ~2.51).
WIKT_FLOOR_4L_WEAK_ZIPF_BELOW = 2.5
RHYME_SIGNATURE_DICT_HEADER = "# RhymeCrime's Rhyme Signature Dictionary
# https://github.com/paceheart/rhymecrime
#
# Each line is of the form:
#
# RHYME_SIGNATURE  WORD1 WORD2 WORD3 ...
#
# where RHYME_SIGNATURE is an underscore-concatenated ARPABET encoding
# of the syllables including and after the final most stressed vowel.
# See rhyme_signature_array for details.
#
# This data is automatically distilled from a forked version of the
# CMU Pronouncing Dictionary, with some manual tweaks and some
# programmatic preprocessing as described in dict.rb.
#
# Singleton signatures are excluded.
#"

WORD_DICT_HEADER = "# RhymeCrime's word info dictionary
# https://github.com/paceheart/rhymecrime
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
  # merge some similar-enough-sounding syllables
  line = line.chomp()
  original_line = line.clone

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

  #         caught [K AA1 T] / fought [F AO1 T]
  #         bong [B AA1 NG] / song [S AO1 NG]
  # but NOT bar [B AA1 R] / score [S K AO1 R], so we leave it alone if it's followed by R
  # If we had reliable data to distinguish 'cot' from 'caught', this would be in imperfect rhymes. But since caught and fought need to rhyme, we're forced to conflate them globally.
  line = gsub_unless_followed_by_r(line, " AO0", " AA0")
  line = gsub_unless_followed_by_r(line, " AO1", " AA1")
  line = gsub_unless_followed_by_r(line, " AO2", " AA2")

  # we could conflate this but whatever, I don't think it would make anything rhyme with 'endure'
  # line.gsub!(" D Y UW", " D UW")
  
  line = dwim_schwas(line)
  
  line = conflate_imperfect_rhymes(line)
  if(TRACE_WORD && line.include?(TRACE_WORD) && line != original_line)
    puts "TRACE Dwimmed #{original_line} to #{line}"
  end
  return line
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

def dwim_schwas(line)
  # illicit [IH2 L IH1 S AH0 T] / solicit [S AH0 L IH1 S IH0 T]
  # selfish [S EH1 L F IH0 SH] / shellfish [SH EH1 L F IH2 SH]
  # conflate all unstressed schwa-ish syllables, unless they are followed by R or NG.
  # mumble a little mumblier, please
  old = 'IH0'
  new = 'AH0'
  original_line = line.clone

  # (line =~ "1" || line =~ "2")
  # Protect R and NG from the upcoming gsub.
  # Also get (1) and (2) out of the way so they don't give false positives for primary/secondary stress detection.
  line.gsub!(old + " R", "fubarduckR")
  line.gsub!(old + " NG", "fubarduckNG")
  line.gsub!(old + " SH", "fubarduckSH") # this is needed for selfish / shellfish

  line.gsub!(old, new)

  if line != original_line
    line.gsub!("(1)", "{a}")
    line.gsub!("(2)", "{b}")
    
    if(!line.include?("1") && !line.include?("2")) # if there is no primary or secondary stress in this pronunciation
      line = original_line
      puts "Protected \"#{line}\" from having its schwas dwimmed"
    else
#      puts "Dwimmed schwas: #{original_line} -> #{line}"
      # put R and NG and (1) and (2) back the way they were
      line.gsub!("fubarduckR", old + " R")
      line.gsub!("fubarduckNG", old + " NG")
      line.gsub!("fubarduckSH", old + " SH")
      line.gsub!("{a}", "(1)")
      line.gsub!("{b}", "(2)")
    end
  end
  return line
end

def conflate_imperfect_rhymes(line)
  # @todo allow this to be toggleable at runtime instead of dictionary-building time
  
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
  return line
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
          sylpron = pron.syllabify
          hash[word].push(sylpron)
          if(word == TRACE_WORD)
            puts "TRACE Loaded #{word} as #{sylpron}"
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
  newhash
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
    return ALL_INITIAL_CONSONANT_CLUSTERS.include?(cluster_str)
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

# True if WordNet lists the base as a verb (any sense). Used to avoid Phase 6 giving
# noun-only stems a bogus verbal -ing frequency (kitchening, crotching, jealousing).
# Bases with no WordNet entry still return true so modern verbs (twerk) can inherit.
def wn_base_has_verb?(base)
  lemmas = WordNet::Lemma.find_all(base)
  return true if lemmas.empty?
  lemmas.any? { |l| l.pos == "v" }
end

#
# put it all together
#

def build_rhyme_signature_dict(cmudict)
  rdict = Hash.new {|h,k| h[k] = [] } # hash of arrays, each element of which is a Pronunciation
  i = 0;
  for word, prons in cmudict
    for pron in prons
      rsig = pron.rhyme_signature
      rdict[rsig].push(word)
    end
    i = i + 1;
  end
  # sort, and remove duplicate words
  for rsig, words in rdict
    new_words = words.sort.uniq
    if(new_words.nil?)
      rdict.delete(rsig)
    else
      rdict[rsig] = new_words
    end
  end
  print "Identified #{rdict.length} unique rhyme signatures, "
  rdict = rdict.reject!{|rsig, words| words.length <= 1 }
  puts "#{rdict.length} of which are nonempty"
  return rdict
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
      rsig = pron.rhyme_signature
      if(!rdict[rsig].empty?)
        proncount += 1
        filtered_cmudict[word].push(pron)
        if(word == TRACE_WORD)
          puts "TRACE #{pron} passed filters because it rhymes with #{rdict[rsig]}"
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

def add_frequency_info(cmudict, subtlex_hash, wordfreq_hash, wiktionary_words)
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
    common_extra += 1
  end
  puts "#{common_extra} extra words added from common_words.txt" if common_extra > 0

  # Phase 5.5: Wiktionary floor for modern words absent from all traditional corpora.
  # Require Zipf >= RARE so sub-RARE bins do not receive the floor wholesale.
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
    next if word.match?(/\A[a-z]{4}\z/) && zipf >= WORDFREQ_RARE_ZIPF && zipf < WIKT_FLOOR_4L_WEAK_ZIPF_BELOW
    next if short_initialism_shape?(word) && subtlex_hash[word] <= 0
    # 2-4 letter strings with strong wordfreq but no lexical anchor: skip floor so
    # IMAX/DVD-style tokens stay rare; Zipf < 3 keeps yeet-style floor eligibility.
    next if acronym_shape_wordfreq_only?(word) && subtlex_hash[word] <= 0 && !wn_has_entry?(word) && zipf >= WORDFREQ_COMMON_ZIPF
    entry[0] = 5
    floor_applied += 1
  end
  puts "#{floor_applied} words received Wiktionary existence floor" if floor_applied > 0

  # Phase 5.5b: Hyphenated word existence floor.
  # SUBTLEX and wordfreq tokenize on hyphens, so hyphenated words systematically score 0.
  # Grant floor when the compound is attested (Wiktionary headword OR WordNet MWE) and
  # the final segment (the "head word") is not independently useful for rhyming:
  # no WordNet lemma, and raw SUBTLEX < 12.
  # Skip inflected forms of hyphenated bases — those are handled by Phase 6 (or blocked).
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

  # Phase 6: frequency inheritance for inflected forms.
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
    next if inflected.end_with?("ing") && !wn_base_has_verb?(base)
    hash[inflected][0] = base_freq
    inherited += 1
  end
  puts "#{inherited} inflected forms inherited frequency from base words" if inherited > 0

  puts "#{count + extra + common_extra + floor_applied + hyp_floor + inherited} total entries with frequency data"
  return hash
end

def build_word_dict(cmudict, rdict, subtlex_hash, wordfreq_hash, wiktionary_words)
  cmudict = filter_cmudict(cmudict, rdict)
  word_dict = add_frequency_info(cmudict, subtlex_hash, wordfreq_hash, wiktionary_words)
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
    cmudict[word] = valid_prons.map(&:syllabify)
    added += 1
  end
  puts "Merged #{added} new words from Wiktionary into pronunciation dict"
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

      derived = Inflect.derive(base_pron, base_word, inflected_word)
      next if derived.nil? || derived.empty?
      next unless derived.phonemes.any?(&:vowel?)

      syllabified = derived.syllabify
      unless WHITELIST.include?(inflected_word)
        next unless final_consonant_cluster_ok?(syllabified.final_consonant_cluster_array)
      end

      cmudict[inflected_word] = [syllabified]
      added += 1
    end
  end
  puts "Generated #{added} inflected-form pronunciations"
end

$inflection_base_words = {}

def rebuild_rhymecrime_dictionaries()
  cmudict = load_cmudict
  wiktionary_prons, forms_map = load_wiktionary
  merge_wiktionary!(cmudict, wiktionary_prons)
  merge_inflected_forms!(cmudict, forms_map)
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
  rdict = build_rhyme_signature_dict(cmudict)
  save_string_hash(rdict, generated_dict_path_under_dict_dir(RHYME_SIGNATURE_DICT_FILENAME), RHYME_SIGNATURE_DICT_HEADER)
  subtlex_hash = load_subtlex
  wordfreq_hash = load_wordfreq
  word_dict = build_word_dict(cmudict, rdict, subtlex_hash, wordfreq_hash, wiktionary_words)
  save_word_dict(word_dict)
end

rebuild_rhymecrime_dictionaries
