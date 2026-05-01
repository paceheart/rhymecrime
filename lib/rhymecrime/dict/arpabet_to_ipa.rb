# frozen_string_literal: true
# encoding: utf-8

require_relative "pronunciation"
require_relative "utils_rhyme"

# General American ARPAbet → IPA back-converter, used by dev tools that surface
# proposed phonemic IPA (e.g. +bin/compare-authoritative-vs-kaikki+) so a
# Wiktionary editor has a starting point rather than retranscribing from
# scratch. The output is a slash-wrapped phonemic transcription.
#
# Conventions:
# - Vowels follow Wiktionary's GA inventory: +AH+ → +ʌ+ stressed / +ə+
#   unstressed; +ER+ → +ɝ+ stressed / +ɚ+ unstressed.
# - Affricates +CH+/+JH+ render as +tʃ+/+dʒ+ (no tie bar) since GA Wiktionary
#   pronunciations rarely use ties.
# - Stress marks +ˈ+ / +ˌ+ replace the syllable separator at stressed
#   syllable boundaries. Monosyllables get no stress mark, matching Wiktionary
#   convention (+/kæt/+, not +/ˈkæt/+).
# - User-supplied syllable boundaries (+.+ tokens) are preserved when present;
#   otherwise we re-syllabify with +Pronunciation#syllabify+ (English
#   max-onset phonotactics).
# - Flapping is *not* reversed: a flapped +D+ in the authoritative pron stays
#   +d+ in the IPA. A Wiktionary editor pasting phonemic +/.../+ may need to
#   restore +/t/+ (e.g. +keto+, +whiteout+, +tutti-frutti+).
module ArpabetToIpa
  CONSONANT_TO_IPA = {
    "B" => "b", "CH" => "tʃ", "D" => "d", "DH" => "ð",
    "F" => "f", "G" => "ɡ", "HH" => "h", "JH" => "dʒ",
    "K" => "k", "L" => "l", "M" => "m", "N" => "n",
    "NG" => "ŋ", "P" => "p", "R" => "ɹ", "S" => "s",
    "SH" => "ʃ", "T" => "t", "TH" => "θ", "V" => "v",
    "W" => "w", "Y" => "j", "Z" => "z", "ZH" => "ʒ",
  }.freeze

  # Vowels whose IPA realisation is stress-independent. +AH+ and +ER+ are
  # handled separately (+ʌ/ə+, +ɝ/ɚ+) because GA collapses them to schwa /
  # schwar in unstressed syllables.
  VOWEL_TO_IPA = {
    "AA" => "ɑ", "AE" => "æ",
    "AO" => "ɔ", "AW" => "aʊ", "AY" => "aɪ",
    "EH" => "ɛ", "EY" => "eɪ",
    "IH" => "ɪ", "IY" => "i",
    "OW" => "oʊ", "OY" => "ɔɪ",
    "UH" => "ʊ", "UW" => "u",
  }.freeze

  module_function

  # Convert a +Pronunciation+ (or anything responding to +phonemes+) to a
  # slash-wrapped GA phonemic IPA string. Returns +""+ for empty prons.
  def convert(pron)
    phones = pron.phonemes
    return "" if phones.nil? || phones.empty? || phones.all? { |p| p == "." }

    syls = split_into_syllables(phones)
    parts = syls.map { |syl| syllable_to_ipa(syl) }
    return "" if parts.empty?

    body = if parts.size == 1
             parts.first[:chars]
           else
             render_polysyllabic(parts)
           end
    "/#{body}/"
  end

  # If the user supplied +.+ syllable boundaries, respect them; otherwise
  # delegate to the project's max-onset syllabifier.
  def split_into_syllables(phones)
    if phones.include?(".")
      out = []
      cur = []
      phones.each do |ph|
        if ph == "."
          out << cur unless cur.empty?
          cur = []
        else
          cur << ph
        end
      end
      out << cur unless cur.empty?
      out
    else
      Pronunciation.new(phones).syllabify.syllables
    end
  end

  def syllable_to_ipa(syllable_phonemes)
    stress = 0
    chars = String.new(encoding: Encoding::UTF_8)
    i = 0
    while i < syllable_phonemes.length
      ph = syllable_phonemes[i]
      base = ph.tr("0-2", "")
      ph_stress = (ph =~ /([012])\Z/) ? Regexp.last_match(1).to_i : 0
      stress = ph_stress if ph_stress > stress
      # Within one syllable, +AH# R+ is functionally CMU's +ER#+ (the NURSE
      # vowel). Render as the rhotic vowel +ɝ+ / +ɚ+ so we match Wiktionary's
      # GA convention (e.g. +herder+ → +/ˈhɝdɚ/+, not +/ˈhʌɹdəɹ/+). Other
      # vowel + R sequences (+IY R+, +UH R+, +EH R+, etc.) stay split because
      # GA distinguishes them as separate phonemic vowels.
      if base == "AH" && syllable_phonemes[i + 1] == "R"
        chars << (ph_stress.positive? ? "ɝ" : "ɚ")
        i += 2
        next
      end
      chars << ipa_for(base, ph_stress)
      i += 1
    end
    { stress: stress, chars: chars }
  end

  def ipa_for(base, stress)
    case base
    when "AH" then stress.positive? ? "ʌ" : "ə"
    when "ER" then stress.positive? ? "ɝ" : "ɚ"
    else
      VOWEL_TO_IPA[base] || CONSONANT_TO_IPA[base] || "?"
    end
  end

  def render_polysyllabic(parts)
    out = String.new(encoding: Encoding::UTF_8)
    parts.each_with_index do |part, i|
      sep = case part[:stress]
            when 1 then "ˈ"
            when 2 then "ˌ"
            else (i.zero? ? "" : ".")
            end
      out << sep << part[:chars]
    end
    out
  end
end
