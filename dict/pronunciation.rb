class Pronunciation
  attr_reader :phonemes

  def initialize(phonemes)
    @phonemes = phonemes
  end

  def ==(other)
    (other.class <= Pronunciation) && @phonemes == other.phonemes
  end

  def <(other)
    @phonemes < other.phonemes
  end

  def <=>(other)
    @phonemes <=> other.phonemes
  end
  
  def to_s
    phonemes.join(" ")
  end

  def empty?
    phonemes.empty?
  end

  # Conflate unstressed IH0 with AH0 (CMU/Wikt/Inflect policy): illicit/solicit, yeeted/defeated.
  # Skips IH0 before R, NG, or SH (beer, selfish/shellfish). If a change would remove all
  # primary/secondary stress from the pronunciation, returns +self+ unchanged.
  def with_dwimmed_schwas
    return self if empty?
    out = @phonemes.dup
    protected_next = %w[R NG SH]
    changed = false
    i = 0
    while i < out.length
      if out[i] == "IH0"
        j = i + 1
        j += 1 while j < out.length && out[j] == "."
        next_bare = (j < out.length) ? out[j].tr("0-2", "") : nil
        unless next_bare && protected_next.include?(next_bare)
          out[i] = "AH0"
          changed = true
        end
      end
      i += 1
    end
    return self unless changed
    has_primary_or_secondary = out.any? { |p| !p.syllable_boundary? && (p.include?("1") || p.include?("2")) }
    unless has_primary_or_secondary
      puts "Protected \"#{to_s}\" from having its schwas dwimmed"
      return self
    end
    self.class.new(out)
  end
  
  def rhyme_signature_array
    # The rhyme signature is everything including and after the final most stressed vowel,
    # which is indicated in cmudict by a "1".
    # Some words don't have a 1, so we settle for the final secondarily-stressed vowel,
    # or failing that, the last vowel.
    #
    # input: [IH0 N S IH1 ZH AH0 N] # the pronunciation of 'incision'
    # output:        [IH  ZH AH  N] # the pronunciation of '-ision' with stress markers removed
    #
    # We remove the stress markers so that we can rhyme 'furs' [F ER1 Z] with 'yours(2)' [Y ER0 Z]
    # They will both have the rhyme signature [ER Z].
    if(empty?)
      [ ]
    else
      rhyme_signature_array_with_stress("1") || rhyme_signature_array_with_stress("2") || rhyme_signature_array_with_stress("0") or raise RuntimeError, "Pronunciation with no vowels: #{self}"
    end
  end

  def rhyme_signature_array_with_stress(stress)
    rsig = Array.new
    @phonemes.reverse.each { |phoneme|
      unless(phoneme.syllable_boundary?)
        rsig.unshift(phoneme.tr("0-2", "")) # we need to remove the numbers
        if(phoneme.include?(stress))
          return rsig # we found the phoneme with stress STRESS, we can stop now
        end
      end
    }
    return nil
  end

  def initial_consonant_cluster_array
    # everything strictly before the first vowel
    rsig = Array.new
    @phonemes.each { |phoneme|
      if phoneme.vowel?
        return rsig
      else
        rsig.push(phoneme)
      end
    }
    return [ ]
  end

  def final_consonant_cluster_array
    # everything strictly after the last vowel
    rsig = Array.new
    @phonemes.reverse.each { |phoneme|
      if phoneme.vowel?
        return rsig
      else
        rsig.unshift(phoneme)
      end
    }
    return [ ]
  end

  def rhyme_signature
    # this makes for a better hash key
    rhyme_signature_array.join("_")
  end

  def rhyme_syllables_array
    # This is like rhyme_signature_array but includes the whole rhyming syllable; it doesn't chop off the preceding consonants.
    if(empty?)
      [ ]
    else
      rhyme_syllables_array_with_stress("1") || rhyme_syllables_array_with_stress("2") || rhyme_syllables_array_with_stress("0") or raise RuntimeError, "Pronunciation with no vowels: #{self}"
    end
  end

  def rhyme_syllables_array_with_stress(stress)
    rsig = Array.new
    foundTheRhymingSyllable = false
    @phonemes.reverse.each { |phoneme|
      unless phoneme.syllable_boundary?
        rsig.unshift(phoneme.tr("0-2", "")) # we need to remove the numbers
      end
      if(!foundTheRhymingSyllable)
        if(phoneme.include?(stress))
          foundTheRhymingSyllable = true; # we found the main stressed vowel, we can stop at the next syllable boundary
        end
      else
        if(phoneme.syllable_boundary?)
          return rsig
        end
      end
    }
    if foundTheRhymingSyllable # we got all the way to the beginning of the word without a syllable break
      return rsig
    end
    return nil
  end

  def rhyme_syllables_string
    rhyme_syllables_array.join(" ")
  end

  def syllabify
    syls = Array.new
    this_syllable = Array.new
    this_initial_consonant_cluster = Array.new
    candidate_initial_consonant_cluster = Array.new
    foundThisSyllablesVowel = false
    @phonemes.reverse.each { |phoneme|
      if !foundThisSyllablesVowel
        this_syllable.unshift(phoneme) # just allow any syllable-final consonant cluster
        if(phoneme.vowel?)
          foundThisSyllablesVowel = true
        end
      else
        # gobble up as many syllable-initial consonants while still being a valid cluster
        candidate_initial_consonant_cluster = this_initial_consonant_cluster.unshift(phoneme)
        if single_consonant?(candidate_initial_consonant_cluster) ||
           ALL_INITIAL_CONSONANT_CLUSTERS.include?(candidate_initial_consonant_cluster.join(" "))
          this_syllable.unshift(phoneme) # PHONEME is legit as a syllable-initial consonant cluster
          this_initial_consonant_cluster = candidate_initial_consonant_cluster
        # puts "#{phoneme} is legit, now we have #{this_syllable} starting with #{this_initial_consonant_cluster}"
        else
          # that's all we can gobble, gotta move on to the next syllable now
          # puts "we've got #{this_syllable}. That's all we can gobble, gotta move on to the next syllable now"
          syls.unshift(this_syllable)
          # add a syllable boundary token
          syls.unshift(".")
          # ok, stick this phoneme at the end of the next syllable (previous, because we're going backward)
          this_syllable = Array.new
          this_initial_consonant_cluster = Array.new
          this_syllable.unshift(phoneme)
          foundThisSyllablesVowel = phoneme.vowel?
        end
      end
    }
    # tack on whatever was left over when we ran out of phonemes
    unless this_syllable.empty?
      syls.unshift(this_syllable)
    end
    sylpron = Pronunciation.new(syls.flatten)
    return sylpron
  end
  
end
