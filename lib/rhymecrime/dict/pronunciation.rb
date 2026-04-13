require_relative "phoneme.rb"

class Pronunciation
  attr_reader :phonemes

  # IH not dwimmed when followed by these (after syllable dots); see +with_dwimmed_schwas+.
  DWIMMED_SCHWA_PROTECTED_NEXT = %w[R NG SH].freeze

  def initialize(phonemes)
    @phonemes = phonemes.map { |p| Phoneme.intern(p) }
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
  #
  # Post-tonic *IH* before word-final *N* (IH0, IH1, or IH2): map to AH0 when primary stress (1)
  # already appeared earlier — *takin'*/*taken*, *puffin* (bird IH2), *puffin'*, etc. Skips *begin*
  # (IH1 is the only primary) and leaves IH before NG alone (handled by the general IH0 branch).
  #
  # Other IH0: conflate with AH0 except before R, NG, SH (beer, selfish).
  def with_dwimmed_schwas
    return self if empty?
    out = @phonemes.dup
    len = out.length
    changed = false
    prior_primary = false
    i = 0
    while i < len
      ph = out[i]
      if (ph == "IH0" || ph == "IH1" || ph == "IH2") && prior_primary
        j = i + 1
        j += 1 while j < len && out[j] == "."
        if j < len && out[j].tr("0-2", "") == "N"
          k = j + 1
          k += 1 while k < len && out[k] == "."
          if k >= len
            out[i] = Phoneme.intern("AH0")
            changed = true
          end
        end
      end
      # IH0 still IH0: post-tonic-N branch above matched (prior_primary) but next phone was not
      # word-final N (e.g. *dodges* / *massages* IH0 before Z). Must not be elsif — that skipped this.
      if ph == "IH0" && out[i] == "IH0"
        j = i + 1
        j += 1 while j < len && out[j] == "."
        dwim_ih0 = if j >= len
                     true
                   else
                     nb = out[j].tr("0-2", "")
                     !DWIMMED_SCHWA_PROTECTED_NEXT.include?(nb)
                   end
        if dwim_ih0
          out[i] = Phoneme.intern("AH0")
          changed = true
        end
      end
      if !ph.syllable_boundary? && ph.vowel? && ph.include?("1")
        prior_primary = true
      end
      i += 1
    end
    return self unless changed
    has_primary_or_secondary = out.any? { |p| !p.syllable_boundary? && (p.include?("1") || p.include?("2")) }
    unless has_primary_or_secondary
      if DICT_BUILD_VERBOSE
        puts "Protected \"#{to_s}\" from having its schwas dwimmed"
      end
      return self
    end
    self.class.new(out)
  end

  # GA intervocalic flapping: singleton T between a sonorant (vowel / R) and an
  # unstressed vowel merges with D. Pre-nasal T (kitten, tighten) is excluded
  # because it surfaces as a glottal stop, not a flap.
  def with_flapped_t
    return self if empty?
    out = @phonemes.dup
    changed = false
    out.each_with_index do |phoneme, i|
      next unless phoneme == "T"
      prev = (i > 0) ? out[i - 1] : nil
      next unless prev && (prev.vowel? || prev == "R")
      nxt = (i < out.length - 1) ? out[i + 1] : nil
      next unless nxt && nxt.vowel? && (nxt.include?("0") || nxt.include?("2"))
      after_nxt = (i < out.length - 2) ? out[i + 2] : nil
      next if after_nxt == "N"
      out[i] = Phoneme.intern("D")
      changed = true
    end
    changed ? self.class.new(out) : self
  end

  def rime_array
    return @rime_array if defined?(@rime_array)

    @rime_array = if empty?
                    [].freeze
                  else
                    raw = rime_array_with_stress("1") || rime_array_with_stress("2") || rime_array_with_stress("0") or raise RuntimeError, "Pronunciation with no vowels: #{self}"
                    flap_t_in_rime(raw).freeze
                  end
  end

  ARPABET_VOWELS = %w[AA AE AH AO AW AY EH EY IH IY OW OY UH UW].to_set

  # T→D in the rime only (stress already stripped). AY+T+AH always merges here
  # so recital/suicidal share a bucket; +with_flapped_t+ may still keep lexical T for rsyll.
  def flap_t_in_rime(rime)
    out = rime.dup
    out.each_with_index do |phoneme, i|
      next unless phoneme == "T"
      prev = (i > 0) ? out[i - 1] : nil
      next unless prev && (ARPABET_VOWELS.include?(prev) || prev == "R")
      nxt = (i < out.length - 1) ? out[i + 1] : nil
      next unless nxt && ARPABET_VOWELS.include?(nxt)
      after_nxt = (i < out.length - 2) ? out[i + 2] : nil
      next if after_nxt == "N"
      out[i] = Phoneme.intern("D")
    end
    out
  end

  def rime_array_with_stress(stress)
    rime = Array.new
    @phonemes.reverse.each { |phoneme|
      unless(phoneme.syllable_boundary?)
        rime.unshift(phoneme.tr("0-2", "")) # we need to remove the numbers
        if(phoneme.include?(stress))
          return rime # we found the phoneme with stress STRESS, we can stop now
        end
      end
    }
    return nil
  end

  def initial_consonant_cluster_array
    # everything strictly before the first vowel
    cluster = Array.new
    @phonemes.each { |phoneme|
      if phoneme.vowel?
        return cluster
      else
        cluster.push(phoneme)
      end
    }
    return [ ]
  end

  def final_consonant_cluster_array
    # everything strictly after the last vowel
    cluster = Array.new
    @phonemes.reverse.each { |phoneme|
      if phoneme.vowel?
        return cluster
      else
        cluster.unshift(phoneme)
      end
    }
    return [ ]
  end

  def rime
    return @rime if defined?(@rime)

    @rime = rime_array.join("_").freeze
  end

  # Consonants immediately before the primary-stressed vowel (same syllable); stress digits stripped.
  def primary_stressed_syllable_onset_bases
    ph = @phonemes
    i = ph.index { |p| !p.syllable_boundary? && p.vowel? && p.include?("1") }
    return [] if i.nil?
    onset = []
    (i - 1).downto(0) do |j|
      break if ph[j].syllable_boundary?
      onset.unshift(ph[j].tr("0-2", "")) unless ph[j].vowel?
    end
    onset
  end

  def rhyme_syllables_array
    return @rhyme_syllables_array if defined?(@rhyme_syllables_array)

    @rhyme_syllables_array = if empty?
                               [].freeze
                             else
                               (rhyme_syllables_array_with_stress("1") || rhyme_syllables_array_with_stress("2") || rhyme_syllables_array_with_stress("0") or raise RuntimeError, "Pronunciation with no vowels: #{self}").freeze
                             end
  end

  def rhyme_syllables_array_with_stress(stress)
    parts = Array.new
    foundTheRhymingSyllable = false
    @phonemes.reverse.each { |phoneme|
      unless phoneme.syllable_boundary?
        parts.unshift(phoneme.tr("0-2", "")) # we need to remove the numbers
      end
      if(!foundTheRhymingSyllable)
        if(phoneme.include?(stress))
          foundTheRhymingSyllable = true; # we found the main stressed vowel, we can stop at the next syllable boundary
        end
      else
        if(phoneme.syllable_boundary?)
          return parts
        end
      end
    }
    if foundTheRhymingSyllable # we got all the way to the beginning of the word without a syllable break
      return parts
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
    rev = @phonemes.reverse
    rev_last = rev.length - 1
    rev.each_with_index { |phoneme, rev_idx|
      if !foundThisSyllablesVowel
        this_syllable.unshift(phoneme) # just allow any syllable-final consonant cluster
        if(phoneme.vowel?)
          foundThisSyllablesVowel = true
        end
      else
        # gobble up as many syllable-initial consonants while still being a valid cluster
        candidate_initial_consonant_cluster = this_initial_consonant_cluster.unshift(phoneme)
        cluster_str = candidate_initial_consonant_cluster.join(" ")
        if single_consonant?(candidate_initial_consonant_cluster) ||
           ALL_INITIAL_CONSONANT_CLUSTERS.include?(cluster_str) ||
           (rev_idx == rev_last && WORD_INITIAL_CONSONANT_CLUSTERS.include?(cluster_str))
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
