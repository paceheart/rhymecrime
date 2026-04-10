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
#         (build_word_dict merges pronunciations into rdict, prunes rare-only buckets, drops freq==0 orphans
#          per disconnect: wordfreq TSV row ⇒ keep; strict OOV ⇒ Kaikki/SUBTLEX rescue only, not rhyme-alone)
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
require_relative "inflect"

require_relative "constants"
require_relative "phonology"
require_relative "lexical"
require_relative "morphology"
require_relative "rime"
require_relative "frequency"

$inflection_base_words = {}

def skip_conceptnet_numberbatch_dict_exports?
  v = ENV["RHYMECRIME_DICT_SKIP_CONCEPTNET_NUMBERBATCH"]
  v && !v.empty? && %w[1 true yes on].include?(v.downcase)
end

def rebuild_rhymecrime_dictionaries()
  ensure_conceptnet_lemma_cache_for_build!
  cmudict = load_cmudict
  original_cmudict_headwords = cmudict.keys.each_with_object(Set.new) { |k, s| s.add(k) }
  wordfreq_hash = load_wordfreq
  wiktionary_prons, forms_map, pos_map, kaikki_verb_morph = load_wiktionary
  apply_lexical_pos_layer_a!(pos_map)
  wn_seed_pos_map_for_cmudict_gaps!(pos_map, cmudict)
  apply_lexical_pos_layer_b!(pos_map, wordfreq_hash)
  save_part_of_speech_map(pos_map)
  merge_wiktionary!(cmudict, wiktionary_prons)
  merge_inflected_forms!(cmudict, forms_map)
  merge_gdropped_in_apostrophe_forms!(cmudict, forms_map)
  subtlex_hash = load_subtlex
  # Track which words are inflected forms for frequency inheritance
  forms_map.each do |base_word, form_pairs|
    form_pairs.each do |inflected_word, base|
      $inflection_base_words[inflected_word] = base if cmudict.key?(inflected_word)
    end
  end
  # Build set of all words with Wiktionary presence (for existence floor)
  wiktionary_words = Set.new(wiktionary_prons.keys)
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
  word_dict = build_word_dict(cmudict, rdict, subtlex_hash, wordfreq_hash, wiktionary_words, pos_map, forms_map, kaikki_verb_morph, original_cmudict_headwords)
  save_string_hash(rdict, generated_dict_path_under_dict_dir(RIME_DICT_FILENAME), RIME_DICT_HEADER)
  save_word_dict(word_dict)
  save_hyphen_variant_map!(word_dict.keys)
  if skip_conceptnet_numberbatch_dict_exports?
    puts "Skipping ConceptNet edge map and Numberbatch vectors (RHYMECRIME_DICT_SKIP_CONCEPTNET_NUMBERBATCH is set)"
  else
    save_conceptnet_edge_map!(word_dict.keys)
    save_numberbatch_vectors!(word_dict.keys)
  end

  common_n = 0
  word_dict.each_value do |(freq, _)|
    if freq > RARE_FREQ_MAX
      common_n += 1
    end
  end
  puts "word_dict: #{word_dict.size} entries (#{common_n} common)"
end
