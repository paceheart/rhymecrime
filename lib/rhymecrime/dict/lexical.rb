# encoding: utf-8
# WordNet queries, lexical shape heuristics, Kaikki ∩ WordNet POS layers.

require "set"
require_relative "inflect"
require_relative "constants"

#
# WordNet
#

def wn_all_proper?(word)
  lemmas = WordNet::Lemma.find_all(word)
  lookup_word = word
  return false if lemmas.empty?
  found_any_word = false
  lemmas.each { |l|
    l.synsets.each { |synset|
      matching = synset.words.select { |w| w.downcase.tr('_', ' ') == lookup_word }
      next if matching.empty?
      found_any_word = true
      return false unless matching.all? { |w| w[0] != w[0].downcase }
    }
  }
  found_any_word
end

def wn_frequency(word)
  all_proper = wn_all_proper?(word)
  if(word == TRACE_WORD)
    puts "TRACE wn_frequency: all_proper=#{all_proper}"
  end
  return 0, all_proper
end

# 2-3 letter lowercase tokens are often initialisms (BBC, NBA). For Zipf>=3 we also treat
# 4-letter all-alpha tokens as acronym-like (IMAX-style in corpora) when there is no SUBTLEX
# and no WordNet lemma. 5-letter words are excluded — they are often real lexemes missing
# from older resources (e.g. emoji). (Four-letter policy may be revisited separately.)
def short_initialism_shape?(word)
  word.match?(/\A[a-z]{2,3}\z/)
end

def two_letter_alpha?(word)
  word.match?(/\A[a-z]{2}\z/)
end

def four_letter_alpha?(word)
  word.match?(/\A[a-z]{4}\z/)
end

def wn_synset_count(word)
  lemmas = WordNet::Lemma.find_all(word)
  return 0 if lemmas.empty?
  lemmas.sum { |l| l.synsets.size }
end

def acronym_shape_wordfreq_only?(word)
  word.match?(/\A[a-z]{2,4}\z/)
end

def wn_has_entry?(word)
  !WordNet::Lemma.find_all(word).empty?
end

# True if WordNet lists the base as a verb (any sense). Used to avoid Phase 8 giving
# noun-only stems a bogus verbal -ing frequency (kitchening, crotching, jealousing).
# Bases with no WordNet entry still return true so modern verbs (twerk) can inherit.
def wn_base_has_verb?(base)
  lemmas = WordNet::Lemma.find_all(base)
  return true if lemmas.empty?
  lemmas.any? { |l| l.pos == "v" }
end

def wn_base_has_adjective?(base)
  lemmas = WordNet::Lemma.find_all(base)
  return true if lemmas.empty?
  lemmas.any? { |l| l.pos == "a" }
end

def wn_base_has_noun?(base)
  lemmas = WordNet::Lemma.find_all(base)
  return true if lemmas.empty?
  lemmas.any? { |l| l.pos == "n" }
end

# WordNet lemma +pos+ codes → strings stored with Kaikki data (part_of_speech.json).
WN_POS_TO_LEXICAL_POS = {
  "n" => "noun",
  "v" => "verb",
  "a" => "adj",
  "s" => "adj", # satellite adjective
  "r" => "adv",
}.freeze

# Kaikki-style POS tags WordNet lists for this spelling (coarse noun / verb / adj / adv).
def wordnet_lexical_pos_set(word)
  lemmas = WordNet::Lemma.find_all(word)
  return Set.new if lemmas.empty?
  out = Set.new
  lemmas.each do |lem|
    mapped = WN_POS_TO_LEXICAL_POS[lem.pos]
    out.add(mapped) if mapped
  end
  out
end

# Layer A: intersect Kaikki’s POS union with WordNet’s coarse POS for the same surface form.
# Words with no WordNet lemmas keep the full Kaikki set (OOV / neologisms). Morph phases use the
# same +pos_map+ after this pass.
def apply_lexical_pos_layer_a!(pos_map)
  pos_map.each do |word, kaikki_set|
    next if kaikki_set.nil? || kaikki_set.empty?
    next unless wn_has_entry?(word)
    wn_set = wordnet_lexical_pos_set(word)
    next if wn_set.empty?
    pos_map[word] = kaikki_set & wn_set
  end
  nil
end

# CMU headwords missing from Kaikki still get coarse POS from WordNet (Layer C seed).
def wn_seed_pos_map_for_cmudict_gaps!(pos_map, cmudict)
  cmudict.each_key do |w|
    next unless wn_has_entry?(w)
    next if pos_map.key?(w) && !pos_map[w].nil? && !pos_map[w].empty?
    pos_map[w] = wordnet_lexical_pos_set(w)
  end
  nil
end

# Max Wordfreq Zipf among Inflect :ed / :ing surfaces derived from +base+.
def max_inflect_ed_ing_zipf(base, wordfreq_hash)
  max_z = 0.0
  Inflect.each_derivable_form(base) do |w|
    inflection_suffix_kind = Inflect.send(:match_suffix_kind, base, w)
    next unless inflection_suffix_kind == :ed || inflection_suffix_kind == :ing
    z = (wordfreq_hash[w] || 0).to_f
    max_z = z if z > max_z
  end
  max_z
end

# Max Zipf among plural :s surfaces Inflect derives from +base+ (boxes, foxes, …).
def max_inflect_plural_zipf(base, wordfreq_hash)
  max_z = 0.0
  Inflect.each_derivable_form(base) do |w|
    inflection_suffix_kind = Inflect.send(:match_suffix_kind, base, w)
    next unless inflection_suffix_kind == :s
    z = (wordfreq_hash[w] || 0).to_f
    max_z = z if z > max_z
  end
  max_z
end

# Layer B: prune marginal WordNet POS using Wordfreq on inflected surfaces (experiment).
# Homographs like +downtown+ (WN noun+adj+adv, no Kaikki row) are deferred to Layer C — not handled here.
def apply_lexical_pos_layer_b!(pos_map, wordfreq_hash)
  pos_map.each do |word, set|
    next if set.nil? || set.empty?
    s = set.dup

    # Marginal verb: keep noun/adj lemmas when synthetic verbal inflections never reach RARE Zipf.
    # Only for WordNet lemmas — OOV slang (*yeet*) keeps Kaikki’s verb so -ed/-ing can inherit.
    if wn_has_entry?(word) && s.include?("verb") && s.size > 1 && (s.include?("noun") || s.include?("adj"))
      if max_inflect_ed_ing_zipf(word, wordfreq_hash) < WORDFREQ_RARE_ZIPF
        s.delete("verb")
      end
    end

    # free: WN gives noun/adj/adv/verb; keep open-class adj+verb only.
    if s.size >= 4 && s.include?("adj") && s.include?("verb") && s.include?("noun") && s.include?("adv")
      s.delete("noun")
      s.delete("adv")
    end

    # Adj + noun: drop noun when a real plural surface exists in Wordfreq but stays below RARE
    # (central, impromptu, …). If every Inflect plural is absent (zipf 0), keep noun — e.g. magenta.
    # WordNet lemmas only — OOV terms like *accelerant* keep noun for real plurals (*accelerants*).
    if wn_has_entry?(word) && s.include?("adj") && s.include?("noun") && s.size >= 2
      pzip = max_inflect_plural_zipf(word, wordfreq_hash)
      if pzip.positive? && pzip < WORDFREQ_RARE_ZIPF
        s.delete("noun")
      end
    end

    # Noun + verb (no adj): drop noun when ed/ing is common but the bare +s+ token is still low Zipf
    # (gobble: gobbles). Skip high-+s+ lemmas (dances, jogs) where -s is productive 3sg, not a weak plural.
    if s.include?("noun") && s.include?("verb") && !s.include?("adj") && s.size == 2
      vzip = max_inflect_ed_ing_zipf(word, wordfreq_hash)
      szip = (wordfreq_hash[word + "s"] || 0).to_f
      s_ceiling = WORDFREQ_RARE_ZIPF + 0.25
      if vzip >= WORDFREQ_RARE_ZIPF && szip.positive? && szip < vzip * 0.9 && szip < s_ceiling
        s.delete("noun")
      end
    end

    pos_map[word] = s
  end
  nil
end
