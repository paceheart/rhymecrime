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

# When the preferred form of a hyphen / spelling variant has no prons but its
# dispreferred sibling does, copy the prons from the dispreferred form into the
# preferred form's +word_dict+ entry. The typical case is the hyphen-preferred
# canonicalization (+up-end+ from +upend+, +hand-held+ from +handheld+,
# +on-screen+ from +onscreen+, +best-seller+ from +bestseller+, …): CMU and
# Kaikki list only the unhyphenated surface, so the hyphenated entry gets a
# +word_dict+ row from spelling-variant resolution but never receives a
# pronunciation from any source.
#
# Without this inheritance, +strip_dispreferred_headwords_from_rdict!+ removes
# the dispreferred surface from its rime bucket, but the preferred form was
# never added (the prior +merge_word_dict_pronunciations_into_rdict!+ pass
# skips empty-pron entries) — the bucket loses both surfaces, so a query like
# +find_rhyming_words('pend')+ misses +up-end+/+upend+ entirely. Copying the
# prons fixes both runtime +pronunciations(preferred)+ lookup and the rdict
# membership (after a follow-up +merge_word_dict_pronunciations_into_rdict!+).
#
# Run after +emit_spelling_variants_auto!+ so the latest auto-emitted variant
# pairs are visible to +preferred_form_in_build_lexicon+, and before
# +strip_dispreferred_headwords_from_rdict!+ so the rime-bucket stripper sees
# the preferred form populated.
def inherit_prons_from_dispreferred_to_preferred!(word_dict, log: true)
  inherited = 0
  word_dict.each do |word, entry|
    prons = entry.is_a?(Array) ? entry[1] : nil
    next unless prons.is_a?(Array) && !prons.empty?
    pref = preferred_form_in_build_lexicon(word, word_dict)
    next if pref == word
    pref_entry = word_dict[pref]
    next unless pref_entry
    pref_prons = pref_entry[1]
    next unless pref_prons.is_a?(Array) && pref_prons.empty?
    pref_entry[1] = prons.dup
    inherited += 1
    if dict_trace_word?(pref) || dict_trace_word?(word)
      dict_trace_puts(pref, "inherit_prons_from_dispreferred_to_preferred: #{pref} ← #{word} (#{prons.map(&:to_s).inspect})")
    end
  end
  if log && inherited > 0
    puts "#{inherited} preferred-form headwords inherited prons from dispreferred siblings"
  end
  inherited
end

# Drop alternate spellings / US–UK / hyphen dispreferred surfaces so +rime_dict+ lists only
# +preferred_form_in_build_lexicon+ headwords (matches runtime +preferred_form+ policy).
def strip_dispreferred_headwords_from_rdict!(rdict, word_dict, log: true)
  dropped = 0
  before_n = rdict.values.sum(&:size)
  rdict.each do |_rime, words|
    next if words.nil? || words.empty?

    words.reject! do |w|
      next false unless word_dict.key?(w)

      dis = preferred_form_in_build_lexicon(w, word_dict) != w
      dropped += 1 if dis
      dis
    end
  end
  rdict.reject! { |_rime, words| words.nil? || words.length <= 1 }
  if log && dropped > 0
    after_n = rdict.values.sum(&:size)
    puts "#{rdict.length} rime buckets (#{after_n} headwords) after removing #{dropped} dispreferred cohort entries (#{before_n} before)"
  end
  dropped
end

def word_dict_frequency_for_rime_bucket(word_dict, word)
  entry = word_dict[word]
  return 0 if entry.nil?
  entry[0].to_i
end

def word_common_preferred_headword?(word, word_dict)
  return false unless word_dict.key?(word)
  return false unless word_dict_frequency_for_rime_bucket(word_dict, word) > RARE_FREQ_MAX

  preferred_form_in_build_lexicon(word, word_dict) == word
end

# True when the bucket has exactly one **common preferred** headword (+preferred_form+ / spelling variants /
# US-UK / hyphen policy, frequency > +RARE_FREQ_MAX+). Mirrors the old “exactly one common” prune but
# ignores alternate spellings that map to another headword as preferred (e.g. *colour* when *color* is preferred).
# Buckets with two or more common preferred rhymes are kept (*yum* / *plum*).
def rime_bucket_one_common_preferred_with_any_rare?(words, word_dict)
  return false if words.nil? || words.length < 2

  common_pref = 0
  words.each do |w|
    common_pref += 1 if word_common_preferred_headword?(w, word_dict)
  end
  common_pref == 1
end

# Drop rime buckets where **every** headword is rare (frequency ≤ +RARE_FREQ_MAX+), or where there is
# exactly **one** common **preferred** headword (artifact size / avoid one strong anchor + clutter).
def delete_rare_only_rime_buckets!(rdict, word_dict, log: true)
  removed = 0
  before_n = rdict.length
  rdict.delete_if do |_rime, words|
    next false if words.nil? || words.empty?
    all_rare = words.all? { |w| word_dict_frequency_for_rime_bucket(word_dict, w) <= RARE_FREQ_MAX }
    one_common_pref_mixed = rime_bucket_one_common_preferred_with_any_rare?(words, word_dict)
    drop = all_rare || one_common_pref_mixed
    removed += 1 if drop
    drop
  end
  if log && removed > 0
    puts "#{rdict.length} out of #{before_n} rime buckets remain after removing rare-only and one-common-preferred+mixed buckets"
  end
  removed
end

def rime_bucket_common_headwords(words, word_dict)
  words.select { |w| word_dict_frequency_for_rime_bucket(word_dict, w) > RARE_FREQ_MAX }
end

# True if +a+ and +b+ have some pairing of pronunciations for +rime+ that counts as a non-identical rhyme.
def rime_common_pair_nonidentical_for_rime?(a, b, rime, word_dict)
  pr_a = word_dict[a]&.dig(1)
  pr_b = word_dict[b]&.dig(1)
  return false if pr_a.nil? || pr_b.nil?

  pr_a.each do |pa|
    next unless pa.rime == rime
    return true unless headword_identical_rhyme?(b, pa.rhyme_syllables_array, rime, word_dict)
  end
  pr_b.each do |pb|
    next unless pb.rime == rime
    return true unless headword_identical_rhyme?(a, pb.rhyme_syllables_array, rime, word_dict)
  end
  false
end

# True when there are ≥2 common headwords and every unordered pair rhymes only identically for this +rime+.
def rime_bucket_all_common_pairs_identical_only?(rime, words, word_dict)
  common = rime_bucket_common_headwords(words, word_dict)
  return false if common.size < 2

  common.combination(2) do |a, b|
    return false if rime_common_pair_nonidentical_for_rime?(a, b, rime, word_dict)
  end
  true
end

# After rare/mixed pruning: drop buckets where all common–common rhyme links are identical (+identical_ok=false+
# would find no partner within the common subset). Skipped when +INCLUDE_IDENTICAL_RHYMES+ is true.
def delete_common_identical_only_rime_buckets!(rdict, word_dict, log: true)
  return 0 if INCLUDE_IDENTICAL_RHYMES

  removed = 0
  before_n = rdict.length
  rdict.delete_if do |rime, words|
    next false if words.nil? || words.empty?
    next false unless rime_bucket_all_common_pairs_identical_only?(rime, words, word_dict)

    removed += 1
    true
  end
  if log && removed > 0
    puts "#{rdict.length} out of #{before_n} rime buckets remain after removing common-identical-only buckets (INCLUDE_IDENTICAL_RHYMES is off)"
  end
  removed
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

  word_pf = preferred_form_in_build_lexicon(word, word_dict)
  seen = {}
  prons.each do |pron|
    rime = pron.rime
    next if rime.empty?
    rs = pron.rhyme_syllables_array
    key = [rime, rs]
    next if seen[key]

    seen[key] = true
    (rdict[rime] || []).each do |other|
      next if preferred_form_in_build_lexicon(other, word_dict) == word_pf
      next if headword_identical_rhyme?(other, rs, rime, word_dict)
      return true
    end
  end
  false
end

# Logical predicate: is +word+ eligible to be a compute/DDB cue (the PK of a
# +related#<lemma>+ row)?
#
# Broader than +relatedness_target_word?+: cue coverage must include every
# lemma a user might ask about at runtime (or a spec fixture references), even
# rhymeless ones (+music+, +concerto+, +algebra+, +quarterback+). Those lemmas
# can't appear as a _related_ in another cue's row (no rhyme to attach to),
# but they're perfectly valid questions on the cue side.
#
# Physical implementation today: +word_common_preferred_headword?+. Keep this
# wrapper so compute, eval scripts, and build-time stats all agree on what
# "cue" means — and so widening the cue set later (e.g. to include dispreferred
# forms a user might type) only requires a change here.
def cue_word?(word, word_dict)
  word_common_preferred_headword?(word, word_dict)
end

# Logical predicate: is +word+ eligible to appear as a related in another cue's
# row, or to be returned in a related-words response to the UI?
#
# Strict superset of +cue_word?+: every relatedness target is a valid cue, but
# some cues (rhymeless lemmas) are not targets. The extra criterion is a
# non-identical rhyme partner in +rdict+ — without one the word would never
# surface in the UI even if it were included in a list.
def relatedness_target_word?(word, word_dict, rdict)
  return false unless cue_word?(word, word_dict)
  prons = word_dict[word]&.dig(1)
  headword_has_nonidentical_rhyme_partner?(word, prons, rdict, word_dict)
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
