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

    suffix = detect_suffix(base_word, inflected_word)
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

  private

  def self.detect_suffix(base, inflected)
    return nil if inflected.length <= base.length

    # Try exact suffix matches against the base spelling
    if inflected == base + "s" || inflected == base + "es"
      :s
    elsif inflected == base.sub(/y\z/, "ies")
      :s
    elsif inflected == base + "ed"
      :ed
    elsif inflected == base.sub(/e\z/, "ed")
      :ed
    elsif inflected == base.sub(/y\z/, "ied")
      :ed
    elsif doubled_consonant?(base, inflected, "ed")
      :ed
    elsif inflected == base + "ing"
      :ing
    elsif inflected == base.sub(/e\z/, "ing")
      :ing
    elsif doubled_consonant?(base, inflected, "ing")
      :ing
    elsif inflected == base + "er" || inflected == base.sub(/e\z/, "er")
      :er
    elsif inflected == base.sub(/y\z/, "ier")
      :er
    elsif doubled_consonant?(base, inflected, "er")
      :er
    elsif inflected == base + "est" || inflected == base.sub(/e\z/, "est")
      :est
    elsif inflected == base.sub(/y\z/, "iest")
      :est
    elsif doubled_consonant?(base, inflected, "est")
      :est
    else
      nil
    end
  end

  # Handles consonant doubling: "stop" -> "stopped" (base + last_char + suffix)
  def self.doubled_consonant?(base, inflected, suffix)
    return false if base.length < 2
    last_char = base[-1]
    inflected == base + last_char + suffix
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
