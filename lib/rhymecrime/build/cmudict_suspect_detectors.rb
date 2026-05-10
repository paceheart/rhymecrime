# frozen_string_literal: true
# encoding: utf-8

# Heuristic detectors for questionable CMUdict 0.7c pronunciations (triage for
# curated/authoritative_pronunciations.txt). See bin/audit-cmudict-suspects.
#
# Caveats:
# - Duplicate-variant scan finds every repeated phone row per headword (often benign CMU clutter).
# - Idea 2 (Kaikki) emits only when Pronunciation#rime differs; remaining hits may still include
#   acceptable variants — use Zipf + ear-check before overriding.
# - Truncation heuristic is intentionally narrow (high Zipf, many vowel letters, tiny phone count).
# - Single-substitution uses normalization *without* flapping so T/D disagreements are visible.

require "set"
require_relative "../io_utils"
require_relative "../phoneme"
require_relative "../pronunciation"
require_relative "../wordfreq_zipf_constants"
require_relative "phonology"

module CmudictSuspectDetectors
  module_function

  # @return [Array<Hash>] each hash includes :base, :pron_string, :occurrences (count), :alts (e.g. [0, 1])
  def duplicate_alternate_prons(cmudict_path)
    by_base = Hash.new { |h, k| h[k] = Hash.new { |h2, k2| h2[k2] = [] } } # base => pron_str => [alt_nums]
    IoUtils.foreach(cmudict_path, encoding: "UTF-8", hint: "cmudict_dupes") do |line|
      row = parse_cmu_line(line)
      next unless row

      pron_str = row[:pron_tokens].join(" ")
      by_base[row[:base]][pron_str] << row[:alt_num]
    end
    out = []
    by_base.each do |base, pron_to_alts|
      pron_to_alts.each do |pron_str, alts|
        next if alts.uniq.size < 2

        out << {
          base: base,
          pron_string: pron_str,
          occurrences: alts.size,
          alts: alts.sort.uniq,
        }
      end
    end
    out.sort_by { |h| [h[:base], h[:pron_string]] }
  end

  # CMU primary stress = ordinal of the vowel token carrying stress digit "1" (0-based).
  # Returns nil if there is no primary-stressed vowel in the flat pronunciation.
  def primary_stressed_vowel_ordinal(pron)
    i = 0
    pron.phonemes.each do |p|
      next if p.syllable_boundary?
      next unless p.vowel?

      return i if p.include?("1")

      i += 1
    end
    nil
  end

  def vowel_phone_count(pron)
    pron.phonemes.count { |p| !p.syllable_boundary? && p.vowel? }
  end

  # Orthographic vowel letters (A E I O U Y), uppercase headword only — matches CMU surface.
  def orthographic_vowel_letters(headword)
    headword.count("AEIOUY")
  end

  # Idea 2: CMU primary vs Kaikki first pron, after shared flat normalization — compute
  # Pronunciation#rime for each (rightmost stress-1 nucleus through word end, per rime_array).
  # Emits a row only when the two rime strings differ (e.g. *potboiler*). Pairs like *engineer*
  # where only which syllable gets digit +1+ differs share the same rime and are skipped.
  #
  # @param kaikki_pron_hash [Hash{String=>Array<Pronunciation>}]
  # @param wordfreq_hash [Hash{String=>Float}] Zipf scale
  def stress_disagreement_with_kaikki(cmudict_path, kaikki_pron_hash, wordfreq_hash, min_zipf: WORDFREQ_COMMON_ZIPF,
                                      min_word_len: 8, min_vowel_phones: 3, skip_bases: Set.new)
    rows = []
    cmu_primary_by_base = cmu_first_variant_by_base(cmudict_path)
    cmu_primary_by_base.each do |base, tokens|
      next if skip_bases.include?(base)
      next if base.length < min_word_len

      zipf = wordfreq_hash[base] || 0
      next if zipf < min_zipf

      wk = kaikki_pron_hash[base]
      next if wk.nil? || wk.empty?

      cmu_pron = normalize_flat_arphabet_pronunciation(Pronunciation.new(tokens))
      wk_pron = normalize_flat_arphabet_pronunciation(wk.first)
      next if cmu_pron.empty? || wk_pron.empty?

      vc = vowel_phone_count(cmu_pron)
      next if vc < min_vowel_phones
      next if vowel_phone_count(wk_pron) != vc

      cmu_rime = cmu_pron.rime
      kaikki_rime = wk_pron.rime
      next if cmu_rime == kaikki_rime

      rows << {
        base: base,
        zipf: zipf,
        cmu_rime: cmu_rime,
        kaikki_rime: kaikki_rime,
        cmu: cmu_pron.to_s,
        kaikki: wk_pron.to_s,
      }
    end
    rows.sort_by { |h| [-h[:zipf], h[:base]] }
  end

  # Idea 4: high Zipf headword whose CMU primary has far fewer vowel nuclei than spelling suggests.
  def truncated_or_under_specified_prons(cmudict_path, wordfreq_hash, min_zipf: WORDFREQ_COMMON_ZIPF,
                                         min_orthographic_vowels: 3, max_arpa_vowel_phones: 1, max_non_dot_phones: 4)
    rows = []
    cmu_primary_by_base = cmu_first_variant_by_base(cmudict_path)
    cmu_primary_by_base.each do |base, tokens|
      zipf = wordfreq_hash[base] || 0
      next if zipf < min_zipf

      head = base.upcase # CMU uses ASCII letters; good enough for vowel letter count
      ov = orthographic_vowel_letters(head)
      next if ov < min_orthographic_vowels

      pron = normalize_flat_arphabet_pronunciation(Pronunciation.new(tokens))
      arpa_v = vowel_phone_count(pron)
      next if arpa_v > max_arpa_vowel_phones

      nd = pron.phonemes.reject { |p| p.syllable_boundary? }.size
      next if nd > max_non_dot_phones

      rows << {
        base: base,
        zipf: zipf,
        orthographic_vowels: ov,
        arpa_vowel_phones: arpa_v,
        non_dot_phones: nd,
        cmu: pron.to_s,
      }
    end
    rows.sort_by { |h| [-h[:zipf], h[:base]] }
  end

  # Idea 5: CMU vs Kaikki first pron differ by exactly one ARPAbet token (after bare-base / stress strip),
  # same length — typical T/D style segment errors in loans.
  def single_phone_substitution_vs_kaikki(cmudict_path, kaikki_pron_hash, wordfreq_hash, min_zipf: WORDFREQ_RARE_ZIPF + 0.5,
                                         min_word_len: 4, min_phones: 3, skip_bases: Set.new)
    rows = []
    cmu_primary_by_base = cmu_first_variant_by_base(cmudict_path)
    cmu_primary_by_base.each do |base, tokens|
      next if skip_bases.include?(base)
      next if base.length < min_word_len

      zipf = wordfreq_hash[base] || 0
      next if zipf < min_zipf

      wk = kaikki_pron_hash[base]
      next if wk.nil? || wk.empty?

      # Without flapping: intervocalic T/D are not conflated, so CMU errors like SATYR (D for T) surface.
      cmu_pron = normalize_flat_arphabet_pronunciation(Pronunciation.new(tokens), apply_flap: false)
      wk_pron = normalize_flat_arphabet_pronunciation(wk.first, apply_flap: false)
      a = cmu_pron.phonemes.reject { |p| p.syllable_boundary? }
      b = wk_pron.phonemes.reject { |p| p.syllable_boundary? }
      next if a.length < min_phones
      next unless a.length == b.length

      diffs = 0
      a.each_index do |i|
        diffs += 1 if Phoneme.bare_base(a[i]) != Phoneme.bare_base(b[i])
      end
      next unless diffs == 1

      rows << {
        base: base,
        zipf: zipf,
        cmu: cmu_pron.to_s,
        kaikki: wk_pron.to_s,
      }
    end
    rows.sort_by { |h| [-h[:zipf], h[:base]] }
  end

  # --- parsing ---

  def parse_cmu_line(line)
    return nil unless useful_cmudict_line?(line)

    line = preprocess_cmudict_line(line)
    tokens = line.split
    return nil if tokens.length < 2

    raw_word = tokens.shift
    alt_num = if raw_word =~ /\(([0-9])\)\z/
                Regexp.last_match(1).to_i
              else
                0
              end
    base = raw_word.downcase.desanitize
    base = base[0...-3] if base =~ /\([0-9]\)\z/

    {
      base: base,
      raw_word: raw_word,
      alt_num: alt_num,
      pron_tokens: tokens,
    }
  end
  private_class_method :parse_cmu_line

  # First CMU variant per base (primary line before numbered alternates), preprocessed phoneme tokens.
  def cmu_first_variant_by_base(cmudict_path)
    order = Hash.new { |h, k| h[k] = [] }
    IoUtils.foreach(cmudict_path, encoding: "UTF-8", hint: "cmudict_primary") do |line|
      row = parse_cmu_line(line)
      next unless row

      order[row[:base]] << row
    end
    first = {}
    order.each do |base, list|
      primary = list.min_by { |r| r[:alt_num] }
      first[base] = primary[:pron_tokens]
    end
    first
  end
  private_class_method :cmu_first_variant_by_base
end
