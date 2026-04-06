#!/usr/bin/env ruby

require "fileutils"

# Rhyming utilities for RhymeCrime
# Used both in preprocessing and at runtime

RIME_DICT_FILENAME = "rime_dict.txt"
WORD_DICT_FILENAME = "word_dict.txt"

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
def variants()
  # hash: word -> [preferred_form alternate_form1 alternate_form2 ...]
  if $variants.nil?
    $variants = load_variants
  end
  return $variants
end

def preferred_form(word)
  forms = variants[word]
  if(forms)
    debug "The preferred form of '#{word}' is '#{forms[0]}'" unless forms[0] == word
    return forms[0]
  else
    return word
  end
end

def all_forms(word)
  forms = variants[word]
  if(forms)
    return forms
  else
    return [word]
  end
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
  return hash
end

#
# prefixes
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

#
# rime (ARPABET key for rhyme lookup; see Pronunciation#rime)
#

def single_consonant?(phoneme_cluster)
  return phoneme_cluster.length == 1 && !phoneme_cluster[0].vowel?
end
