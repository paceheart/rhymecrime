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

    base_phonemes = base_pron.phonemes.reject { |p| p == "." }
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
  def self.each_derivable_form(base)
    return if base.nil? || base.empty?

    bl = base.bytesize
    yield base + "s"
    yield base + "es"

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
