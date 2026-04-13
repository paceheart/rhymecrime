# encoding: utf-8
# Rime index: build, merge word_dict prons, rare-only bucket prune, filter_cmudict.

require_relative "utils_rhyme"
require_relative "pronunciation.rb"
require_relative "constants"

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
  # sort in-place and uniq in-place to avoid an extra array allocation per bucket
  for rime, words in rdict
    words.sort!
    words.uniq!
    rdict[rime] = words
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
  rdict.each do |_rime, words|
    words.sort!
    words.uniq!
  end
  rdict.reject! { |_rime, words| words.length <= 1 }
  rdict
end

def word_dict_frequency_for_rime_bucket(word_dict, word)
  entry = word_dict[word]
  return 0 if entry.nil?
  entry[0].to_i
end

# Drop rime lines where every word has frequency <= RARE_FREQ_MAX (see rare? in crime.rb).
def delete_rare_only_rime_buckets!(rdict, word_dict)
  removed = 0
  rdict.delete_if do |_rime, words|
    next false if words.nil? || words.empty?
    all_rare = words.all? do |w|
      word_dict_frequency_for_rime_bucket(word_dict, w) <= RARE_FREQ_MAX
    end
    removed += 1 if all_rare
    all_rare
  end
  puts "#{rdict.length} out of #{rdict.length + removed} rime buckets remain after removing buckets containing only rare words" if removed > 0
  rdict
end
def filter_cmudict(cmudict, rdict)
  # filter out words that differ only in apostrophes, and pronunciations with no rhymes
  filtered_cmudict = Hash.new
  proncount = 0
  total = 0
  for word, prons in cmudict
    filtered_cmudict[word] = Array.new # we still want entries for words with no pronunciations, though, in case they have frequency data
    dict_trace_puts(word, "prons = #{prons}") if dict_trace_word?(word)
    for pron in prons
      total += 1
      rime = pron.rime
      if(!rdict[rime].empty?)
        proncount += 1
        filtered_cmudict[word].push(pron)
        dict_trace_puts(word, "#{pron} passed filters; rime bucket = #{rdict[rime]}") if dict_trace_word?(word)
      end
    end
  end
  puts "#{proncount} out of #{total} pronunciations remain in the dictionary after removing pronunciations with no rhymes"
  return filtered_cmudict
end

# Mirrors +identical_rhyme?+ in crime.rb: true when every +target_rime+ pronunciation of +rhyme_word+ matches +target_rs+,
# or when there is no such pronunciation (vacuous; candidate is filtered out for identical_ok=false).
def headword_identical_rhyme?(rhyme_word, target_rs, target_rime, word_dict)
  prons = word_dict[rhyme_word]&.dig(1)
  return true if prons.nil? || prons.empty?
  prons.each do |pron|
    next unless pron.rime == target_rime
    return false if pron.rhyme_syllables_array != target_rs
  end
  true
end

# True if +word+ has at least one rime-bucket partner treated as a non-identical rhyme (+find_rhyming_words(..., false)+).
def headword_has_nonidentical_rhyme_partner?(word, prons, rdict, word_dict)
  return false if prons.nil? || prons.empty?

  seen = {}
  prons.each do |pron|
    rime = pron.rime
    next if rime.empty?
    rs = pron.rhyme_syllables_array
    key = [rime, rs]
    next if seen[key]

    seen[key] = true
    (rdict[rime] || []).each do |other|
      next if other == word
      next if headword_identical_rhyme?(other, rs, rime, word_dict)
      return true
    end
  end
  false
end

# Drop rime-bucket members not in +allowed+; remove singleton buckets (same invariant as +merge_word_dict_pronunciations_into_rdict!+).
def prune_rdict_to_headwords!(rdict, allowed)
  allowed = allowed.to_set if allowed.is_a?(Array)
  rdict.each do |_rime, words|
    words.reject! { |w| !allowed.include?(w) }
  end
  rdict.reject! { |_rime, words| words.nil? || words.length <= 1 }
  rdict
end
