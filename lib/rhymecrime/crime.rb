#!/usr/bin/env ruby
# coding: utf-8

Gem.paths = { 'GEM_PATH' => '/usr/local/rvm/gems/ruby-2.6.5/' }

#
# control parameters
# Don't tweak these here, tweak them in frontend.rb
#

$output_format = 'cgi'
$display_word_frequencies = false
$display_word_similarities = false

#
# Public interface: rhymecrime(word1, word2, goal, output_format='text', debug_mode=false)
# see bin/rhyme.rb for documentation
# 

require 'rwordnet'
require 'net/http'
require 'uri'
require 'json'
require 'cgi'
require_relative 'dict/utils_rhyme'
require_relative 'dict/phoneme.rb'
require_relative 'dict/pronunciation.rb'
require_relative "related"

#
# utilities
#

def cgi_print(string)
  if($output_format == 'cgi')
    print string
  end
end

def debug_info(word)
  result = ""
  i = 0
  prons = pronunciations(word)
  for pron in prons
    i = i + 1
    unless i == 1
      result << " "
    end

    # pronunciation
    if prons.length == 1
      result << "pron="
    else
      result << "pron#{i}="
    end
    result << pron.to_s

    # rhyme syllables string
    if prons.length == 1
      result << " rsyll="
    else
      result << " rsyll#{i}="
    end

    result << pron.rhyme_syllables_string

    if prons.length == 1
      result << " rime="
    else
      result << " rime#{i}="
    end
    result << pron.rime
  end
  return result
end

#
# rhyme computation
#

$word_dict = nil
def word_dict()
  # word => [frequency, pronunciations]
  # pronunciations = [pronunciation1, pronunciation2 ...]
  # pronunciation = [syllable1, syllable1, ...]
  if $word_dict.nil?
    $word_dict = load_word_dict
  end
  $word_dict
end

WORDS_NEEDED_FOR_TESTING = ['arpeggio', 'asterisk', 'blackmail', 'bobcat', 'burglar', 'burglary', 'cat', 'celebrity', 'costume', 'crime', 'doubloons', 'drumsticks', 'fanciers', 'feline', 'fortissimo', 'galaxy', 'glissando', 'halloween', 'hemiola', 'homicide', 'item', 'jaguar', 'mandolin', 'music', 'overtone', 'pianissimo', 'pirate', 'pussy', 'repertoire', 'ritardando', 'scurvy', 'star', 'thing', 'tree', 'treetop', 'trespassing', 'whiskers', 'wildcat', 'xylophone'] # include these even if they don't have any rhymes
def needed_for_testing?(word)
  WORDS_NEEDED_FOR_TESTING.include?(word)
end  

$rdict = nil # rime (underscore ARPABET key) -> words hash
def rdict
  # rime => [rhyming_word1 rhyming_word2 ...]
  if $rdict.nil?
    $rdict = load_rime_dict_as_hash
  end
  $rdict
end

def load_rime_dict_as_hash()
  load_string_hash(generated_dict_path(RIME_DICT_FILENAME)) or die "First run ./bin/dict-build to populate generated/"
end

def pronunciations(word)
  word_info = word_dict[word]
  if(word_info)
    return word_info[1]
  else
    return [ ]
  end
end

def frequency(word)
  word_info = word_dict[word]
  if(word_info)
    return word_info[0]
  else
    return 0
  end
end

# Sorted list of RhymeCrime part-of-speech tags for +word+ (Kaikki +pos+ union, then lexical
# Kaikki POS intersected with WordNet coarse POS when WN has the lemma; see apply_lexical_pos_layer_a!
# in dict.rb (build). Empty if unknown or before generated/part_of_speech.json exists.
$part_of_speech_by_word = nil
def part_of_speech_tags(word)
  w = word.to_s.downcase.strip
  return [] if w.empty?
  if $part_of_speech_by_word.nil?
    path = generated_dict_path(PART_OF_SPEECH_FILENAME)
    $part_of_speech_by_word =
      if File.exist?(path)
        JSON.parse(File.read(path, encoding: "UTF-8"))
      else
        {}
      end
  end
  tags = $part_of_speech_by_word[w]
  tags.is_a?(Array) ? tags : []
end

def rdict_lookup(rime)
  rdict[rime] || [ ]
end

def find_preferred_rhyming_words(word)
  return filter_out_dispreferred_words(find_rhyming_words(word, false), word)
end

def filter_out_dispreferred_words(words, focal_word)
  # filters out dispreferred spelling variants and prefix words
  result = words.map { |word| preferred_form(word) }
  if result
    result.sort!.uniq!
    result = result - all_forms(focal_word)
    debug "preferred: #{result.inspect}"
  end
  result = filter_out_prefix_words(result, focal_word)
  return result || [ ]
end

def filter_out_prefix_words(words, focal_word)
  return words - prefix_words(words, focal_word)
end

def prefix_words(words, focal_word)
  # All words in WORDS that would share the same root as FOCAL_WORD if you removed its prefix.
  # For example, if WORDS contains "able" and "disable", the prefix_words are ["disable"].
  # But if WORDS contained "unable" and "disable", there would be no prefix_words.
  focal_roots = Array.new
  focal_roots << focal_word
  for prefix in COMMON_PREFIXES
    if focal_word.start_with?(prefix)
      root = focal_word[prefix.length..-1]
      if words.include?(root)
        focal_roots << root
      end
    end
  end
  
  result = Array.new
  for word in words
    if focal_roots.include?(word)
      result << word
    else
      for prefix in COMMON_PREFIXES
        if word.start_with?(prefix)
          root = word[prefix.length..-1]
          if focal_roots.include?(root)
            result << word
          end
        end
      end
    end
  end
  if result
    debug "Filtering out prefix words #{result} from #{words}"
  end
  return result
end

def any_rhyming_words?(word)
  !find_rhyming_words(word).empty?
end

def find_rhyming_words(word, identical_ok=true)
  # merges multiple pronunciations of WORD
  # use our compiled rime dictionary
  rhyming_words = Array.new
  unless(explicitly_forbidden?(word))
    for form in all_forms(word) # to increase the likelihood of a hit, try all spelling variants
      debug "Finding rhyming words for #{form} #{debug_info(form)}:"
      for pron in pronunciations(form)
        for rhyme in find_rhyming_words_for_pronunciation(pron, identical_ok)
          rhyming_words.push(rhyme)
        end
      end
      rhyming_words.delete(word)
      if(rhyming_words)
        rhyming_words = rhyming_words.uniq
      end
    end
  end
  return rhyming_words || [ ]
end

def identical_rhyme?(rhyme, target_rhyme_syllables_array, target_rime)
  # Used to filter out identical rhymes, where the entire final stressed syllable is identical to the one in RSIG.
  # e.g. if you input "leave", this will return "grieve" but not "believe", because the rhyming syllable
  # "L_IY_V" is identical.
  # Only considers pronunciations that actually rhyme (share the target rime), so a non-rhyming
  # alternate pronunciation (e.g. noun RE-cord vs verb re-CORD) can't give a false escape.
  for pron in pronunciations(rhyme)
    next unless pron.rime == target_rime
    if pron.rhyme_syllables_array != target_rhyme_syllables_array
      return false
    end
  end
  return true
end

def all_identical_rhymes?(words)
  syllable_signatures = Hash.new
  for word in words do
    for pron in pronunciations(word)
      syllable_signatures[pron.rhyme_syllables_string] = true
    end
  end
  if syllable_signatures.length == 1
    debug "Filtered out identical rhymes #{words}"
    return true
  else
    return false
  end
end

def find_rhyming_words_for_pronunciation(pron, identical_ok=true)
  # use our compiled rime dictionary
  results = Array.new
  rime = pron.rime
  rsyllables = pron.rhyme_syllables_array
  rdict_lookup(rime).each { |rhyme|
    cand_prons = pronunciations(rhyme)
    if(!identical_ok && identical_rhyme?(rhyme, rsyllables, rime))
      debug "Filtered out identical rhyme: #{pron} / #{rhyme} (#{debug_info(rhyme)})"
    else
      results.push(rhyme)
    end
  }
  return results || [ ]
end

def has_rhyming_word?(word)
  unless(explicitly_forbidden?(word))
    for pron in pronunciations(word)
      rime = pron.rime
      if(! rdict_lookup(rime).empty?)
        return true
      end
    end
  end
  return false
end

def filter_out_rhymeless_words(words)
  words.select { |word| has_rhyming_word?(word) }
end

#
# WordNet stuff
#

def find_synsets(word)
  lemmas = WordNet::Lemma.find_all(word)
  synsets = lemmas.map { |lemma| lemma.synsets }
  return synsets.flatten || [ ]
end

def find_synonyms(word)
  results = Array.new
  for synset in find_synsets(word) do
    for word in synset.words do
      results << word
    end
  end
  return results.uniq!.sort!
end

#
# Thematic relatedness
#

def find_related_words(word, include_self, include_rhymeless=true)
  words = []
  unless explicitly_forbidden?(word)
    words = RelatedWords.find_thematically_related_words(word, include_self, include_rhymeless)
    words = filter_out_dispreferred_words(words, word)
  end
  return words
end

def find_related_rhymes(rhyme, rel)
  result = find_rhyming_words(rhyme, false)
  result = filter_out_dispreferred_words(result, rhyme)
  result = result.select { |w| thematically_related?(rhyme, w) }
end

$rhyming_tuple_cache = Hash.new()
def find_rhyming_tuples(input_rel1)
  if $rhyming_tuple_cache.key?(input_rel1)
    return $rhyming_tuple_cache[input_rel1]
  else
    results = really_find_rhyming_tuples(input_rel1)
    $rhyming_tuple_cache[input_rel1] = results
    return results
  end
end

def really_find_rhyming_tuples(input_rel1)
  # Rhyming word sets that are related to INPUT_REL1.
  # Each element of the returned array is an array of words that rhyme with each other and are all related to INPUT_REL1.
  # Algorithm:
  # Compute the set of all words thematically related to INPUT_REL1, call it RELATEDS1.
  # For each word REL1 in RELATEDS1,
  #   Get all rhymes RHYME1 of REL1.
  #   If R is in RELATEDS1, compute R's rime and put RHYME1 in the bucket labeled by that rime.
  # Return all buckets with two or more words in them.
  related_rhymes = Hash.new {|h,k| h[k] = [] } # hash of arrays
  unless(explicitly_forbidden?(input_rel1))
    relateds1 = find_related_words(input_rel1, true)
    relateds1.each { |rel1|
      for rel1pron in pronunciations(rel1)
        rime = rel1pron.rime
        debug "Rhymes for #{rel1} [#{rime}] #{debug_info(rel1)}:"
        find_rhyming_words_for_pronunciation(rel1pron, true).each { |rhyme1|
          if(relateds1.include? rhyme1) # we only care about relateds of input_rel1
            rhyme1 = preferred_form(rhyme1) # push 'honor' instead of 'honour'. This will ensure we don't push both.
            related_rhymes[rime].push(rhyme1)
            debug " #{rhyme1} #{debug_info(rhyme1)}"
          end
        }
      end
    }
  end
  tuples = [ ]
  related_rhymes.each { |rime, relrhymes|
    relrhymes.sort!.uniq!
    if(relrhymes.length > 1 && !all_identical_rhymes?(relrhymes))
      tuples.push(relrhymes.sort!)
    end
  }
  return tuples
end

def find_rhyming_pairs(input_rel1, input_rel2)
  # Pairs of rhyming words where the first word is related to INPUT_REL1 and the second word is related to INPUT_REL2
  # Each element of the returned array is a pair of rhyming words [W1 W2] where W1 is related to INPUT_REL1 and W2 is related to INPUT_REL2
  # Algorithm:
  # Compute the set of all words thematically related to INPUT_REL1, call it RELATEDS1.
  # Compute the set of all words thematically related to INPUT_REL2, call it RELATEDS2.
  # For each word REL1 in RELATEDS1,
  #   Get all non-identical rhymes RHYME of REL1.
  #   If RHYME rhymes with REL1 and is related to INPUT_REL2, we win! "REL1 / RHYME" is a pair.
  related_rhymes = Hash.new {|h,k| h[k] = [] } # hash of arrays
  unless(explicitly_forbidden?(input_rel1) || explicitly_forbidden?(input_rel2))
    relateds1 = find_related_words(input_rel1, true)
    relateds2 = find_related_words(input_rel2, true).to_set
    relateds1.each { |rel1|
      # rel1 is a word related to input_rel1. We're looking for rhyming pairs [rel1 rel2].
      debug "rhymes for #{rel1} (#{debug_info(rel1)}):<br>"
      find_rhyming_words(rel1, false).each { |rhyme| # check all non-identical rhymes of REL1, call each one 'RHYME'
        if(relateds2.include? rhyme) # is RHYME related to INPUT_REL2? If so, we win!
          related_rhymes[rel1].push(rhyme)
          debug " " + rhyme + " " + debug_info(rhyme)
        end
      }
      debug "<br><br>"
    }
  end
  pairs = [ ]
  related_rhymes.each { |relrhyme1, relrhyme2_list|
    if(!relrhyme2_list.empty?)
      relrhyme2_list.each { |relrhyme2|
        pairs.push([relrhyme1, relrhyme2])
      }
    end
  }
  return pairs
end

#
# Display
#

def print_synsets(synsets, input_word)
  # prints the synsets in SYNSETS that are nontrivial wrt INPUT_WORD
  isFirst = true
  for synset in synsets
    synonyms = synset.words - [ input_word ]
    unless(synonyms.empty?)
      unless isFirst
        cgi_print "<br>"
      end
      isFirst = false;
      cgi_print "<i>"
      puts short_gloss(synset)
      cgi_print "</i>"
      puts
      print_words(synonyms)
    end
  end
end

def short_gloss(synset)
  gloss = synset.gloss
  i = gloss.index(';')
  if i
    return gloss[0,i]
  else
    return gloss
  end
end

def print_tuple(tuple, focal_word=false)
  # this basically just pushes the rare words to the end, but we could do something snazzier if we want
  cgi_print "<div class='output_tuple'><p class='output_p'>"
  good_tuple = tuple.reject{ |t| rare?(t) }
  bad_tuple  = tuple.select{ |t| rare?(t) }
  if(good_tuple.empty?)
    print_half_of_tuple(bad_tuple, focal_word)
  elsif(bad_tuple.empty?)
    print_half_of_tuple(good_tuple, focal_word)
  else
    print_half_of_tuple(good_tuple, focal_word)
    print " / "
    print_half_of_tuple(bad_tuple, focal_word)
  end
  cgi_print "</p></div>"
  puts
  STDOUT.flush
end
  
def print_half_of_tuple(tuple, focal_word=false)
  # print TUPLE separated by slashes
  i = 0
  tuple.each { |elem|
    if(i > 0)
      print " / "
    end
    print_word(elem, focal_word)
    i += 1
  }
end

def print_tuples(tuples, focal_word=false)
  # return boolean, did I print anything? i.e. was TUPLES nonempty?
  success = !tuples.empty?
  if(success)
    tuples.sort.uniq.each { |tuple|
      print_tuple(tuple, focal_word)
    }
  end
  return success
end

def print_words(words, focal_word=false)
  success = !words.empty?
  if(success)
    words.sort.uniq.each { |word|
      cgi_print "<div class='output_tuple'>"
      cgi_print "<p class='output_p'>"
      print_word(word, focal_word)
      if($display_word_frequencies)
        print " (#{frequency(word)})"
      end
      cgi_print "</p>"
      cgi_print "</div>"
      puts
    }
  end
  return success
end

def ubiquity(word)
  # 0-255
  result = 0
  case frequency(word)
  when 0
    result = 0
  when 1
    result = 40
  when 2..5
    result = 80
  when 6..20
    result = 120
  when 21..100
    result = 160
  when 101..1000
    result = 200
  else
    result = 255
  end
  result
end

def rare?(word)
  frequency(word) <= 4 # rare_words/common_words + frequency pipeline
end

def filter_out_rare_words(words)
  # When you enter e.g. 'kitten', you'll get back some reasonable
  # things like 'bitten', 'britain', and 'smitten', but you'll also
  # get back crap like 'bitton', 'brittain', 'brittan', 'brittin',
  # 'britton', 'ditton', 'fitton', etc.
  #
  # Some of these are rare words, and some are just
  # mistakes. Regardless, we don't want them in our output. They
  # clutter up the place and make the good rhymes harder to see.
  #
  # We don't want to get rid of them entirely, though; occasionally
  # that rare word is exactly the one you want, or a good word gets
  # misfiled as rare. So instead we put them in the 'dregs' bucket,
  # which shows up as "For the desperate:" on the website.
  good = words.reject{ |w| rare?(w) }
  bad = words.select { |w| rare?(w) }
  return good, bad
end

def rare_tuple?(tuple, threshold=2)
  common_count = 0
  for word in tuple
    unless rare?(word)
      common_count = common_count + 1
      if(common_count >= threshold)
        return false
      end
    end
  end
  return true
end

def filter_out_rare_tuples(tuples)
  # A tuple gets to be common if it contains at least two common words
  good = tuples.reject{ |t| rare_tuple?(t) }
  bad = tuples.select { |t| rare_tuple?(t) }
  return good, bad
end

def rare_pair?(pair)
  rare_tuple?(pair, 2)
end

def filter_out_rare_pairs(tuples)
  # A pair only gets to be common if both its words are common
  good = tuples.reject{ |t| rare_pair?(t) }
  bad = tuples.select { |t| rare_pair?(t) }
  return good, bad
end

def print_word(word, focal_word=false)
  word = word.gsub(/\(.*\)/, '') # remove stuff in parentheses
  got_rhymes = !pronunciations(word).empty?
  if(got_rhymes)
    # @todo urlencode
    cgi_print "<a href='rhyme.rb?word1=#{word}'>"
  end
  ubiq = 255
  if(rare?(word))
    ubiq = 0
  end
  # cgi_print "<span style='color: rgb(#{ubiq}, #{ubiq}, #{ubiq});'>"
  word = word.gsub('_', ' ')
  print word
  # cgi_print "</span>"
  if(got_rhymes)
    cgi_print "</a>"
  end
  if($display_word_similarities)
    print_html_percent_similarity(word, focal_word)
  end
end

#
# Central dispatcher
#

def focal_word(word)
  return "\"<span class='focal_word'>#{word}</span>\""
end

def rhymecrime(word1, word2, goal, output_format='text', debug_mode=false)
  # When you enter a single word,
  #   RhymeCrime displays rhymes for that word (see find_rhyming_words), separating out the rare words (see rare?)
  #   and in a separate column, displays sets of rhyming words (see find_rhyming_tuples)
  # When you enter two words,
  #   RhymeCrime first displays rhymes for WORD1 that are thematically related to WORD2 (see related_rhymes),
  #   and in a separate column, displays pairs of rhyming words (RHYME1 / RHYME2) in which RHYME1 is related to WORD1 and RHYME2 is related to WORD2. (see find_rhyming_pairs)
  $output_format = output_format
  $debug_mode = debug_mode
  header_eol = ":<div class='results'>"
  
  result = nil
  dregs = [ ]
  result_type = :error # :words, :tuples, :bad_input, :vacuous, :error
  result_header = "Unexpected error."

  # special cases
  if(word1 == "" and word2 == "")
    return nil, :vacuous, ""
  end
  if(word1 == "" and word2 != "")
    word1, word2 = word2, word1
  end

  # main list of cases
  case goal
  when "rhymes"
    result_header = "Rhymes for " + focal_word(word1) + header_eol
    result, dregs = filter_out_rare_words(find_preferred_rhyming_words(word1))
    result_type = :words
  when "related"
    result_header = "Words related to " + focal_word(word1) + header_eol
    result, dregs = filter_out_rare_words(filter_out_rhymeless_words(find_related_words(word1, false)))
    result_type = :words
  when "set_related"
    result_header = "Rhyming word sets related to " + focal_word(word1) + header_eol
    result, dregs = filter_out_rare_tuples(find_rhyming_tuples(word1))
    result_type = :tuples
  when "pair_related"
    if(word1 == "" or word2 == "")
      result_header = "I need two words to find rhyming pairs. For example, Word 1 = <span class='focal_word'>crime</span>, Word 2 = <span class='focal_word'>heaven</span>"
      result_type = :bad_input
    else
      result_header = "Rhyming word pairs where the first word is related to" + " " + focal_word(word1) + " and the second word is related to " + " " + focal_word(word2) + header_eol
      result, dregs = filter_out_rare_tuples(find_rhyming_pairs(word1, word2))
      result_type = :tuples
    end
  when "related_rhymes"
    if(word1 == "" or word2 == "")
      result_header = "I need two words to find related rhyming pairs. For example, Word 1 = <span class='focal_word'>please</span>, Word 2 = <span class='focal_word'>cats</span>"
      result_type = :bad_input
    else
      result_header = "Rhymes for" + " " + focal_word(word1) + " that are related to " + focal_word(word2) + header_eol
      result, dregs = filter_out_rare_words(find_related_rhymes(word1, word2))
      result_type = :words
    end
  else
    result_header = "Invalid selection."
    result_type = :bad_input
  end
  debug "result = #{result}"
  debug "result_type = #{result_type}"
  return result, dregs, result_type, result_header
end

#
# Utilities
#

def related?(word1, word2, include_self=false)
  # Is word1 thematically related to word2?
  word1 = preferred_form(word1)
  word2 = preferred_form(word2)
  not explicitly_forbidden?(word1) and not explicitly_forbidden?(word2) and thematically_related?(word1, word2)
end

def rhymes?(word1, word2, identical_ok=true)
  # Does word1 rhyme with word2?
  find_rhyming_words(word1, identical_ok).include?(word2)
end
