# coding: utf-8

# Cohort for rime from rime_dict (dict-build keeps preferred headwords only; see strip_dispreferred_headwords_from_rime_dict!).
def rime_dict_lookup(rime)
  rime_dict[rime] || []
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

def find_rhyming_words(word, homophone_ok=true)
  # merges multiple pronunciations of WORD
  # use our compiled rime dictionary
  #
  # forbidden? is checked per spelling-variant form rather than gated
  # on the input surface. Scrubbed / tombstoned forms are absent from
  # word_dict; this skip is belt-and-braces for any stray variant.
  rhyming_words = Array.new
  for form in all_forms(word) # to increase the likelihood of a hit, try all spelling variants
    next if forbidden?(form)
    debug "Finding rhyming words for #{form} #{debug_info(form)}:"
    for pron in pronunciations(form)
      for rhyme in find_rhyming_words_for_pronunciation(pron, homophone_ok)
        rhyming_words.push(rhyme)
      end
    end
    rhyming_words.delete(word)
    if(rhyming_words)
      rhyming_words = rhyming_words.uniq
    end
  end
  return rhyming_words || [ ]
end

# Returns true when two ARPABET tokens describe the same surface phone for duplicate-pron
# trapping: collapse secondary stress (digit 2) with unstressed (0); keep primary (1) distinct from both.
def homophone_trap_equivalent_phone_tokens?(a, b)
  return true if a == b
  normalize_secondary_stress_to_unstressed_for_homophone_trap(a.to_s) == normalize_secondary_stress_to_unstressed_for_homophone_trap(b.to_s)
end

def normalize_secondary_stress_to_unstressed_for_homophone_trap(s)
  return s if s == "."
  if s =~ /\A(.+)([012])\z/
    base = Regexp.last_match(1).to_s
    d = Regexp.last_match(2).to_i
    nd = (d == 1) ? 1 : 0
    "#{base}#{nd}"
  else
    s
  end
end

def pronunciation_phoneme_homophone_trap_duplicate?(pron_a, pron_b)
  return false unless pron_a.phonemes.length == pron_b.phonemes.length

  pron_a.phonemes.each_with_index do |ph, i|
    return false unless homophone_trap_equivalent_phone_tokens?(ph, pron_b.phonemes[i])
  end
  true
end

def homophone_rhyme?(rhyme, target_pron)
  # Catches true homophones (same full pronunciation): write/right, plain/plane,
  # symbol/cymbal, flour/flower, puffin/puffin'. These would pass a
  # rime-cohort lookup but almost never count as legitimate rhymes; they're
  # "homophone / spelling-variant traps".
  #
  # CMU marks secondary syllable stress with 2 and unstressed with 0; perceptually close
  # pairs (sunday/sundae, marquee/marquis) differ only there. Collapse 2 onto 0
  # (1 unchanged) when comparing phoneme tuples so those become duplicate-pronunciation
  # traps (plumber/demur stays distinct: mismatched consonants and primary stresses).
  #
  # Morphological prefix cases (loading/unloading, end/upend, able/disable)
  # are intentionally _not_ caught here -- they're handled by filter_out_prefix_words
  # downstream. Coincidental rich-rime collisions where the words differ before the
  # stressed syllable (leave/believe, plied/applied, bone/trombone) _pass_
  # this filter and are allowed to rhyme. We accept splash damage (e.g.
  # percussion/repercussion getting caught by filter_out_prefix_words) in exchange
  # for a simpler rule.
  target_rime = target_pron.rime
  for pron in pronunciations(rhyme)
    next unless pron.rime == target_rime
    next unless pronunciation_phoneme_homophone_trap_duplicate?(pron, target_pron)
    return true
  end
  return false
end

def all_nontrivially_rich_rhymes?(words)
  # Bucket-wide rich_rime collision is only a real rich-rhyme signal when at
  # least one of the prons has a nontrivially_rich_rime? (i.e. its primary-
  # stress syllable carries an onset consonant that the rich rime captures).
  # Tuples like [viola, hemiola, payola] all have onsetless OW1 syllables, so
  # every rich_rime trivially equals the plain rime — they're plain rhymes,
  # not rich rhymes, and dropping them silently buries good music tuples like
  # music → viola / hemiola.
  syllable_signatures = Hash.new
  any_nontrivial = false
  for word in words do
    for pron in pronunciations(word)
      syllable_signatures[pron.rich_rime] = true
      any_nontrivial = true if pron.nontrivially_rich_rime?
    end
  end
  if syllable_signatures.length == 1 && any_nontrivial
    debug "Filtered out rich rhymes #{words}"
    return true
  else
    return false
  end
end

def find_rhyming_words_for_pronunciation(pron, homophone_ok=true)
  # use our compiled rime dictionary
  results = Array.new
  rime = pron.rime
  rime_dict_lookup(rime).each do |rhyme|
    if(!homophone_ok && homophone_rhyme?(rhyme, pron))
      debug "Filtered out homophone rhyme: #{pron} / #{rhyme} (#{debug_info(rhyme)})"
    else
      results.push(rhyme)
    end
  end
  return results || [ ]
end

def has_rhyming_word?(word)
  unless forbidden?(word)
    for pron in pronunciations(word)
      rime = pron.rime
      if(! rime_dict_lookup(rime).empty?)
        return true
      end
    end
  end
  return false
end

def filter_out_rhymeless_words(words)
  words.select { |word| has_rhyming_word?(word) }
end
