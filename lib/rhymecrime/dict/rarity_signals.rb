# encoding: utf-8
#
# Rarity signal extraction (rarity-pipeline stage 1): per-headword signal extraction. Every
# feature the downstream classifier / rule-based combiner reads is produced here once and
# never recomputed.
#
# Rarity scoring (stage 2: +rarity_classifier.predict+ or the legacy rules in
# +compute_frequency+ / Wiktionary existence floor / +filter_word_dict_disconnected!+ rescue)
# consumes the +RaritySignals+ struct only — it must not reach back into the raw corpora.
#
# Rarity gate (stage 3: +rare? / allowed?+ in +crime.rb+) compares final freq against
# +RARE_FREQ_MAX+; it's a pure threshold.
#
# Feature surface intentionally kept small: raw corpus scalars, WordNet presence /
# synset count / coarse POS, surface shape / case, POS tag coverage, and the
# post-propagation legacy freq (classifier's most useful non-Zipf signal per the
# ablation in +bin/train-rarity-classifier --ablate-group+). Hand-engineered
# Kaikki / morphology / WordNet-subtyping flags were dropped in the ablation study
# (cost ≈ 0.1 pp on 5-fold CV vs +1 pp cost of dropping +post_propagation_freq+).
# If you need a new feature, add it here + in +LEARNED_RARITY_FEATURE_NAMES+ +
# +learned_rarity_feature_vector+ and retrain.
#
# Usage:
#
#   ctx = RarityContext.build(subtlex_hash:, subtlex_total_hash:, wordfreq_hash:,
#                             pos_map:, wiktionary_words:, rare_words:,
#                             common_words:, neol_words:, cmudict_orig:,
#                             ref_cn:, ref_nb:, ref_usf:)
#   sig = extract_rarity_signals(word, ctx)

require "set"
require_relative "lexical"
require_relative "constants"
require_relative "utils_rhyme"

RarityContext = Struct.new(
  :subtlex_hash, :subtlex_total_hash, :wordfreq_hash,
  :pos_map, :wiktionary_words,
  :rare_words, :common_words, :neol_words,
  :cmudict_orig, :ref_cn, :ref_nb, :ref_usf,
  :usf_associations, :conceptnet_adjacency, :conceptnet_adjacency_loaded,
  keyword_init: true
) do
  def self.build(**kwargs)
    new(
      subtlex_hash: kwargs[:subtlex_hash] || Hash.new(0),
      subtlex_total_hash: kwargs[:subtlex_total_hash] || Hash.new(0),
      wordfreq_hash: kwargs[:wordfreq_hash] || {},
      pos_map: kwargs[:pos_map] || {},
      wiktionary_words: kwargs[:wiktionary_words] || Set.new,
      rare_words: kwargs[:rare_words] || Set.new,
      common_words: kwargs[:common_words] || Set.new,
      neol_words: kwargs[:neol_words] || Set.new,
      cmudict_orig: kwargs[:cmudict_orig] || Set.new,
      ref_cn: kwargs[:ref_cn],
      ref_nb: kwargs[:ref_nb],
      ref_usf: kwargs[:ref_usf] || Set.new,
      usf_associations: kwargs[:usf_associations] || {},
      conceptnet_adjacency: kwargs[:conceptnet_adjacency] || {},
      conceptnet_adjacency_loaded: !!kwargs[:conceptnet_adjacency_loaded],
    )
  end
end

# Flat bag of features for one headword. Flags are 0.0/1.0 floats so
# +learned_rarity_feature_vector+ can append them to the model input without
# coercion. Non-flag scalars are raw (Zipf, SUBTLEX count, synset count) — the
# classifier standardizes (logreg) or splits (GBT) on them.
#
# Ordering here is not significant for the struct itself; see
# +LEARNED_RARITY_FEATURE_NAMES+ in +rarity_classifier.rb+ for the classifier's
# feature vector order.
RaritySignals = Struct.new(
  :word,

  # --- Corpus scalars ---
  :wordfreq_zipf,                 # Float >= 0 (0 when OOV)
  :subtlex_freqlow,               # Int >= 0 (lowercase occurrences only)
  :subtlex_total,                 # Int >= 0 (all cases)
  :subtlex_cap_ratio,             # Float in [0,1] or nil (<min total)
  :cmudict_original_flag,
  :conceptnet_flag,
  :numberbatch_flag,
  :usf_flag,
  :neol_flag,
  :common_words_flag,
  :rare_words_flag,
  :semantically_promiscuous_flag,
  :wiktionary_words_flag,

  # --- WordNet (presence + coarse POS) ---
  :wn_entry_flag,
  :wn_synset_count,
  :wn_lemma_count,                        # WordNet::Lemma.find_all(word).size
  :wn_all_proper_flag,
  :wn_has_noun_flag,
  :wn_has_verb_flag,
  :wn_has_adj_flag,

  # --- Graph-degree signals (richer than the binary +_flag+ versions above) ---
  :usf_out_degree,                        # size of usf_associations[word] (0 when no cue row)
  :cn_degree,                             # ConceptNet adjacency size (0 when unknown)
  :cn_adjacency_loaded_flag,              # 1 iff the edges file was present when signals were extracted

  # --- Shape / case ---
  :word_len,
  :two_letter_alpha_flag,
  :four_letter_alpha_flag,
  :likely_proper_noun_by_case_flag,

  # --- POS tag coverage ---
  :pos_tag_count,
  :pos_has_noun_flag,
  :pos_has_verb_flag,
  :pos_has_adj_flag,
  :pos_has_intj_flag,
  :pos_all_function_word_flag,            # OOV tagged only with pron/prep/det/conj/num

  # --- Post-propagation (recomputed by the classifier pass) ---
  :post_propagation_freq,
  :freq_source_phase,                     # one of :cmudict_seed, :subtlex, :common_list, :neol, :wiktionary_floor, :morph_inherit_kaikki, :morph_inherit_listed, :morph_expand_listed, :morph_expand_subtlex, :gdrop, :unknown
  :received_donor_from_common_base_flag
)

# Order is part of the trained-classifier ABI: +rarity_freq_source_to_index+
# returns the array index, which is what the model sees as a feature value.
# Append new sources at the end; renaming a symbol is safe (model doesn't see
# the symbol name), but reordering invalidates +generated/rarity_classifier.json+.
RARITY_FREQ_SOURCE_PHASES = [
  :unknown, :cmudict_seed, :subtlex, :common_list, :neol,
  :wiktionary_floor, :morph_inherit_kaikki, :morph_inherit_listed,
  :morph_expand_listed, :morph_expand_subtlex, :gdrop
].freeze

def rarity_freq_source_to_index(phase)
  i = RARITY_FREQ_SOURCE_PHASES.index(phase)
  i.nil? ? 0 : i
end

# +word+: lowercase surface. +ctx+: +RarityContext+ bag.
# Returns a fully-populated +RaritySignals+ (minus post-propagation fields, which
# default to +nil+ / +0+ / +false+ and are filled in by the classifier pass).
def extract_rarity_signals(word, ctx)
  sub_raw = (ctx.subtlex_hash && ctx.subtlex_hash[word]) || 0
  sub_tot = (ctx.subtlex_total_hash && ctx.subtlex_total_hash[word]) || 0
  zipf = (ctx.wordfreq_hash && ctx.wordfreq_hash[word]) || 0
  cap_ratio = subtlex_capitalized_ratio(word, ctx.subtlex_hash, ctx.subtlex_total_hash)

  in_cmu = ctx.cmudict_orig.include?(word)
  in_neol = ctx.neol_words.include?(word)
  in_common_list = ctx.common_words.include?(word)
  in_rare_list = ctx.rare_words.include?(word)
  in_wiktionary = ctx.wiktionary_words.include?(word)

  u = hyphens_to_underscores(word)
  in_cn = !!(ctx.ref_cn && ctx.ref_cn.include?(u))
  in_nb = !!(ctx.ref_nb && ctx.ref_nb.include?(u))
  in_usf = ctx.ref_usf ? ctx.ref_usf.include?(word) : false

  wn_in = wn_has_entry?(word)
  syn_n = wn_in ? wn_synset_count(word) : 0
  lem_n = begin
    WordNet::Lemma.find_all(word).size
  rescue
    0
  end
  wn_all_proper = wn_in ? wn_all_proper?(word) : false
  wn_noun = wn_in ? wn_base_has_noun?(word) : false
  wn_verb = wn_in ? wn_base_has_verb?(word) : false
  wn_adj  = wn_in ? wn_base_has_adjective?(word) : false

  usf_row = ctx.usf_associations ? ctx.usf_associations[word] : nil
  usf_deg = usf_row ? usf_row.size : 0
  cn_key = hyphens_to_underscores(word)
  cn_adj_row = ctx.conceptnet_adjacency ? ctx.conceptnet_adjacency[cn_key] : nil
  cn_deg = cn_adj_row ? cn_adj_row.size : 0
  cn_loaded = !!ctx.conceptnet_adjacency_loaded

  wlen = word.length
  two_letter = two_letter_alpha?(word)
  four_letter = four_letter_alpha?(word)
  case_proper = likely_proper_noun_by_case?(word, ctx.subtlex_hash, ctx.subtlex_total_hash, nil)

  pos_set = (ctx.pos_map && ctx.pos_map[word]) || nil
  pos_arr = pos_set.respond_to?(:to_a) ? pos_set.to_a : Array(pos_set)
  pos_has_noun = pos_arr.include?("noun")
  pos_has_verb = pos_arr.include?("verb")
  pos_has_adj  = pos_arr.include?("adj")
  pos_has_intj = pos_arr.include?("intj")
  pos_all_fw = !pos_arr.empty? && pos_arr.all? { |t| OOV_FUNCTION_WORD_POS_TAGS.include?(t) }

  RaritySignals.new(
    word,
    zipf.to_f,
    sub_raw.to_i,
    sub_tot.to_i,
    cap_ratio,
    in_cmu,
    in_cn,
    in_nb,
    in_usf,
    in_neol,
    in_common_list,
    in_rare_list,
    semantically_promiscuous?(word),
    in_wiktionary,

    wn_in,
    syn_n.to_i,
    lem_n.to_i,
    wn_all_proper,
    wn_noun,
    wn_verb,
    wn_adj,

    usf_deg.to_i,
    cn_deg.to_i,
    cn_loaded,

    wlen.to_i,
    two_letter,
    four_letter,
    case_proper,

    pos_arr.size,
    pos_has_noun,
    pos_has_verb,
    pos_has_adj,
    pos_has_intj,
    pos_all_fw,

    nil, :unknown, false
  )
end
