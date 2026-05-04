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
        if j < len && Phoneme.bare_base(out[j]) == "N"
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
                     nb = Phoneme.bare_base(out[j])
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
    has_primary_or_secondary = false
    j = 0
    while j < len
      p = out[j]
      if !p.syllable_boundary? && (p.include?("1") || p.include?("2"))
        has_primary_or_secondary = true
        break
      end
      j += 1
    end
    unless has_primary_or_secondary
      if DICT_BUILD_VERBOSE
        puts "Protected \"#{to_s}\" from having its schwas dwimmed"
      end
      return self
    end
    self.class.new(out)
  end

  # GA intervocalic flapping: singleton T between a sonorant (vowel / R) and a
  # *reduced* vowel merges with D. Pre-nasal T (kitten, tighten) is excluded
  # because it surfaces as a glottal stop, not a flap. Both this full-pron pass
  # and the rime-level pass below share +flap_t_target?+ — the linguistic rule.
  def with_flapped_t
    return self if empty?
    out = @phonemes.dup
    changed = false
    out.each_with_index do |phoneme, i|
      next unless Pronunciation.flap_t_target?(out, i)
      out[i] = Phoneme.intern("D")
      changed = true
    end
    changed ? self.class.new(out) : self
  end

  # Bases of the flap-permissible (reduced) ARPAbet vowels: schwa /ə/ (AH0),
  # lax /ɪ/ (IH0), and morpheme-final/prevocalic /i, oʊ/ (IY/OW). Other vowels —
  # UW (tutu, bluetooth), EY (retail), AA/AO (botox, blowtorch), EH (latex), AW
  # (whiteout, baytown — also blocked separately by the pre-N glottal carve-out),
  # AY/OY/AE — do not reduce, so flapping is blocked when CMU marks the post-T
  # vowel with secondary stress in those classes. See Wikipedia on Flapping
  # (Distribution): "the vowel following the flap must … be a reduced one
  # (namely /ə/, morpheme-final or prevocalic /i, oʊ/, or /ɪ/ preceding /ŋ/, /k/,
  # etc.), so words like botox, retail, and latex are not flapped …"
  FLAP_T_REDUCIBLE_BASES = %w[AH IH IY OW].to_set.freeze

  # Should the +T+ at +phonemes[i]+ flap to +D+? Operates on stress-bearing
  # phonemes (no syllable dots) — both +with_flapped_t+ (flat pron) and
  # +flap_t_in_rime+ (rime with stress preserved) feed it the right shape.
  def self.flap_t_target?(phonemes, i)
    return false unless phonemes[i] == "T"
    prev = (i > 0) ? phonemes[i - 1] : nil
    return false unless prev && (prev.vowel? || prev == "R")
    nxt = (i < phonemes.length - 1) ? phonemes[i + 1] : nil
    return false unless nxt && nxt.vowel?
    after_nxt = (i < phonemes.length - 2) ? phonemes[i + 2] : nil
    # Pre-nasal T (kitten, tighten) glottalizes, doesn't flap.
    return false if after_nxt == "N"
    base = nxt.tr("0-2", "")
    return false unless FLAP_T_REDUCIBLE_BASES.include?(base)
    if nxt.include?("0")
      true
    elsif nxt.include?("2")
      # Stress-2 only flaps when /i, oʊ/ sit at a morpheme-final or prevocalic
      # right edge — the potato/tomato OW2 case. Schwa never carries stress 2,
      # and IH2 in this slot is vanishingly rare; restricting to IY/OW keeps
      # the rule honest. (CMU's /uː/ tutu/bluetooth UW2 is full vowel and is
      # already excluded above by the base check.)
      (base == "IY" || base == "OW") && (after_nxt.nil? || after_nxt.vowel?)
    else
      # Stress 1 — never flap.
      false
    end
  end

  def rime_array
    return @rime_array if defined?(@rime_array)

    @rime_array = if empty?
                    [].freeze
                  else
                    raw = rime_array_with_stress("1") || rime_array_with_stress("2") || rime_array_with_stress("0") or raise RuntimeError, "Pronunciation with no vowels: #{self}"
                    flapped = flap_t_in_rime(raw)
                    flapped.map { |p| Phoneme.intern(p.tr("0-2", "")) }.freeze
                  end
  end

  ARPABET_VOWELS = %w[AA AE AH AO AW AY EH EY IH IY OW OY UH UW].to_set

  # T→D in the rime, applied while stress digits are still attached so we can
  # honor the reducibility rule (see +flap_t_target?+). +rime_array+ strips
  # stress after this pass. AY+T+AH0 still merges here for recital/suicidal
  # because AH0 is reducible; UW1+T+UW2 in tutu correctly does not, so the
  # rime is +UW_T_UW+ rather than collapsing into voodoo's +UW_D_UW+.
  def flap_t_in_rime(rime)
    out = rime.dup
    out.each_with_index do |phoneme, i|
      out[i] = Phoneme.intern("D") if Pronunciation.flap_t_target?(out, i)
    end
    out
  end

  def rime_array_with_stress(stress)
    rime = Array.new
    @phonemes.reverse.each { |phoneme|
      unless(phoneme.syllable_boundary?)
        rime.unshift(phoneme) # stress digits stay; +rime_array+ strips after the flap pass
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

  def rich_rime_array
    return @rich_rime_array if defined?(@rich_rime_array)

    @rich_rime_array = if empty?
                         [].freeze
                       else
                         (rich_rime_array_with_stress("1") || rich_rime_array_with_stress("2") || rich_rime_array_with_stress("0") or raise RuntimeError, "Pronunciation with no vowels: #{self}").freeze
                       end
  end

  def rich_rime_array_with_stress(stress)
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

  def rich_rime
    rich_rime_array.join(" ")
  end

  # +rich_rime+ starts at the beginning of the primary-stress syllable while
  # +rime+ starts at the primary-stress vowel itself. When that syllable has
  # no onset consonant, the two cover identical spans and +rich_rime+ carries
  # zero information beyond +rime+. Call that a +trivially_rich_rime?+: any
  # cross-word match on +rich_rime+ in this case is equivalent to a plain
  # rime match, not a true rich rhyme (which requires the onset to match
  # too). Length-compares the underlying arrays — flap-T normalization in
  # +rime_array+ shifts phoneme identity (T → D) but preserves length, and
  # both arrays share the same end and the same stress-digit stripping.
  def trivially_rich_rime?
    rich_rime_array.length == rime_array.length
  end

  def nontrivially_rich_rime?
    !trivially_rich_rime?
  end

  # Split +@phonemes+ on +.+ tokens into per-syllable arrays. Cheap; used by
  # the vowel-count invariant and any caller that needs a structural view of
  # an already-syllabified pronunciation.
  def syllables
    out = []
    cur = []
    @phonemes.each do |ph|
      if ph.syllable_boundary?
        out << cur unless cur.empty?
        cur = []
      else
        cur << ph
      end
    end
    out << cur unless cur.empty?
    out
  end

  # Per-syllable vowel count. CMUDict encodes every syllable nucleus as a
  # vowel symbol (AA/AE/AH/AO/AW/AY/EH/ER/EY/IH/IY/OW/OY/UH/UW with a stress
  # digit), including syllabic consonants (rhythm = R IH1 DH AH0 M, with the
  # syllabic /m/ rendered as schwa AH0). Under that convention every well-
  # formed syllable has exactly one vowel — the +syllable_vowel_invariant+
  # check exploits this.
  def syllable_vowel_counts
    syllables.map { |syl| syl.count(&:vowel?) }
  end

  # Invariant: every syllable has exactly one vowel. Returns +true+ if so,
  # +false+ for an empty pronunciation or any syllable with 0 / >=2 vowels.
  # Empty pron is treated as a violation so callers don't have to special-
  # case it; all real call sites operate on non-empty prons.
  def syllable_vowel_invariant_ok?
    counts = syllable_vowel_counts
    !counts.empty? && counts.all? { |n| n == 1 }
  end

  # Human-readable description of the first vowel-count violation in this
  # pronunciation (e.g. "syllable 2 has 0 vowels: L AH0 JH IH1 D AH0 M AH0 T").
  # Returns +nil+ when the invariant holds. Used by build-time warnings and
  # by the standalone audit tool to point at the offending syllable.
  def syllable_vowel_invariant_violation
    counts = syllable_vowel_counts
    return "no syllables (empty pronunciation)" if counts.empty?
    syls = syllables
    counts.each_with_index do |n, i|
      next if n == 1
      return "syllable #{i + 1} has #{n} vowels: #{syls[i].join(' ')}"
    end
    nil
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
    # tack on whatever was left over when we ran out of phonemes. If the leftover
    # has no vowel — non-English initial clusters that aren't in
    # +WORD_INITIAL_CONSONANT_CLUSTERS+ (sbarro/SB, schneider/SHN, svelte/SV,
    # tsunami/TS, voila/VW, vroom/VR) — merge it onto the front of the first
    # vowel-bearing syllable instead of letting it stand as a vowelless syllable
    # of its own (which would violate +syllable_vowel_invariant_ok?+).
    unless this_syllable.empty?
      if this_syllable.any?(&:vowel?) || syls.empty?
        syls.unshift(this_syllable)
      else
        # find the first non-"." entry (the next real syllable) and merge into it
        first_real_idx = syls.index { |e| e != "." }
        if first_real_idx
          syls[first_real_idx] = this_syllable + syls[first_real_idx]
          # drop the now-redundant leading "." if we merged into the first syllable
          syls.shift if first_real_idx == 1 && syls.first == "."
        else
          syls.unshift(this_syllable)
        end
      end
    end
    sylpron = Pronunciation.new(syls.flatten)
    return sylpron
  end
  
end
