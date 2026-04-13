# encoding: utf-8
# Derives pronunciations for inflected word forms from a base pronunciation.
# Uses English suffix phonology rules to append the correct phonemes.

require 'set'
require_relative 'pronunciation'

module Inflect
  VOICELESS = Set.new(%w[P T K F TH S SH CH])
  SIBILANTS = Set.new(%w[S Z SH ZH CH JH])

  # Given a base word's Pronunciation and the inflected spelling,
  # detect which suffix was added and return a new Pronunciation
  # with the appropriate phonemes appended. Returns nil if the
  # suffix can't be determined or doesn't apply.
  def self.derive(base_pron, base_word, inflected_word)
    return nil if base_pron.nil? || base_pron.empty?

    base_phonemes = base_pron.phonemes.each_with_object([]) { |p, a| a << p unless p == "." }
    return nil if base_phonemes.empty?

    suffix = match_suffix_kind(base_word, inflected_word)
    return nil if suffix.nil?

    final = base_phonemes.last
    final_bare = final.tr("0-2", "")

    new_phonemes = case suffix
    when :s
      if SIBILANTS.include?(final_bare)
        base_phonemes + ["IH0", "Z"]
      elsif VOICELESS.include?(final_bare)
        base_phonemes + ["S"]
      else
        base_phonemes + ["Z"]
      end
    when :ed
      if final_bare == "T" || final_bare == "D"
        base_phonemes + ["IH0", "D"]
      elsif VOICELESS.include?(final_bare)
        base_phonemes + ["T"]
      else
        base_phonemes + ["D"]
      end
    when :ing
      trimmed = trim_for_ing(base_phonemes, base_word)
      trimmed + ["IH0", "NG"]
    when :er
      base_phonemes + ["ER0"]
    when :est
      base_phonemes + ["AH0", "S", "T"]
    else
      nil
    end

    return nil if new_phonemes.nil?
    Pronunciation.new(new_phonemes)
  end

  # True if +inflected+ matches one of the English suffix patterns handled by +derive+
  # (+s+/+es+, +ed+, +ing+, +er+, +est+, y→ies, doubled consonant, etc.) for this +base+.
  def self.inflection_of_base?(base, inflected)
    return false if base.nil? || inflected.nil?
    return false if inflected.length <= base.length
    !match_suffix_kind(base, inflected).nil?
  end

  # Yields spellings derivable from +base+ by the same surface rules as +match_suffix_kind+
  # (forward direction only). Used to propagate frequency from high-frequency bases without
  # O(n²) “every rare word × every base” scans.
  # Yields base spellings +b+ such that +inflection_of_base?(b, inflected)+ (inverse of
  # +each_derivable_form+). Bounded small set per word; used to avoid Phase 9 O(|hash|×|common|).
  def self.each_candidate_base_for_inflected(inflected)
    return enum_for(__method__, inflected) unless block_given?

    il = inflected.bytesize
    return if il < 2

    cands = []
    push = lambda do |b|
      next if b.nil? || b.empty?

      bl = b.bytesize
      cands << b if bl < il
    end

    # y → ies / ied / ier / iest
    if inflected.end_with?("iest") && il >= 5
      stem = inflected.byteslice(0, il - 4)
      push.call(stem + "y") if stem.bytesize >= 1
    end
    %w[ies ied ier].each do |suf|
      next unless inflected.end_with?(suf) && il >= suf.bytesize + 1

      stem = inflected.byteslice(0, il - suf.bytesize)
      push.call(stem + "y") if stem.bytesize >= 1
    end

    # silent trailing e → stem + ed / ing / er / est
    if inflected.end_with?("ed") && il >= 3
      stem = inflected.byteslice(0, il - 2)
      push.call(stem + "e") if stem.bytesize >= 1
    end
    if inflected.end_with?("ing") && il >= 4
      stem = inflected.byteslice(0, il - 3)
      push.call(stem + "e") if stem.bytesize >= 1
    end
    if inflected.end_with?("er") && il >= 3 && !inflected.end_with?("ier")
      stem = inflected.byteslice(0, il - 2)
      push.call(stem + "e") if stem.bytesize >= 1
    end
    if inflected.end_with?("est") && il >= 4 && !inflected.end_with?("iest")
      stem = inflected.byteslice(0, il - 3)
      push.call(stem + "e") if stem.bytesize >= 1
    end

    # consonant doubling undo (B + c + ed / ing / er / est)
    if inflected.end_with?("ed") && il >= 5 &&
        inflected.getbyte(il - 3) == inflected.getbyte(il - 4)
      push.call(inflected.byteslice(0, il - 3))
    end
    if inflected.end_with?("ing") && il >= 6 &&
        inflected.getbyte(il - 4) == inflected.getbyte(il - 5)
      push.call(inflected.byteslice(0, il - 4))
    end
    if inflected.end_with?("er") && il >= 5 && !inflected.end_with?("ier") &&
        inflected.getbyte(il - 3) == inflected.getbyte(il - 4)
      push.call(inflected.byteslice(0, il - 3))
    end
    if inflected.end_with?("est") && il >= 6 && !inflected.end_with?("iest") &&
        inflected.getbyte(il - 4) == inflected.getbyte(il - 5)
      push.call(inflected.byteslice(0, il - 4))
    end

    # direct suffix after base
    if inflected.end_with?("s") && il >= 2
      push.call(inflected.byteslice(0, il - 1))
    end
    if inflected.end_with?("es") && il >= 3
      push.call(inflected.byteslice(0, il - 2))
    end
    if inflected.end_with?("ed") && il >= 3
      push.call(inflected.byteslice(0, il - 2))
    end
    if inflected.end_with?("ing") && il >= 4
      push.call(inflected.byteslice(0, il - 3))
    end
    if inflected.end_with?("er") && il >= 3
      push.call(inflected.byteslice(0, il - 2))
    end
    if inflected.end_with?("est") && il >= 4
      push.call(inflected.byteslice(0, il - 3))
    end

    cands.uniq.each do |b|
      yield b if inflection_of_base?(b, inflected)
    end

    nil
  end

  def self.each_derivable_form(base)
    return if base.nil? || base.empty?

    bl = base.bytesize
    yield base + "s"
    # Plural -es attaches to the stem after silent-e (fox→foxes), not as base+"es" (annualizees junk).
    yield base + "es" unless base.end_with?("e") && !base.end_with?("ee")

    if base.end_with?("y") && bl >= 2
      stem = base.byteslice(0, bl - 1)
      yield stem + "ies"
      yield stem + "ied"
      yield stem + "ier"
      yield stem + "iest"
    end

    if base.end_with?("e") && bl >= 2 && !base.end_with?("ee")
      stem = base.byteslice(0, bl - 1)
      yield stem + "ed"
      yield stem + "ing"
      yield stem + "er"
      yield stem + "est"
    else
      yield base + "ed"
      yield base + "ing"
      yield base + "er"
      yield base + "est"
    end

    # Consonant doubling (stop → stopped). Skip vowel-final bases — avoids annualize+e+ed junk.
    if bl >= 2
      lc = base[-1]
      unless lc.match?(/\A[aeiouy]\z/i)
        yield base + lc + "ed"
        yield base + lc + "ing"
        yield base + lc + "er"
        yield base + lc + "est"
      end
    end

    nil
  end

  # Colloquial g-dropped spelling *…in'* from verbal *…ing* and the same +base+ as +match_suffix_kind+.
  # Returns nil unless +ing_w+ is the canonical Inflect participle of +base+ (same cases as +:ing+).
  def self.gdropped_in_apostrophe_spelling(base, ing_w)
    return nil unless inflection_of_base?(base, ing_w)
    return nil unless match_suffix_kind(base, ing_w) == :ing

    bl = base.bytesize
    il = ing_w.bytesize

    if base.end_with?("y") && bl >= 2
      stem = base.byteslice(0, bl - 1)
      return stem + "yin'" if ing_w == stem + "ying"
    end

    if base.end_with?("e") && bl >= 2 && !base.end_with?("ee")
      stem = base.byteslice(0, bl - 1)
      return stem + "in'" if ing_w == stem + "ing"
    end

    return nil unless ing_w.start_with?(base)
    rest = ing_w.byteslice(bl, il - bl)
    return base + "in'" if rest == "ing"

    if bl >= 2 && il == bl + 1 + 3 && ing_w.end_with?("ing") && ing_w.getbyte(bl) == base.getbyte(bl - 1)
      return base + base[-1] + "in'"
    end

    nil
  end

  private

  # Returns :s, :ed, :ing, :er, :est, or nil. Shared by +derive+ and +inflection_of_base?+.
  # Ordered for cheap rejects: length, y/silent-e (no +base+ allocations), then start_with? + rest.
  def self.match_suffix_kind(base, inflected)
    bl = base.bytesize
    il = inflected.bytesize
    return nil if il <= bl

    # --- y → ies / ied / ier / iest (does not start_with?(base)) ---
    if base.end_with?("y") && bl >= 2
      stem = base.byteslice(0, bl - 1)
      case il
      when bl + 2 # stem + "ies" / "ied" / "ier" all length stem+3 = (bl-1)+3 = bl+2
        if inflected == stem + "ies"
          return :s
        elsif inflected == stem + "ied"
          return :ed
        elsif inflected == stem + "ier"
          return :er
        end
      when bl + 3 # stem + "iest" = (bl-1)+4 = bl+3
        return :est if inflected == stem + "iest"
      end
    end

    # --- silent trailing e → stem + ed/ing/er/est ---
    if base.end_with?("e") && bl >= 2 && !base.end_with?("ee")
      stem = base.byteslice(0, bl - 1)
      return :ed if inflected == stem + "ed"
      return :ing if inflected == stem + "ing"
      return :er if inflected == stem + "er"
      return :est if inflected == stem + "est"
    end

    # --- direct suffix after base ---
    return nil unless inflected.start_with?(base)
    rest = inflected.byteslice(bl, il - bl)
    # annualize+es→annualizees is not English; real plural is annualize+s (annualizes).
    if rest == "es" && base.end_with?("e") && !base.end_with?("ee") && inflected == base + "es"
      return nil
    end
    case rest
    when "s", "es"
      return :s
    when "ed"
      return :ed
    when "ing"
      return :ing
    when "er"
      return :er
    when "est"
      return :est
    end

    # --- consonant doubling: stop → stopped / stopping / stopper / stoppest ---
    return nil if bl < 2
    doubled = base.getbyte(bl - 1)
    return nil unless inflected.getbyte(bl) == doubled

    return :ed if inflected.end_with?("ed") && il == bl + 1 + 2
    return :ing if inflected.end_with?("ing") && il == bl + 1 + 3
    return :er if inflected.end_with?("er") && il == bl + 1 + 2
    return :est if inflected.end_with?("est") && il == bl + 1 + 3

    nil
  end

  # For -ing, if the base word ends in a silent-e pattern (e.g., "dance" -> "dancing"),
  # the final schwa from the -e may need to be removed.
  # For consonant doubling cases (e.g., "stop" -> "stopping"), no trim needed.
  def self.trim_for_ing(phonemes, base_word)
    return phonemes unless base_word.end_with?("e") && !base_word.end_with?("ee")

    if phonemes.length >= 2
      second_last = phonemes[-2].tr("0-2", "")
      last = phonemes[-1].tr("0-2", "")
      # If word ends in consonant (like "dance" = D AE1 N S), keep as-is
      # If word ends in vowel+consonant pattern from silent-e, keep as-is
      # The silent-e doesn't add a phoneme in most cases, so no trim needed
    end
    phonemes
  end
end
