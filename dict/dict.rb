#!/usr/bin/env ruby

# Change this to a string to display detailed output for a particular word
TRACE_WORD = nil

# Preprocess the cmudict data into a format that's efficient for looking up rhyming words.
# Reads from CMUDICT_FILENAME, writes out RHYME_SIGNATURE_DICT_FILENAME and WORD_DICT_FILENAME.
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
require_relative 'utils_rhyme'
require_relative 'phoneme.rb'
require_relative 'pronunciation.rb'

CMUDICT_FILENAME = "cmudict/cmudict-0.7c.txt"
RARE_WORDS_FILENAME = "rare_words.txt"
COMMON_WORDS_FILENAME = "common_words.txt"

WordNet::DB.path = "WordNet3.1/"
WORDNET_TAGSENSE_COUNT_MULTIPLICATION_FACTOR = 100 # each tagsense_count from wordnet counts as this many occurrences in some corpus

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

def delete_blacklisted_keys_from_hash(cmudict)
  count = 0
  for bad_word in blacklist
    if(cmudict.delete(bad_word.chomp))
      count = count + 1
    end
  end
  puts "Removed #{count} blacklisted words from the dictionary"
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
  IO.readlines(CMUDICT_FILENAME).each{ |line|
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
# parse lemma dict
#

def load_lemma_dict()
  lemmahash = Hash.new # word form => base word (lemma)
  freqhash = Hash.new(0) # hash of numbers (word occurrence frequencies), default 0
  wordcount = 0
  IO.readlines("lemma_en/lemma.en.txt").each{ |line|
    if(useful_lemma_dict_line?(line))
      line.chomp!
      wordcount += 1
      entry, altforms_str = line.split(' -> ')
      word, freq_str = entry.split('/')
      # update lemmehash
      for altform in altforms_str.split(',')
        lemmahash[altform] = word
      end
      # update freqhash
      if(freq_str)
        freq = freq_str.to_i
      else
        freq = 1
      end
      freqhash[word] += freq
      for altform in altforms_str.split(',')
        freqhash[altform] += freq
      end
    else
      puts "Ignoring lemma_dict line: #{line}"
    end
  }
  # this slightly overcounts because it double-counts altforms that are the same as lemma
  puts "Mapped #{lemmahash.length + wordcount} words to #{wordcount} lemmas"
  puts "Loaded #{freqhash.length} words from the frequency data"
  return lemmahash, freqhash
end

def useful_lemma_dict_line?(line)
  # comments are not useful
  return !(line =~ /\A;/)
end

#
# WordNet
#

def wn_frequency(word, lemmadict)
  frequency = 0
  lemmas = WordNet::Lemma.find_all(word)
  # If you didn't find it, try using the lemmadict to get the base form of WORD
  if(lemmas.empty?)
    base_word = lemmadict[word]
    if(base_word)
      lemmas = WordNet::Lemma.find_all(base_word)
    end
  end
  lemmas.each { |lemma|
    # +1 because words get a boost just from being in WordNet at all
    frequency += (lemma.tagsense_count + 1) * WORDNET_TAGSENSE_COUNT_MULTIPLICATION_FACTOR
    if(word == TRACE_WORD)
      puts "TRACE lemma #{lemma.inspect}, tagsense_count = #{lemma.tagsense_count}, wn_frequency = #{frequency}"
    end
  }
  return frequency
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

def add_frequency_info(cmudict, lemmadict, freqdict)
  # we use lemma_en and WordNet for word frequency data,
  # to distinguish rare words from common words.
  count = 0;
  hash = Hash.new
  rare_words = IO.readlines(RARE_WORDS_FILENAME, chomp: true)
  common_words = IO.readlines(COMMON_WORDS_FILENAME, chomp: true)
  for word, prons in cmudict
    if(stop_word?(word))
      freq = 999999 # very common
# Even if we let 'Vlad' through, it would have incorrect syllable boundaries because it won't accept VL as a conconant cluster
#    elsif(WHITELIST.include?(word))
#      freq = 212 # common enough to be worth mentioning explicitly
    elsif(common_words.include?(word))
      freq = 99
    elsif(rare_words.include?(word))
      freq = 0
    else
      freqdict_freq = freqdict[word] || 0
      wn_freq = wn_frequency(word, lemmadict)
      freq = freqdict_freq + wn_freq
    end
    # lemma_en (freqdict_freq) has better coverage than WordNet,
    # but also includes some false positives. It has the pro of including good things like
    #   bettor 1, holy 2994, mod 456, paroled 237, saffron 180, slacker 561, trillion 1, vanes 153
    # at the cost of including some crap and proper nouns like
    #   nardo 1, bors 27, matias 2, soweto 96, steinman 1
    # A random sample of 15 words with a freqdict_freq of 1 yielded:
    #   5 good: gasoline (wn 1), chicanery, noncombatants, propagandize, psilocybin
    #   1 whatever: parimutuel (wn 1)
    #   5 names: adam (wn 1), ciardi, cydonia, tuscaloosa, walter
    #   2 initialisms: cctv, ni
    #   2 rare: junco, stylites
    # Only a third of them are good. Is it worth adding 2/3 crap to get the 1/3 good?
    if(freq > 0)
      count += 1
    end
    entry = [freq, prons]
    hash[word] = entry
  end
  puts "#{count} of those entries have frequency data"
  return hash
end

def build_word_dict(cmudict, lemmadict, freqdict, rdict)
  cmudict = filter_cmudict(cmudict,rdict)
  word_dict = add_frequency_info(cmudict, lemmadict, freqdict)
  return filter_word_dict(word_dict)
end

def rebuild_rhymecrime_dictionaries()
  cmudict = load_cmudict
  delete_blacklisted_keys_from_hash(cmudict)
  rdict = build_rhyme_signature_dict(cmudict)
  save_string_hash(rdict, RHYME_SIGNATURE_DICT_FILENAME, RHYME_SIGNATURE_DICT_HEADER)
  lemma_dict, freq_dict = load_lemma_dict
  word_dict = build_word_dict(cmudict, lemma_dict, freq_dict, rdict)
  save_word_dict(word_dict)
end

rebuild_rhymecrime_dictionaries
