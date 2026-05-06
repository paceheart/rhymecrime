# encoding: utf-8
# Inflection policy (Kaikki attestation, morph_base_allows_*), Kaikki-derived surface pronunciations.

require_relative "inflect"
require_relative "lexical"
require_relative "phonology"
require_relative "constants"

def morph_part_of_speech_tags(pos_map, base)
  s = pos_map[base]
  return [] if s.nil? || s.empty?
  s.to_a
end

# *Deers* / *sheeps*: Inflect treats *base+s* as :s, but WordNet marks *deer*, *sheep*, … as invariant in noun.exc.
# Extended to cover bases whose noun.exc plural is irregular and non-s (*ox* → *oxen*, *child* → *children*,
# *goose* → *geese*): *oxes* / *childs* / *gooses* are spurious regular plurals in that case.
def morph_spurious_plural_s_on_invariant_noun?(plural_word)
  invariant = wn_noun_exc_invariant_plural_bases
  irregular = wn_noun_exc_irregular_non_s_plural_bases
  return false if invariant.empty? && irregular.empty?

  Inflect.each_candidate_base_for_inflected(plural_word) do |base|
    next unless invariant.include?(base) || irregular.include?(base)
    next unless Inflect.inflection_of_base?(base, plural_word)
    next unless Inflect.send(:match_suffix_kind, base, plural_word) == :s

    return true if plural_word == base + "s" || plural_word == base + "es"
  end
  false
end

# Kaikki listed this exact surface as an inflected form of base (collect_inflected_forms).
def wiktionary_surface_form_attested?(forms_map, base, inflected)
  pairs = forms_map[base]
  return false if pairs.nil? || pairs.empty?
  pairs.any? { |form, b| form == inflected && b == base }
end

# True if Kaikki lists any surface for base whose Inflect suffix kind matches suffix_kind (:ed, :ing, …).
# Spelling variants (e.g. cataloging vs catalogging) share the same kind, so a listed participle
# attests Inflect’s preferred -ing spelling for WN verb lemmas.
def wiktionary_derivation_suffix_attested?(forms_map, base, suffix_kind)
  return false if suffix_kind.nil?
  pairs = forms_map[base]
  return false if pairs.nil? || pairs.empty?
  pairs.any? do |form, b|
    next false unless b == base
    Inflect.send(:match_suffix_kind, base, form) == suffix_kind
  end
end

# True if some Inflect-derived surface for base with suffix suffix_kind reaches RARE Zipf in Wordfreq.
# With morph_base_allows_verb_forms?, lexeme-level allowance still requires per-surface Kaikki or Zipf
# on the exact spelling (so *cataloging* in corpus does not promote *catalogging*).
def corpus_inflection_suffix_zipf_attested?(wordfreq_hash, base, suffix_kind)
  return false if suffix_kind.nil? || wordfreq_hash.nil?
  Inflect.each_derivable_form(base) do |w|
    next if w == base
    next unless Inflect.inflection_of_base?(base, w)
    next unless Inflect.send(:match_suffix_kind, base, w) == suffix_kind
    z = (wordfreq_hash[w] || 0).to_f
    return true if z >= WORDFREQ_RARE_ZIPF
  end
  false
end

# Inflect doubles final *k* when the base ends in *-ck*, which spells *ckk* (*lock*→*lockked*, *snuck*→*snuckked*).
# English adds *-ed/-ing/-er/-est* without that extra *k* (*locked*, *snucking*). *Trek*→*trekked* doubles *k*
# after a vowel letter, not after *ck*.
def morph_inflect_ck_double_k_junk?(base, inflected)
  return false unless base.end_with?("ck")
  inflected == base + "ked" || inflected == base + "king" ||
    inflected == base + "ker" || inflected == base + "kest"
end

# True when Inflect *-ed* or *-ing* duplicates a role Kaikki already fills for the verb lexeme
# (kaikki_verb_morph from load_wiktionary).
def morph_kaikki_redundant_verb_inflection_blocked?(base, suffix_kind, kaikki_verb_morph)
  return false if kaikki_verb_morph.nil?

  case suffix_kind
  when :ed
    kaikki_verb_morph[:past_surfaces].include?(base)
  when :ing
    kaikki_verb_morph[:non_lemma_surfaces_in_pp_paradigm].include?(base)
  else
    false
  end
end

# -ed/-ing: Kaikki verb when present; cross-check WordNet so noun-only lemmas do not inherit
# verbal junk (FP-4). When both Kaikki and WordNet agree the base is a verb, require a Kaikki
# surface row. If Kaikki also lists adj on the lemma, require Wordfreq Zipf on the inflected
# surface so lexicon rows for marginal verbs (e.g. *taboo*) do not promote rare *tabooed* when
# corpus use is negligible. OOV bases (no WordNet entry) keep the legacy open policy.
#
# When list_authoritative_base is true (list-pivot Inflect inheritance only), skip
# Kaikki/corpus verb attestation: entries tagged common/common_ish in curated/rarity.csv are curated list headwords
# (*finesse*→*finessed* must inherit).
#
# kaikki_verb_morph (from load_wiktionary): blocks Inflect *-ed*/*-ing* when Kaikki already documents
# the corresponding verb slot in the lexeme (*snuck* is a past surface of *sneak*; do not add *snucked*;
# *sneaking* is the present participle; do not add *snucking* from *snuck*).
def morph_base_allows_verb_forms?(base, inflected, pos_map, forms_map, zipf_inf, wordfreq_hash = nil, list_authoritative_base: false, kaikki_verb_morph: nil)
  inflection_suffix_kind = Inflect.send(:match_suffix_kind, base, inflected)
  return true unless inflection_suffix_kind == :ed || inflection_suffix_kind == :ing

  # No *-ing* on regular *-ed* participles (*whipped*→*whippeding*). Short *-ed* stems (e.g. *bed*) skip.
  if inflection_suffix_kind == :ing && base.end_with?("ed") && base.bytesize >= 5
    return false
  end

  # No stacking *-ed* onto a surface that is already a productive *-s* inflection (*presents*→*presentsed*).
  if inflection_suffix_kind == :ed && inflected == base + "ed" && base.bytesize >= 5 &&
      base.end_with?("s") && !base.end_with?("ss", "us", "is")
    stem_candidate = base.byteslice(0, base.bytesize - 1)
    if stem_candidate.bytesize >= 3 && Inflect.inflection_of_base?(stem_candidate, base)
      return false
    end
  end

  # Same pattern for *-ing* (*presents*→*presentsing*).
  if inflection_suffix_kind == :ing && inflected == base + "ing" && base.bytesize >= 5 &&
      base.end_with?("s") && !base.end_with?("ss", "us", "is")
    stem_candidate = base.byteslice(0, base.bytesize - 1)
    if stem_candidate.bytesize >= 3 && Inflect.inflection_of_base?(stem_candidate, base)
      return false
    end
  end

  # Inflect consonant-doubling: *presents*+*s*+*ed*→*presentssed* (and *…sing*). Block when *base* is
  # already a productive *-s* surface of a WordNet lemma (*present*→*presents*); *gas*→*gassed* stays
  # allowed (*ga* is not a WN headword).
  if (inflection_suffix_kind == :ed || inflection_suffix_kind == :ing) &&
      base.end_with?("s") && !base.end_with?("ss", "us", "is") && base.bytesize >= 5
    stem_one_s = base.byteslice(0, base.bytesize - 1)
    if stem_one_s.bytesize >= 4 && Inflect.inflection_of_base?(stem_one_s, base) && wn_has_entry?(stem_one_s)
      if (inflection_suffix_kind == :ed && inflected == base + "s" + "ed") ||
          (inflection_suffix_kind == :ing && inflected == base + "s" + "ing")
        return false
      end
    end
  end

  # *presentss*: Inflect accepts *presents*+*s*; block *-ed/-ing* when one *s* peeler yields a known
  # headword that already inflects to base (*harness*→*harnes* is not lexical, so it passes).
  if (inflection_suffix_kind == :ed || inflection_suffix_kind == :ing) && base.end_with?("ss") && base.bytesize >= 6 && wordfreq_hash
    chop = base.byteslice(0, base.bytesize - 1)
    if chop.bytesize >= 4 && Inflect.inflection_of_base?(chop, base)
      chop_zipf = (wordfreq_hash[chop] || 0).to_f
      chop_known = wn_has_entry?(chop) || chop_zipf >= WORDFREQ_RARE_ZIPF
      return false if chop_known
    end
  end

  # No second *-ed* on spellings that already end in *-ed* (*sinned*→*sinneded*, *programmed*→*programmedded*).
  # Short bases (*bed*→*bedded*) skip via length floor.
  if inflection_suffix_kind == :ed && base.bytesize >= 5 && base.end_with?("ed") &&
      inflected.start_with?(base) && inflected.bytesize > base.bytesize
    return false
  end

  return false if morph_inflect_ck_double_k_junk?(base, inflected)

  if kaikki_verb_morph && morph_kaikki_redundant_verb_inflection_blocked?(base, inflection_suffix_kind, kaikki_verb_morph)
    return false
  end

  return true if list_authoritative_base

  tags = morph_part_of_speech_tags(pos_map, base)
  wn_in = wn_has_entry?(base)
  wn_v = wn_base_has_verb?(base)

  if tags.any?
    return false unless tags.include?("verb")
    return false if wn_in && !wn_v
    if wn_in && wn_v
      kaikki_ok = wiktionary_derivation_suffix_attested?(forms_map, base, inflection_suffix_kind)
      corpus_ok = corpus_inflection_suffix_zipf_attested?(wordfreq_hash, base, inflection_suffix_kind)
      return false unless kaikki_ok || corpus_ok
      # Deadjectival *-ing* (*greening*) when the lexeme has no verb row: require Zipf on the surface.
      # Lemmas that are *also* verbs (*blog*, *vlog*, *twerk*) use the Kaikki surface / Zipf path below
      # so *blogging* / *vlogged* can inherit when listed/attested without web-scale Zipf on the participle.
      return zipf_inf >= WORDFREQ_RARE_ZIPF if tags.include?("adj") && !tags.include?("verb")
      # Lexeme allows *-ed/-ing* in principle, but each Inflect spelling must be Kaikki-listed or
      # independently Zipf-attested — blocks *catalogging* when only *cataloging* has corpus/Kaikki support.
      return wiktionary_surface_form_attested?(forms_map, base, inflected) ||
        (zipf_inf || 0).to_f >= WORDFREQ_RARE_ZIPF
    end
    return true
  end
  wn_v
end

def pronunciation_vowel_phoneme_count(pron)
  return 0 if pron.nil? || pron.empty?
  pron.phonemes.count { |ph| !ph.syllable_boundary? && ph.vowel? }
end

def silent_e_stem_plus_er?(base, w)
  bl = base.bytesize
  return false unless base.end_with?("e") && bl >= 2 && !base.end_with?("ee")
  w == base.byteslice(0, bl - 1) + "er"
end

def silent_e_stem_plus_est?(base, w)
  bl = base.bytesize
  return false unless base.end_with?("e") && bl >= 2 && !base.end_with?("ee")
  w == base.byteslice(0, bl - 1) + "est"
end

# Blocks *happyer; allows *happier. Non-y: adjective (Kaikki or WN) with phonological / attestation
# rules. Silent-e stem+*er* (*service*→*servicer*) is allowed when the base is verbal and the
# derived form has independent Zipf (blocks *oranger*-style junk while keeping attested agents).
def morph_base_allows_comparative_er_est?(base, w, pos_map, base_first_pron, forms_map, zipf_w)
  inflection_suffix_kind = Inflect.send(:match_suffix_kind, base, w)
  return true unless inflection_suffix_kind == :er || inflection_suffix_kind == :est

  return false if morph_inflect_ck_double_k_junk?(base, w)

  # Standard English uses *more/most* for many *-less* adjectives; block synthetic *-er/-est* unless Kaikki attests.
  if base.end_with?("less") && base.bytesize >= 6
    return false unless wiktionary_surface_form_attested?(forms_map, base, w)
  end

  # No *-er/-est* on plural / 3sg *-s* surfaces (*needles*→*needlesest*, *poses*→*poseser*) unless attested.
  bl = base.bytesize
  if bl >= 5 && base.end_with?("s") && !base.end_with?("ss", "us", "is")
    stem_candidate = base.byteslice(0, bl - 1)
    if stem_candidate.bytesize >= 3 && Inflect.inflection_of_base?(stem_candidate, base)
      return false unless wiktionary_surface_form_attested?(forms_map, base, w)
    end
  end

  # *-y*→*-ier/-iest* is for adjectives (*happy*→*happier*), not nouns (*buddy*→*buddier* junk).
  if base.end_with?("y") && bl >= 2
    stem = base.byteslice(0, bl - 1)
    return false if w == base + "er" || w == base + "est"
    if w == stem + "ier" || w == stem + "iest"
      tags_y = morph_part_of_speech_tags(pos_map, base)
      adj_y = tags_y.any? ? tags_y.include?("adj") : wn_base_has_adjective?(base)
      return false unless adj_y
      # Kaikki adj tag without WordNet confirmation (base is OOV in WN, or WN has the base
      # without an adj sense): the adj sense is typically dialectal/marginal and Kaikki
      # sometimes lists dialectal comparatives (*thingy*→*thingier*) with no corpus footprint.
      # wn_base_has_adjective? is default-lenient (returns true for OOV bases) so we use
      # wn_has_entry? to gate it. Require BOTH Kaikki attestation AND surface Zipf.
      kaikki_adj_unconfirmed = tags_y.include?("adj") &&
        !(wn_has_entry?(base) && wn_base_has_adjective?(base))
      if tags_y.any? && kaikki_adj_unconfirmed
        return false unless wiktionary_surface_form_attested?(forms_map, base, w)
        return zipf_w >= WORDFREQ_RARE_ZIPF
      end
      return true
    end
    return false
  end

  # Silent-e *stem+est* on a verbal lemma (*waste*→*wastest*): require corpus or Kaikki; real superlatives
  # (*finest*, *gentlest*) stay attested / Zipf-backed.
  if inflection_suffix_kind == :est && silent_e_stem_plus_est?(base, w) && wn_base_has_verb?(base)
    return wiktionary_surface_form_attested?(forms_map, base, w) ||
      zipf_w.to_f >= WORDFREQ_RARE_ZIPF
  end

  if inflection_suffix_kind == :er && silent_e_stem_plus_er?(base, w)
    tags = morph_part_of_speech_tags(pos_map, base)
    zip_ok = zipf_w >= WORDFREQ_RARE_ZIPF
    verbal_nouny = if tags.any?
      tags.include?("verb") && tags.include?("noun")
    else
      wn_base_has_verb?(base) && wn_base_has_noun?(base)
    end
    if verbal_nouny && (!tags.any? || !tags.include?("adj") || zip_ok)
      return true if zip_ok || wiktionary_surface_form_attested?(forms_map, base, w)
    end
  end

  tags = morph_part_of_speech_tags(pos_map, base)
  adj_ok = tags.any? ? tags.include?("adj") : wn_base_has_adjective?(base)
  return false unless adj_ok

  vc = pronunciation_vowel_phoneme_count(base_first_pron)
  attested = wiktionary_surface_form_attested?(forms_map, base, w)
  if tags.any?
    # Without a pronunciation we cannot count vowels; do not treat as monosyllable (avoids *impromptuer*
    # slipping through when the base has frequency but no surviving ARPABET row).
    # Lemma is both noun and adjective (*liege*, *nice*): do not bypass attestation on monosyllables
    # (*lieger* / *liegest*); *nicer* / *nicest* remain Kaikki-attested.
    noun_and_adj = tags.include?("noun") && tags.include?("adj")
    # Monosyllable adj shortcut used to bypass Kaikki attestation for silent-e comparatives
    # (*safe*→*safer*). But Kaikki-only adj-tagged bases with no verb/noun tag (*liege*=["adj"])
    # slipped unattested comparatives through; require either Kaikki attestation or surface
    # Zipf so *lieger* (zipf=0, no forms row) fails while *safer*/*nicer* still pass.
    if base_first_pron && !base_first_pron.empty? && vc <= 1 && !noun_and_adj
      return true if attested || zipf_w >= WORDFREQ_RARE_ZIPF
    end
    return false unless attested
    # Kaikki adj without WN adj confirmation (OOV-in-WN or WN-present-without-adj): require
    # surface Zipf on top of Kaikki attestation. Blocks phantom comparatives for bases whose
    # adj sense is dialectal/marginal.
    kaikki_adj_unconfirmed = tags.include?("adj") &&
      !(wn_has_entry?(base) && wn_base_has_adjective?(base))
    if kaikki_adj_unconfirmed
      return zipf_w >= WORDFREQ_RARE_ZIPF
    end
    # Surface Zipf evidence required for all other Kaikki-attested comparatives; blocks
    # phantom comparatives Kaikki lists for archaic/marginal senses even when the base has
    # verb+noun+adj tags.
    zipf_w >= WORDFREQ_RARE_ZIPF
  else
    return true if base_first_pron && !base_first_pron.empty? && vc <= 2 &&
      !(wn_base_has_noun?(base) && wn_base_has_adjective?(base))
    attested
  end
end

# Plural *:s*: Kaikki noun when present; WordNet noun cross-check. When Kaikki lists both adj
# and noun on the same lemma, require a Kaikki form row for that plural (blocks *impromptus*).
#
# Pure noun lemmas: Inflect *+s* alone is not enough — require Kaikki listing for this plural **or**
# dialogue presence (SUBTLEX FREQlow>0) **or** strong wordfreq (Zipf ≥ WORDFREQ_COMMON_ZIPF).
#
# We do **not** use WORDFREQ_RARE_ZIPF alone here: erroneous *+s* plurals (*sheeps* ~2.2) sit in the
# 2.0–2.9 band from web text but lack subtitle use; SUBTLEX or common Zipf separates them from real plurals.
#
# WordNet **mass-dominant** nouns (wn_noun_base_mass_dominant_for_productive_plural?) and **feeling+attribute**
# lemmas (wn_noun_base_feeling_plus_attribute_plural_needs_own_corpus?, e.g. *indifference*): Inflect *+s* is
# allowed only when the **plural surface** itself is dialogue- or Zipf-strong — not when Kaikki merely lists
# the form. That blocks *nostalgias* / *chaoses* / *goodwills* and keeps *indifferences* from inheriting a
# common base tier while *apples* (noun.plant) still promotes via Wiktionary / SUBTLEX / Zipf as before.
def morph_base_allows_plural_s?(base, pos_map, forms_map, plural_word, wordfreq_hash: nil, subtlex_hash: nil)
  # Kaikki-attested plural of an otherwise adj/verb-coded base whose plural has corpus evidence
  # (*observables* zipf 2.11, *malignancies* zipf 2.53, *biopics* zipf 1.88): trust Wiktionary's
  # attestation of the exact plural surface. Requires corpus evidence (wordfreq Zipf ≥ RARE or
  # SUBTLEX dialogue trickle) so mass-noun spurious plurals Kaikki lists but real corpora don't
  # attest (*informations*, *advices*) are still blocked.
  if wiktionary_surface_form_attested?(forms_map, base, plural_word) &&
     !morph_spurious_plural_s_on_invariant_noun?(plural_word)
    wf_p = (wordfreq_hash && wordfreq_hash[plural_word]) || 0
    sub_p = (subtlex_hash && subtlex_hash[plural_word]) || 0
    tags_b = morph_part_of_speech_tags(pos_map, base)
    # Adj-tagged base (often adj-primary with a marginal noun sense, e.g. *ambient*, *thick*):
    # slangy/conversational plurals can register as subtitle noise even when Kaikki lists the form
    # as a plural. Demand Zipf ≥ RARE on the plural surface so we only promote productive nominal
    # plurals (*blacks* wf>4, *goods* wf>5) and not casual usages (*ambients* wf=1.36, *thicks* wf=1.05).
    if tags_b.any? && tags_b.include?("adj")
      return true if wf_p >= WORDFREQ_RARE_ZIPF
    else
      return true if wf_p >= WORDFREQ_RARE_ZIPF || sub_p > 0
    end
  end

  tags = morph_part_of_speech_tags(pos_map, base)
  if tags.any?
    # Verb-only lemmas: treat trailing -s as 3sg (*twerks*), not a noun plural (*gooses* is noun+verb).
    return true if tags.include?("verb") && !tags.include?("noun")
    return false unless tags.include?("noun")
    return false if wn_has_entry?(base) && !wn_base_has_noun?(base)
    return false if morph_spurious_plural_s_on_invariant_noun?(plural_word)
    if tags.include?("adj")
      # Kaikki listing alone is not enough for adj-tagged bases: add a plural-surface Zipf floor
      # (*ambients*/1.36, *thicks*/1.05 fail; productive adj→noun plurals like *blacks*/*goods* pass).
      return false unless wiktionary_surface_form_attested?(forms_map, base, plural_word)
      wf_p = (wordfreq_hash && wordfreq_hash[plural_word]) || 0
      return wf_p >= WORDFREQ_RARE_ZIPF
    end
    if wn_noun_base_mass_dominant_for_productive_plural?(base) ||
       wn_noun_base_feeling_plus_attribute_plural_needs_own_corpus?(base)
      return (subtlex_hash && subtlex_hash[plural_word].to_i > 0) ||
             (wordfreq_hash && (wordfreq_hash[plural_word] || 0).to_f >= WORDFREQ_COMMON_ZIPF)
    end
    return true if wiktionary_surface_form_attested?(forms_map, base, plural_word)
    if subtlex_hash && subtlex_hash[plural_word].to_i > 0
      return true
    end
    if wordfreq_hash && (wordfreq_hash[plural_word] || 0).to_f >= WORDFREQ_COMMON_ZIPF
      return true
    end

    return false
  end
  !morph_spurious_plural_s_on_invariant_noun?(plural_word)
end

# $inflection_base_words (filled in dict.rb) maps Wiktionary/Kaikki surfaces to their lemma.
# When surface is recorded as an inflected form of a *different* headword, the list-pivot
# Inflect inheritance and common-list Inflect expansion passes must not treat it as an
# Inflect *stem* — forward rules would stack suffixes on participles
# (*cataloging*→*catalogings*).
def morph_kaikki_lists_surface_as_inflected_nonlemma?(surface)
  lex = $inflection_base_words[surface]
  lex && lex != surface
end

# True when base is itself a plural surface form of an anchored singular: ends in s
# and a candidate singular (Inflect's plural-strip — drop -s, drop -es, -ies → -y,
# silent-e restoration) is in hash, neol_words, common_words, or has wordfreq-attested
# real-word use. Used by the Inflect-expansion passes to suppress spurious double plurals
# (*parasailingses* from neol-listed *parasailings* whose singular *parasailing* is also in
# neol). Targets the case where the lemma never makes it into Kaikki's
# $inflection_base_words but the morphology is still transparent — Kaikki-attested
# inflected surfaces are already caught upstream by
# morph_kaikki_lists_surface_as_inflected_nonlemma?.
def morph_base_is_already_plural_form?(base, hash, neol_words, common_words, wordfreq_hash)
  return false if base.nil? || base.bytesize <= 2
  return false unless base.end_with?("s")
  Inflect.raw_candidate_bases_for_inflected(base).any? do |singular|
    next false if singular == base
    hash.key?(singular) ||
      (neol_words && neol_words.include?(singular)) ||
      (common_words && common_words.include?(singular)) ||
      (wordfreq_hash && (wordfreq_hash[singular] || 0).to_f >= WORDFREQ_COMMON_ZIPF)
  end
end

# *ccses* / *cdses* / *idses*: Inflect's sibilant rule attaches *-es* to stems ending in *-s*,
# but when that stem is already a regular *…+s* plural (*ccs*←*cc*, *ids*←*id*), English never
# stacks another *-es*. Kaikki/CMU paradigm rows still show up; keep *buses* / *gases* via
# Zipf ≥ COMMON (stems *bus* / *gas* are not “already plural” in the same sense — *bu*/*ga*
# are spurious singular chops, but those surfaces are independently common in wordfreq).
def morph_spurious_plural_ses_after_s_plural_stem?(word, hash, neol_words, common_words, wordfreq_hash, subtlex_hash)
  return false if word.nil? || word.bytesize < 5
  return false unless word.end_with?("ses")
  bl = word.bytesize
  stem = word.byteslice(0, bl - 2)
  return false unless stem.end_with?("s") && !stem.end_with?("ss")
  return false unless Inflect.match_suffix_kind(stem, word) == :s
  return false unless morph_base_is_already_plural_form?(stem, hash, neol_words, common_words, wordfreq_hash)
  wf = (wordfreq_hash[word] || 0).to_f
  return false if wf >= WORDFREQ_COMMON_ZIPF
  sub = (subtlex_hash[word] || 0).to_i
  return false if sub >= MORPH_LEXICAL_NOUN_PLURAL_SUBTLEX_MIN
  true
end

# Syllabified pronunciation for inflected_word from base_word's first CMU pron, or nil.
# Same final-cluster whitelist gate as merge_inflected_forms! (common-list / SUBTLEX-anchored Inflect expansion).
def morph_derived_syllabified_pronunciation(base_pron, base_word, inflected_word)
  derived = Inflect.derive(base_pron, base_word, inflected_word)
  return nil if derived.nil? || derived.empty?
  return nil unless derived.phonemes.any?(&:vowel?)
  syllabified = normalize_flat_arphabet_pronunciation(derived).syllabify
  unless WHITELIST.include?(inflected_word)
    return nil unless final_consonant_cluster_ok?(syllabified.final_consonant_cluster_array)
  end
  check_syllable_vowel_invariant!(syllabified, inflected_word, "morph_derived")
  syllabified
end

def morph_derived_prons_for_promotion(base_prons, base_word, inflected_word)
  return [] if base_prons.nil? || base_prons.empty?
  syll = morph_derived_syllabified_pronunciation(base_prons.first, base_word, inflected_word)
  syll ? [syll] : []
end

# Pronunciation for colloquial *…in'* from the syllabified *…ing* form: final NG → N, and the vowel
# immediately before that NG is set to AH0 (schwa) so the rime aligns with *taken*/*waken* without
# with_dwimmed_schwas on the whole word.
def morph_gdropped_in_apostrophe_syllabified_pronunciation(ing_syll, in_prime_word)
  return nil if ing_syll.nil? || ing_syll.empty?

  ph = ing_syll.phonemes.reject { |p| p == "." }
  return nil if ph.length < 2

  last = ph.last
  return nil unless last.tr("0-2", "") == "NG"

  penult = ph[-2]
  return nil unless penult.vowel?

  new_flat = Pronunciation.new(ph[0..-3] + ["AH0", "N"])
  syllabified = normalize_flat_arphabet_pronunciation(new_flat).syllabify
  unless WHITELIST.include?(in_prime_word)
    return nil unless final_consonant_cluster_ok?(syllabified.final_consonant_cluster_array)
  end
  check_syllable_vowel_invariant!(syllabified, in_prime_word, "morph_gdropped_in_apostrophe")
  syllabified
end

# Kaikki-attested verbal *…ing* → colloquial *…in'* (not in CMU); same attestation gate as merge_inflected_forms!.
def merge_gdropped_in_apostrophe_forms!(pronunciation_map, forms_map)
  added = 0
  forms_map.each do |base_word, form_pairs|
    next unless wn_base_has_verb?(base_word)

    form_pairs.each do |inflected_word, b|
      next unless b == base_word
      next unless inflected_word.end_with?("ing")
      next unless pronunciation_map.key?(inflected_word)

      in_prime = Inflect.gdropped_in_apostrophe_spelling(base_word, inflected_word)
      next if in_prime.nil?
      next if pronunciation_map.key?(in_prime)
      next if ignore_cmudict_word?(in_prime, pronunciation_map)

      ing_prons = pronunciation_map[inflected_word]
      next if ing_prons.nil? || ing_prons.empty?

      syll = morph_gdropped_in_apostrophe_syllabified_pronunciation(ing_prons.first, in_prime)
      next if syll.nil?

      pronunciation_map[in_prime] = [syll]
      added += 1
      dict_trace_puts(in_prime, "g-drop merge: ← #{inflected_word} (base=#{base_word})") if dict_trace_word?(in_prime)
    end
  end
  puts "Generated #{added} g-dropped *in'* pronunciations from verbal *ing*" if added > 0
  added
end

def merge_inflected_forms!(pronunciation_map, forms_map)
  added = 0
  forms_map.each do |base_word, form_pairs|
    base_prons = pronunciation_map[base_word]
    next if base_prons.nil? || base_prons.empty?

    base_pron = base_prons.first
    form_pairs.each do |inflected_word, _|
      next if pronunciation_map.key?(inflected_word)
      next if ignore_cmudict_word?(inflected_word, pronunciation_map)

      syllabified = morph_derived_syllabified_pronunciation(base_pron, base_word, inflected_word)
      next if syllabified.nil?

      pronunciation_map[inflected_word] = [syllabified]
      added += 1
    end
  end
  puts "Generated #{added} inflected-form pronunciations"
end
