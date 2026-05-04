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
  @wordnet_synset_count_cache = {}
  $wn_synset_line_index_by_path = nil
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
  cache = @wordnet_synset_count_cache ||= {}
  cached = cache[word]
  return cached unless cached.nil?
  lemmas = wn_lemma_find_all_cached(word)
  count = lemmas.empty? ? 0 : lemmas.sum { |l| l.synsets.size }
  cache[word] = count
  count
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

# rwordnet's Synset#relation follows pointer offsets as integers, which breaks Princeton WordNet 3.1
# (8-digit synset ids with leading zeros). Read pointer targets from the dict data files instead.

WN_DICT_DATA_FILE = {
  "n" => "data.noun",
  "v" => "data.verb",
  "a" => "data.adj",
  "s" => "data.adj",
  "r" => "data.adv",
}.freeze

WN_DERIVATION_PTR_SYMBOLS = Set.new(%w[+ < \\])

def wn_dict_data_path(pos_char)
  fn = WN_DICT_DATA_FILE[pos_char]
  return nil if fn.nil?

  File.join(WordNet::DB.path, "dict", fn)
end

# One full scan per WordNet data file, then O(1) lookup. Global +$wn_synset_line_index_by_path+
# is cleared in +clear_wordnet_lemma_cache!+ and after +compute_lemma_map+ (see dict.rb).

def build_wn_synset_line_index(path)
  idx = {}
  File.foreach(path, encoding: "UTF-8") do |ln|
    next if ln.bytesize < 9

    off = ln.byteslice(0, 8)
    next unless ln.getbyte(8) == 0x20 && off.match?(/\A\d{8}\z/)

    idx[off] = ln
  end
  idx.freeze
end

def wn_synset_line_index_for_path(path)
  ($wn_synset_line_index_by_path ||= {})[path] ||= build_wn_synset_line_index(path)
end

# Full synset line (header + gloss) for 8-digit +synset_offset+ in the data file for +pos_char+.
def wn_synset_line_for_offset(pos_char, synset_offset)
  path = wn_dict_data_path(pos_char)
  return nil unless path && File.file?(path)

  key = synset_offset.to_i.to_s.rjust(8, "0")
  wn_synset_line_index_for_path(path)[key]
end

def wn_parse_synset_header_fields(header)
  toks = header.split
  return nil if toks.size < 4

  _off, _lex, _ss, wc_s = toks.shift(4)
  wc = wc_s.to_i
  return nil if toks.size < wc * 2

  words = []
  wc.times do
    words << toks.shift.downcase
    toks.shift # lex_id
  end
  return nil if toks.empty?

  pc = toks.shift.to_i
  ptrs = []
  pc.times do
    return nil if toks.size < 4

    ptrs << { sym: toks.shift, off: toks.shift, pos: toks.shift, src_tgt: toks.shift }
  end
  { words: words, ptrs: ptrs }
end

# All member lemmas (lowercase) in synsets reached by 1-hop derivation pointers from any sense of +word+.
def wn_derivation_target_lemmas_for_word(word)
  names = Set.new
  w = word.to_s
  return names if w.empty?

  [w, hyphens_to_underscores(w), w.tr("_", "-")].uniq.each do |wv|
    wn_lemma_find_all_cached(wv).each do |lem|
      pos_char = lem.pos
      lem.synset_offsets.each do |off_i|
        line = wn_synset_line_for_offset(pos_char, off_i)
        next unless line

        hdr = line.split(" | ", 2).first
        st = wn_parse_synset_header_fields(hdr)
        next unless st

        st[:ptrs].each do |p|
          next unless WN_DERIVATION_PTR_SYMBOLS.include?(p[:sym])

          tline = wn_synset_line_for_offset(p[:pos], p[:off])
          next unless tline

          th = tline.split(" | ", 2).first
          stt = wn_parse_synset_header_fields(th)
          next unless stt

          stt[:words].each { |lw| names.add(lw) }
        end
      end
    end
  end
  names
end

def wn_derivation_target_hit?(targets, base)
  return false if targets.nil? || targets.empty?

  b = base.to_s
  return false if b.empty?

  want = [b.downcase, hyphens_to_underscores(b).downcase, b.tr("_", "-").downcase].uniq
  want.any? { |x| targets.include?(x) }
end

# 1-hop derivation / participle / derived-from-adj pointers from any sense of +word+ to a synset
# that lists +base+ as a member lemma.
def wn_derivationally_related_to_base?(word, base)
  w = word.to_s
  b = base.to_s
  return false if w.empty? || b.empty?

  targets = wn_derivation_target_lemmas_for_word(w)
  wn_derivation_target_hit?(targets, b)
end

# Productive English -ly / -ful spelled per +Inflect+, with WordNet POS shape guards so *early*≠*ear*,
# *only*≠*on*, *friendly* (noun)≠*friend*, etc.
def wn_productive_affix_lemma_pair?(word, base)
  kind = Inflect.send(:match_suffix_kind, base, word)
  return false unless %i[ly ful].include?(kind)
  return false unless Inflect.inflection_of_base?(base, word)

  poses = wn_lemma_find_all_cached(word).map(&:pos).uniq.sort
  return false if poses.empty?

  case kind
  when :ful
    return false unless poses == ["a"]
  when :ly
    return false unless poses == ["a"] || poses == ["r"]
  else
    return false
  end
  true
end

# Regular verbal *-ed* / *-ing* / *-s* surfaces whose unique verbal morphy stem matches +base+
# and +Inflect+ agrees on the suffix shape (+deafened+→+deafen+, +bumbling+→+bumble+,
# +needs+ adv→+need+ verb). Rescues cases where WordNet lists the inflected form as its own
# adj/gerund/adverb head (so +wn_share_synset?+ / +wn_derivationally_related_to_base?+ return
# false) but the verbal relationship is still sound.
#
# Stems are deduped by spelling-variant +preferred_form+ before the unique-base check: WordNet's
# morphy returns both spellings of a single lexeme (+morphy(fulfilled,verb)=[fulfil,fulfill]+,
# +morphy(travelled,verb)=[travel,travelled]+) which would otherwise look like an ambiguous stem.
# Genuine ambiguity (+feed+→{+feed+,+fee+}, +singing+→{+sing+,+singe+}) still blocks because the
# stems map to different preferred forms.
def wn_verb_stem_via_morphy?(word, base)
  kind = Inflect.send(:match_suffix_kind, base, word)
  return false unless %i[ed ing s].include?(kind)
  return false unless wn_base_has_verb?(base)

  stems = (WordNet::Synset.morphy(word, "verb") rescue [])
  return false if stems.empty?

  canonical_stems = stems.map { |s| preferred_form(s) || s }.uniq
  return false unless canonical_stems.size == 1

  base_canonical = preferred_form(base) || base
  canonical_stems.first == base_canonical
end

# Regular *-s* noun plurals whose WordNet noun-morphy result includes +base+.
# Rescues lemma collapse for surfaces that have their own WN noun synset because
# of a pluralia-tantum-derivative sense (+communications+ "telecommunications",
# +glasses+ "spectacles", +arms+ "weapons") — +wn_share_synset?+ correctly says
# no but the morphological plural relationship is still real and Kaikki/morphy
# both attest it. Distinguishes these from genuine standalone nouns whose +-s+
# ending is coincidental (+alias+, +atlas+, +basis+, +assess+, +caress+ —
# morphy returns only the surface or an unrelated stem so the gate stays shut),
# and from pluralia-tantum that aren't really plurals (+aerobatics+,
# +binoculars+, +bahamas+ — morphy returns only the surface).
#
# +base+ is matched after +preferred_form+ canonicalization so spelling-variant
# pairs (+colors+/+colour+) still match through.
def wn_noun_plural_via_morphy?(word, base)
  kind = Inflect.send(:match_suffix_kind, base, word)
  return false unless kind == :s
  return false unless wn_base_has_noun?(base)

  # Reject morphy's opportunistic +-ss+ → +-s+ chops (+ass+→+as+, +boss+→+bos+,
  # +pass+→+pas+, +buss+→+bus+). +morphy(word, "noun")+ tries stripping a
  # single +s+ from any +-ss+ surface and returns the result whenever WordNet
  # happens to have a noun entry for it, regardless of whether the two are
  # semantically related. English doesn't pluralize +s+-final bases by adding
  # another +s+ — the real plural inflection of +as+/+bos+/+pas+/+bus+ is
  # +-es+ (+asses+/+boses+/+pases+/+buses+). So a +kind == :s+ shape where
  # +word+ ends in +-ss+ and +base+ ends in +-s+ is virtually always the
  # opportunistic chop, never a real plural. Doc-preserved pluralia-tantum
  # (+glasses+→+glass+, +arms+→+arm+, +communications+→+communication+,
  # +kisses+→+kiss+) end in +-sses+/+-ms+/+-tions+, never +-ss+ over +-s+, so
  # this guard doesn't touch them.
  return false if word.end_with?("ss") && base.end_with?("s")

  stems = (WordNet::Synset.morphy(word, "noun") rescue [])
  return false if stems.empty?

  base_canonical = preferred_form(base) || base
  stems.any? { |s| (preferred_form(s) || s) == base_canonical }
end

# True if WordNet lists the base as a verb (any sense). Used to avoid Kaikki morph
# inheritance giving noun-only stems a bogus verbal -ing frequency (kitchening, crotching,
# jealousing). Bases with no WordNet entry still return true so modern verbs (twerk) can
# inherit.
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

# Small, conservative list of noun-only irregular plurals where +base+s+ / +base+es+ is spurious
# and the base doesn't double as a common verb lemma. Drawn from WordNet +noun.exc+ but hand-filtered
# to avoid blocking verb 3rd-person-singulars (*knifes*, *leafs*, *wifes*) and legitimate nominal
# alternates (*mouses* for computer mice, *appendixes* in medical usage).
WN_NOUN_IRREGULAR_NON_S_PLURAL_BASES = Set.new(%w[
  child goose ox tooth foot man woman person brother louse
]).freeze

# WordNet noun lex-filenames whose single-synset members tend to be encyclopedic / specialist
# rather than conversational English (Latin botanical anatomy, foreign numeric units, clan /
# gens group labels). When a single-synset WN lemma sits in one of these categories and has
# almost no SUBTLEX dialogue trickle, it's an encyclopedic token even though WordNet / wordfreq
# give it headword-level anchors (+anther+, +gens+, +lakh+). Noun.animal and noun.communication
# are intentionally excluded: they collide with common animal names (+tapir+ / +axolotl+ /
# +puffin+) and idiom commons (+skulduggery+ / +malware+).
WN_ENCYCLOPEDIC_SINGLE_SYNSET_LEXNAMES = Set.new(%w[
  noun.plant noun.quantity noun.group
]).freeze

# Kaikki POS tags that designate closed-class function words. An OOV headword tagged
# exclusively with these is nonstandard (+hisself+) or foreign-closed-class (+hor+ particle,
# +raison+ fragments); genuine function-word commons (+of+, +his+, +yours+) are
# +unrhymable_stop_word?+ entries that get deleted from +word_dict+ at build time.
OOV_FUNCTION_WORD_POS_TAGS = Set.new(%w[
  pron particle det conj prep num article postp
]).freeze

# WordNet noun lex-categories covering biological taxonomy. Used with +wn_all_proper+ and
# +syn_n == 1+ to demote Latin scientific binomials whose SUBTLEX FREQlow is a 1–4 count
# fragment rather than sustained dialogue. +cajun+ (noun.person) has the same all_proper +
# single-synset + low-sub profile but is a conversational demonym, so +noun.person+ stays out.
WN_ALL_PROPER_BIOLOGY_LEXNAMES = Set.new(%w[
  noun.animal noun.plant
]).freeze

# True when +word+ matches the WN single-synset + specialized-lex + thin-SUBTLEX profile that
# +compute_frequency+ proactively demotes to rare. Used by Kaikki morph inheritance to refuse
# plural/inflection inheritance that would undo the demotion (e.g. +gens+ → +gen+ base inherit).
def wn_encyclopedic_single_synset_demoted?(word, subtlex_hash, wordfreq_hash)
  return false unless wn_has_entry?(word)
  return false unless wn_synset_count(word) == 1
  zipf = wordfreq_hash[word] || 0
  return false unless zipf > 0 && zipf < WORDFREQ_COMMON_ZIPF + 0.5
  sub_raw = subtlex_hash[word] || 0
  return false unless sub_raw < 5
  lexnames = wn_noun_synsets_unified(word).map { |s| wn_synset_noun_lexname(s) }.compact
  lexnames.any? { |ln| WN_ENCYCLOPEDIC_SINGLE_SYNSET_LEXNAMES.include?(ln) }
end

def wn_noun_exc_irregular_non_s_plural_bases
  WN_NOUN_IRREGULAR_NON_S_PLURAL_BASES
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

# +word+ has no WordNet lemma but is an Inflect surface of a WordNet lemma. Used to skip the OOV
# low-SUBTLEX +subtlex_freq+ ceiling when Zipf is strong (*successors*) without helping bare fragments
# that are not morphologically tied to a lexicon head (*anders* has no such base).
def wn_oov_subtlex_cap_skip_via_inflection_anchor?(word)
  return false if wn_has_entry?(word)

  Inflect.each_candidate_base_for_inflected(word) do |base|
    next unless wn_has_entry?(base)
    next unless Inflect.inflection_of_base?(base, word)

    kind = Inflect.match_suffix_kind(base, word)
    next if kind.nil?

    if kind == :s
      next if wn_noun_base_mass_dominant_for_productive_plural?(base)
      next if wn_noun_base_feeling_plus_attribute_plural_needs_own_corpus?(base)
    end

    if %i[ed ing er est].include?(kind)
      next unless wn_base_has_verb?(base) || wn_base_has_adjective?(base)
    end

    return true
  end
  false
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
