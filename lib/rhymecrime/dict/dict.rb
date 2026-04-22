#!/usr/bin/env ruby
# encoding: utf-8
#
# RhymeCrime dictionary compiler entrypoint: CMU + Wiktionary/Kaikki + frequency phases → <repo>/generated/*.
# Prefer: ./bin/dict-build from the repo root (loads this file with cwd = this directory, then runs rebuild).
#
# Implementation is split under this directory by concern:
#
#   Dependency direction (load order):
#     constants     — paths, thresholds, export headers
#       → phonology — CMU + ARPAbet + syllabification + Wiktionary pronunciation merge
#       → lexical   — WordNet + POS layers (+ inflect Zipf probes for POS pruning)
#       → morphology — inflection policy + Kaikki-derived surface pronunciations
#       → rime      — rime index build / merge / rare-bucket prune / filter_cmudict
#       → frequency — SUBTLEX + wordfreq + compute_frequency + add_frequency_info + build_word_dict
#         (build_word_dict merges pronunciations into rdict, strips dispreferred spellings from cohorts,
#          prunes weak rime buckets, drops freq==0 orphans
#          per disconnect: wordfreq TSV row ⇒ keep; strict OOV ⇒ Kaikki/SUBTLEX rescue only, not rhyme-alone)
#          Rare headword omission for export runs in +rebuild_rhymecrime_dictionaries+ after hyphen-map keys snapshot.)
#     this file     — rebuild_rhymecrime_dictionaries only
#
# Corpus inputs live under <repo>/corpora/. Invoked by bin/dict-build.
# ConceptNet lemma cache under generated/ is created by setup.sh after downloading assertions, or
# automatically at the start of this rebuild if it is missing or older than assertions.gz.
#
# Fast iteration: set RHYMECRIME_DICT_SKIP_CONCEPTNET_NUMBERBATCH=1 to skip the slow ConceptNet and
# Numberbatch exports at the end (hyphen map and word_dict still run). Default is to rebuild everything.

require "rwordnet"
require "json"
require "set"
require_relative "utils_rhyme"
require_relative "phoneme.rb"
require_relative "pronunciation.rb"
require_relative "wiktionary"
require_relative "varcon"
require_relative "inflect"

require_relative "constants"
require_relative "phonology"
require_relative "lexical"
require_relative "morphology"
require_relative "rime"
require_relative "frequency"
require_relative "corpus_variants"

$inflection_base_words = {}

# Lazy path -> frozen Hash of 8-digit synset offset string -> full data-file line (+wn_synset_line_for_offset+).
$wn_synset_line_index_by_path = nil

def skip_conceptnet_numberbatch_dict_exports?
  v = ENV["RHYMECRIME_DICT_SKIP_CONCEPTNET_NUMBERBATCH"]
  v && !v.empty? && %w[1 true yes on].include?(v.downcase)
end

# True when +word+ and +base+ share at least one WordNet synset (any POS).
def wn_share_synset?(word, base)
  word_offsets = Set.new
  [word, hyphens_to_underscores(word), word.tr("_", "-")].uniq.each do |f|
    wn_lemma_find_all_cached(f).each do |lem|
      lem.synsets.each { |s| word_offsets.add([s.pos, s.pos_offset]) }
    end
  end
  return false if word_offsets.empty?

  [base, hyphens_to_underscores(base), base.tr("_", "-")].uniq.each do |f|
    wn_lemma_find_all_cached(f).each do |lem|
      lem.synsets.each { |s| return true if word_offsets.include?([s.pos, s.pos_offset]) }
    end
  end
  false
end

# Same-lexeme check for dict lemmas: shared synset; cheap suffix-specific checks; then 1-hop derivation
# (file-based, 3.1-safe). Derivation is last and walks WN data for +word+ when earlier checks fail.
def wn_accept_inflection_lemma_pair?(word, base)
  wn_share_synset?(word, base) ||
    wn_verb_stem_via_morphy?(word, base) ||
    wn_productive_affix_lemma_pair?(word, base) ||
    wn_derivationally_related_to_base?(word, base)
end

# Build a hash mapping each word_dict headword to its base/lemma form.
# Source A: $inflection_base_words (Kaikki forms_map — populated earlier in rebuild).
# Source B: Inflect.each_candidate_base_for_inflected picks the best base already in word_dict.
# Words with a WordNet entry and an :er/:est suffix keep themselves (singer, faster are standalone).
# For Source B, if the word has a WordNet entry then the candidate base must pass
# +wn_accept_inflection_lemma_pair?+ (shared synset, 1-hop derivation pointers, guarded -ly/-ful,
# or unique verbal morphy for Inflect *-ed* / *-ing*). This blocks false stems like crew→crow when
# no link matches.
# Fallback: self-lemma (word is its own base).
def compute_lemma_map(word_dict)
  lemma_map = {}
  begin
    word_dict.each_key do |word|
      # Source A: Kaikki-derived base (Wiktionary explicitly lists the relationship).
      # When the word has a WN entry, require +wn_accept_inflection_lemma_pair?+ — Kaikki can link
      # archaic/dialectal inflections (crew→crow, feed→fee) that mislead the common-sense lemma.
      kaikki_base = $inflection_base_words[word]
      if kaikki_base && kaikki_base != word && word_dict.key?(kaikki_base)
        if !wn_has_entry?(word) || wn_accept_inflection_lemma_pair?(word, kaikki_base)
          lemma_map[word] = kaikki_base
          next
        end
      end

      word_in_wn = wn_has_entry?(word)

      # Source B: Inflect candidate bases present in word_dict (skip when no morphological suffix shape).
      raw_bases = Inflect.raw_candidate_bases_for_inflected(word)
      next if raw_bases.empty?

      best_base = nil
      best_freq = -1
      raw_bases.each do |base|
        next unless word_dict.key?(base)
        next unless Inflect.inflection_of_base?(base, word)

        kind = Inflect.send(:match_suffix_kind, base, word)
        next if kind.nil?

        # -er/-est words with their own WordNet entry are standalone (singer, faster)
        if (kind == :er || kind == :est) && word_in_wn
          best_base = nil
          break
        end

        # If word is in WordNet, base must share a synset (crew≠crow, ring≠re, thing≠the).
        # If word is NOT in WordNet, base must at least be in WordNet (tran, sacre, etc. are not).
        if word_in_wn
          next unless wn_accept_inflection_lemma_pair?(word, base)
        else
          next unless wn_has_entry?(base)
        end

        base_freq = word_dict[base][0]
        if best_base.nil? || base_freq > best_freq || (base_freq == best_freq && base.length < best_base.length)
          best_base = base
          best_freq = base_freq
        end
      end

      lemma_map[word] = best_base if best_base && best_base != word
    end
  ensure
    $wn_synset_line_index_by_path = nil
  end

  self_n = word_dict.size - lemma_map.size
  puts "Lemma map: #{lemma_map.size} inflected → base, #{self_n} self-lemmas"
  lemma_map
end

def rebuild_rhymecrime_dictionaries()
  clear_wordnet_lemma_cache!
  ensure_conceptnet_lemma_cache_for_build!
  cmudict = load_cmudict
  original_cmudict_headwords = cmudict.keys.each_with_object(Set.new) { |k, s| s.add(k) }
  wordfreq_hash = load_wordfreq
  wiktionary_prons, forms_map, pos_map, kaikki_verb_morph, kaikki_capitalized_only, kaikki_variant_map = load_wiktionary
  varcon_variant_map = load_varcon
  wiktionary_headwords = wiktionary_prons.keys
  apply_lexical_pos_layer_a!(pos_map)
  wn_seed_pos_map_for_cmudict_gaps!(pos_map, cmudict)
  apply_lexical_pos_layer_b!(pos_map, wordfreq_hash)
  save_part_of_speech_map(pos_map)
  merge_wiktionary!(cmudict, wiktionary_prons)
  wiktionary_prons.clear
  wiktionary_prons = nil
  merge_inflected_forms!(cmudict, forms_map)
  merge_gdropped_in_apostrophe_forms!(cmudict, forms_map)
  subtlex_hash, subtlex_total_hash = load_subtlex
  # Track which words are inflected forms for frequency inheritance
  forms_map.each do |base_word, form_pairs|
    form_pairs.each do |inflected_word, base|
      $inflection_base_words[inflected_word] = base if cmudict.key?(inflected_word)
    end
  end
  # Build set of all words with Wiktionary presence (for existence floor)
  wiktionary_words = Set.new(wiktionary_headwords)
  forms_map.each do |base_word, form_pairs|
    wiktionary_words.add(base_word)
    form_pairs.each do |inflected_word, _|
      wiktionary_words.add(inflected_word) if cmudict.key?(inflected_word)
    end
  end
  delete_explicitly_forbidden_keys_from_hash(cmudict)
  hyp_cmudict_edge = delete_headwords_with_edge_hyphen!(cmudict)
  puts "Removed #{hyp_cmudict_edge} cmudict headwords with a leading or trailing '-'" if hyp_cmudict_edge > 0
  rdict = build_rime_dict(cmudict)
  word_dict = build_word_dict(cmudict, rdict, subtlex_hash, subtlex_total_hash, wordfreq_hash, wiktionary_words, pos_map, forms_map, kaikki_verb_morph, original_cmudict_headwords, kaikki_capitalized_only, kaikki_variant_map, varcon_variant_map)
  hyphen_fold_build_keys = word_dict.keys
  lemma_map = compute_lemma_map(word_dict)
  save_string_hash(rdict, generated_dict_path_under_dict_dir(RIME_DICT_FILENAME), RIME_DICT_HEADER)
  save_word_dict(word_dict, lemma_map)
  save_hyphen_variant_map!(hyphen_fold_build_keys, exported_keys: word_dict.keys)
  if skip_conceptnet_numberbatch_dict_exports?
    puts "Skipping ConceptNet edge map and Numberbatch vectors (RHYMECRIME_DICT_SKIP_CONCEPTNET_NUMBERBATCH is set)"
  else
    rel_bases = relatedness_export_base_headwords(word_dict.keys, lemma_map)
    save_conceptnet_edge_map!(word_dict.keys, lemma_map)
    save_numberbatch_vectors!(rel_bases)
  end

  common_n = 0
  common_base_forms = Set.new
  word_dict.each do |word, (freq, _)|
    next unless freq > RARE_FREQ_MAX

    common_n += 1
    base = lemma_map.fetch(word, word)
    common_base_forms.add(base)
  end
  cue_n = 0
  target_n = 0
  common_base_forms.each do |base|
    next unless cue_word?(base, word_dict)

    cue_n += 1
    target_n += 1 if relatedness_target_word?(base, word_dict, rdict)
  end
  puts "word_dict: #{word_dict.size} entries"
  puts "  - #{common_n} common"
  puts "  - #{common_base_forms.size} common base forms"
  puts "  - #{cue_n} cue words (precompute row PKs)"
  puts "  - #{target_n} relatedness-target words (eligible to appear in a related list)"
end
