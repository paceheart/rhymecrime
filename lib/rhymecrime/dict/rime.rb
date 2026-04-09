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
