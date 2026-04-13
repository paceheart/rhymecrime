# encoding: utf-8
# WordNet queries, lexical shape heuristics, Kaikki ∩ WordNet POS layers.

require "set"
require_relative "inflect"
require_relative "constants"
require_relative "utils_rhyme"

#
# WordNet
#

# Memoize WordNet::Lemma.find_all per surface form. Dict rebuild clears this at entry so memory
# does not grow unbounded across repeated builds in the same process.
def clear_wordnet_lemma_cache!
  @wordnet_lemma_find_all_cache = {}
end

def wn_lemma_find_all_cached(form)
  cache = @wordnet_lemma_find_all_cache ||= {}
  cache[form] ||= WordNet::Lemma.find_all(form)
end

def wn_all_proper?(word)
  lemmas = wn_lemma_find_all_cached(word)
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
  dict_trace_puts(word, "wn_frequency: all_proper=#{all_proper}") if dict_trace_word?(word)
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
  lemmas = wn_lemma_find_all_cached(word)
  return 0 if lemmas.empty?
  lemmas.sum { |l| l.synsets.size }
end

def acronym_shape_wordfreq_only?(word)
  word.match?(/\A[a-z]{2,4}\z/)
end

def wn_has_entry?(word)
  w = word.to_s
  return false if w.empty?
  # WordNet lemmas are usually hyphenated (topsy-turvy); older call sites used underscores only and missed them.
  [w, hyphens_to_underscores(w), w.tr("_", "-")].uniq.any? do |c|
    !wn_lemma_find_all_cached(c).empty?
  end
end

# True if WordNet lists the base as a verb (any sense). Used to avoid Phase 8 giving
# noun-only stems a bogus verbal -ing frequency (kitchening, crotching, jealousing).
# Bases with no WordNet entry still return true so modern verbs (twerk) can inherit.
def wn_base_has_verb?(base)
  lemmas = wn_lemma_find_all_cached(base)
  return true if lemmas.empty?
  lemmas.any? { |l| l.pos == "v" }
end

def wn_base_has_adjective?(base)
  lemmas = wn_lemma_find_all_cached(base)
  return true if lemmas.empty?
  lemmas.any? { |l| l.pos == "a" }
end

def wn_base_has_noun?(base)
  lemmas = wn_lemma_find_all_cached(base)
  return true if lemmas.empty?
  lemmas.any? { |l| l.pos == "n" }
end

# WordNet noun lexicographer files used for “mass-dominant” plural policy. *noun.attribute* alone
# mixes count and mass (*indifference*/*indifferences*); we only treat attribute lemmas as mass-locked
# when some sense is also in +WN_NOUN_LEXNAME_HARD_MASS+ (*goodwill*: possession + attribute + feeling).
# *noun.person* synsets are ignored (+Chaos+ the deity vs *chaos* the mass noun).
WN_NOUN_LEXNAME_MASS_DOMINANT = Set.new(%w[
  noun.attribute
  noun.cognition
  noun.feeling
  noun.food
  noun.motive
  noun.phenomenon
  noun.possession
  noun.state
  noun.substance
]).freeze

WN_NOUN_LEXNAME_HARD_MASS = Set.new(%w[
  noun.cognition
  noun.food
  noun.motive
  noun.phenomenon
  noun.possession
  noun.state
  noun.substance
]).freeze

# Bases whose usual plural is not *+s* (*deer*, *sheep*, …). WordNet 3.1 +noun.exc+ often omits
# identity pairs like *deer* → *deer*, so we merge this list after loading the file.
WN_INVARIANT_PLURAL_BASES_FALLBACK = Set.new(%w[
  bison cod deer moose sheep swine trout
]).freeze

# Princeton WordNet 3.x +lexnames+ table: two-digit file id → lexicographer file name (see lexnames(5WN)).
# Used when +dict/lexnames+ is missing or unreadable so +wn_synset_noun_lexname+ still works.
WN_LEX_FILENUM_TO_LEXNAME = {
  "00" => "adj.all", "01" => "adj.pert", "02" => "adv.all", "03" => "noun.Tops", "04" => "noun.act",
  "05" => "noun.animal", "06" => "noun.artifact", "07" => "noun.attribute", "08" => "noun.body",
  "09" => "noun.cognition", "10" => "noun.communication", "11" => "noun.event", "12" => "noun.feeling",
  "13" => "noun.food", "14" => "noun.group", "15" => "noun.location", "16" => "noun.motive",
  "17" => "noun.object", "18" => "noun.person", "19" => "noun.phenomenon", "20" => "noun.plant",
  "21" => "noun.possession", "22" => "noun.process", "23" => "noun.quantity", "24" => "noun.relation",
  "25" => "noun.shape", "26" => "noun.state", "27" => "noun.substance", "28" => "noun.time",
  "29" => "verb.body", "30" => "verb.change", "31" => "verb.cognition", "32" => "verb.communication",
  "33" => "verb.competition", "34" => "verb.consumption", "35" => "verb.contact", "36" => "verb.creation",
  "37" => "verb.emotion", "38" => "verb.motion", "39" => "verb.perception", "40" => "verb.possession",
  "41" => "verb.social", "42" => "verb.stative", "43" => "verb.weather", "44" => "adj.ppl",
}.freeze

# Map data.* +lex_filenum+ (two-digit id) → lexicographer name. File format (Princeton): tab-separated
# +filenum+, +lexname+, +syntactic_category+ (1=noun …) — not +lexname pos filenum+.
def wn_noun_lex_filenum_to_lexname
  @wn_noun_lex_filenum_to_lexname ||= begin
    m = {}
    root = WordNet::DB.path
    %w[dict/lexnames lexnames].each do |rel|
      path = File.join(root, rel)
      next unless File.file?(path)

      File.foreach(path, chomp: true, encoding: "UTF-8") do |line|
        next if line.empty? || line.start_with?("#")
        parts = line.split("\t")
        parts = line.split if parts.size < 3
        next if parts.size < 3

        num, name, _ss_type = parts[0], parts[1], parts[2]
        next if num.nil? || name.nil? || num.empty? || name.empty?

        key = num.rjust(2, "0")
        m[key] = name
      end
      break if m.size >= 40
    end
    m = WN_LEX_FILENUM_TO_LEXNAME.merge(m) if m.size < 40
    m.freeze
  end
end

def wn_synset_noun_lexname(synset)
  return nil unless synset&.pos == "n"

  map = wn_noun_lex_filenum_to_lexname
  return nil if map.empty?

  fn = synset.lex_filenum.to_s
  map[fn.rjust(2, "0")] || map[fn]
end

# Lemma bases that WordNet’s +noun.exc+ marks with the same surface as singular and plural (*deer deer*,
# *sheep sheep*, …). A bare *…+s+* spelling (*deers*, *sheeps*) is then a spurious regular plural for
# frequency and morph inheritance unless handled elsewhere.
def wn_noun_exc_invariant_plural_bases
  @wn_noun_exc_invariant_plural_bases ||= begin
    s = Set.new
    root = WordNet::DB.path
    %w[dict/noun.exc noun.exc].each do |rel|
      path = File.join(root, rel)
      next unless File.file?(path)

      File.foreach(path, chomp: true, encoding: "UTF-8") do |line|
        next if line.empty? || line.start_with?("#")
        inf, lem = line.split
        next unless inf && lem && inf == lem

        s.add(lem)
      end
      break if s.any?
    end
    s.merge(WN_INVARIANT_PLURAL_BASES_FALLBACK)
    s.freeze
  end
end

# All noun synsets for +word+, deduped, across WN spelling variants (hyphen / underscore).
def wn_noun_synsets_unified(word)
  forms = [word, hyphens_to_underscores(word), word.tr("_", "-")].uniq
  seen = {}
  forms.each do |f|
    next unless wn_has_entry?(f)

    wn_lemma_find_all_cached(f).each do |lem|
      next unless lem.pos == "n"

      lem.synsets.each do |s|
        key = [s.pos, s.pos_offset]
        seen[key] = s
      end
    end
  end
  seen.values
end

# True when every WordNet noun sense of +base+ sits in a mass-leaning lexicographer file, so Inflect *+s*
# should not inherit via corpus alone (blocks *nostalgias* while keeping *apples*).
def wn_noun_base_mass_dominant_for_productive_plural?(base)
  return false unless wn_has_entry?(base)
  return false unless wn_base_has_noun?(base)

  syns = wn_noun_synsets_unified(base)
  return false if syns.empty?

  # Mythology / named-entity senses (*Chaos*) live in +noun.person+; they should not prevent treating
  # the everyday mass noun as mass-dominant for plural policy.
  syns.reject! { |s| wn_synset_noun_lexname(s) == "noun.person" }
  return false if syns.empty?

  lexnames = syns.map { |s| wn_synset_noun_lexname(s) }
  return false if lexnames.any?(&:nil?)

  return false unless lexnames.all? { |ln| WN_NOUN_LEXNAME_MASS_DOMINANT.include?(ln) }

  # *indifference*: feeling + attribute only → do not block *indifferences*. *goodwill*: also possession/state-class.
  if lexnames.include?("noun.attribute") && lexnames.none? { |ln| WN_NOUN_LEXNAME_HARD_MASS.include?(ln) }
    return false
  end

  true
end

# *indifference*-style lemmas: after the mass-dominant exception (feeling + attribute, no hard-mass sense),
# we still must not copy a strong base frequency onto *+s* (*indifferences*) when the plural is only
# weakly attested — same corpus bar as full mass nouns. Pure *noun.feeling* (*nostalgia*) stays on the
# mass-dominant path instead.
def wn_noun_base_feeling_plus_attribute_plural_needs_own_corpus?(base)
  return false unless wn_has_entry?(base)
  return false unless wn_base_has_noun?(base)

  syns = wn_noun_synsets_unified(base)
  return false if syns.empty?

  syns.reject! { |s| wn_synset_noun_lexname(s) == "noun.person" }
  return false if syns.empty?

  uniq_lex = syns.map { |s| wn_synset_noun_lexname(s) }.compact.uniq
  return false if uniq_lex.empty?
  return false unless uniq_lex.all? { |ln| %w[noun.feeling noun.attribute].include?(ln) }

  uniq_lex.include?("noun.feeling") && uniq_lex.include?("noun.attribute")
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
  lemmas = wn_lemma_find_all_cached(word)
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
