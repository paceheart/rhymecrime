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

# Kaikki listed this exact surface as an inflected form of +base+ (+collect_inflected_forms+).
def wiktionary_surface_form_attested?(forms_map, base, inflected)
  pairs = forms_map[base]
  return false if pairs.nil? || pairs.empty?
  pairs.any? { |form, b| form == inflected && b == base }
end

# True if Kaikki lists any surface for +base+ whose Inflect suffix kind matches +suffix_kind+ (:ed, :ing, …).
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

# True if some Inflect-derived surface for +base+ with suffix +suffix_kind+ reaches RARE Zipf in Wordfreq.
# With +morph_base_allows_verb_forms?+, lexeme-level allowance still requires per-surface Kaikki or Zipf
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
# (+kaikki_verb_morph+ from +load_wiktionary+).
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

# -ed/-ing: Kaikki +verb+ when present; cross-check WordNet so noun-only lemmas do not inherit
# verbal junk (FP-4). When both Kaikki and WordNet agree the base is a verb, require a Kaikki
# surface row. If Kaikki also lists +adj+ on the lemma, require Wordfreq Zipf on the inflected
# surface so lexicon rows for marginal verbs (e.g. *taboo*) do not promote rare *tabooed* when
# corpus use is negligible. OOV bases (no WordNet entry) keep the legacy open policy.
#
# When +list_authoritative_base+ is true (Phase 9 only), skip Kaikki/corpus verb attestation: entries in
# common_words.txt are curated list headwords (*finesse*→*finessed* must inherit).
#
# +kaikki_verb_morph+ (from +load_wiktionary+): blocks Inflect *-ed*/*-ing* when Kaikki already documents
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
  # headword that already inflects to +base+ (*harness*→*harnes* is not lexical, so it passes).
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
      return zipf_inf >= WORDFREQ_RARE_ZIPF if tags.include?("adj")
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

# Blocks *happyer; allows *happier. Non-+y+: adjective (Kaikki or WN) with phonological / attestation
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
      return true
    end
    return false
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
    return true if base_first_pron && !base_first_pron.empty? && vc <= 1
    return false unless attested
    # Attested comparatives from adjective-only (or non-verb) lemmas still need corpus support on
    # the surface itself; otherwise *impromptuer* inherits *impromptu*’s frequency (FP).
    return zipf_w >= WORDFREQ_RARE_ZIPF unless tags.include?("verb")
    true
  else
    return true if base_first_pron && !base_first_pron.empty? && vc <= 2
    attested
  end
end

# Plural *:s*: Kaikki +noun+ when present; WordNet noun cross-check. When Kaikki lists both +adj+
# and +noun+ on the same lemma, require a Kaikki form row for that plural (blocks *impromptus*).
#
# Pure noun lemmas: Inflect *+s* alone is not enough — require Kaikki listing for this plural **or**
# dialogue presence (SUBTLEX FREQlow>0) **or** strong wordfreq (Zipf ≥ +WORDFREQ_COMMON_ZIPF+).
#
# We do **not** use +WORDFREQ_RARE_ZIPF+ alone here: erroneous *+s* plurals (*sheeps* ~2.2) sit in the
# 2.0–2.9 band from web text but lack subtitle use; SUBTLEX or common Zipf separates them from real plurals.
def morph_base_allows_plural_s?(base, pos_map, forms_map, plural_word, wordfreq_hash: nil, subtlex_hash: nil)
  tags = morph_part_of_speech_tags(pos_map, base)
  if tags.any?
    # Verb-only lemmas: treat trailing -s as 3sg (*twerks*), not a noun plural (*gooses* is noun+verb).
    return true if tags.include?("verb") && !tags.include?("noun")
    return false unless tags.include?("noun")
    return false if wn_has_entry?(base) && !wn_base_has_noun?(base)
    if tags.include?("adj")
      return wiktionary_surface_form_attested?(forms_map, base, plural_word)
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
  true
end

# +$inflection_base_words+ (filled in +dict.rb+) maps Wiktionary/Kaikki surfaces to their lemma.
# When +surface+ is recorded as an inflected form of a *different* headword, Phase 9/10 must not treat it
# as an Inflect *stem* — forward rules would stack suffixes on participles (*cataloging*→*catalogings*).
def morph_kaikki_lists_surface_as_inflected_nonlemma?(surface)
  lex = $inflection_base_words[surface]
  lex && lex != surface
end

# Syllabified pronunciation for +inflected_word+ from +base_word+'s first CMU pron, or nil.
# Same final-cluster whitelist gate as merge_inflected_forms! (Phase 10/11 morph promotion).
def morph_derived_syllabified_pronunciation(base_pron, base_word, inflected_word)
  derived = Inflect.derive(base_pron, base_word, inflected_word)
  return nil if derived.nil? || derived.empty?
  return nil unless derived.phonemes.any?(&:vowel?)
  syllabified = normalize_flat_arphabet_pronunciation(derived).syllabify
  unless WHITELIST.include?(inflected_word)
    return nil unless final_consonant_cluster_ok?(syllabified.final_consonant_cluster_array)
  end
  syllabified
end

def morph_derived_prons_for_promotion(base_prons, base_word, inflected_word)
  return [] if base_prons.nil? || base_prons.empty?
  syll = morph_derived_syllabified_pronunciation(base_prons.first, base_word, inflected_word)
  syll ? [syll] : []
end

# Pronunciation for colloquial *…in'* from the syllabified *…ing* form: final NG → N, and the vowel
# immediately before that NG is set to AH0 (schwa) so the rime aligns with *taken*/*waken* without
# +with_dwimmed_schwas+ on the whole word.
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
  syllabified
end

# Kaikki-attested verbal *…ing* → colloquial *…in'* (not in CMU); same attestation gate as +merge_inflected_forms!+.
def merge_gdropped_in_apostrophe_forms!(cmudict, forms_map)
  added = 0
  forms_map.each do |base_word, form_pairs|
    next unless wn_base_has_verb?(base_word)

    form_pairs.each do |inflected_word, b|
      next unless b == base_word
      next unless inflected_word.end_with?("ing")
      next unless cmudict.key?(inflected_word)

      in_prime = Inflect.gdropped_in_apostrophe_spelling(base_word, inflected_word)
      next if in_prime.nil?
      next if cmudict.key?(in_prime)
      next if ignore_cmudict_word?(in_prime, cmudict)

      ing_prons = cmudict[inflected_word]
      next if ing_prons.nil? || ing_prons.empty?

      syll = morph_gdropped_in_apostrophe_syllabified_pronunciation(ing_prons.first, in_prime)
      next if syll.nil?

      cmudict[in_prime] = [syll]
      added += 1
      dict_trace_puts(in_prime, "g-drop merge: ← #{inflected_word} (base=#{base_word})") if dict_trace_word?(in_prime)
    end
  end
  puts "Generated #{added} g-dropped *in'* pronunciations from verbal *ing*" if added > 0
  added
end

def merge_inflected_forms!(cmudict, forms_map)
  added = 0
  forms_map.each do |base_word, form_pairs|
    base_prons = cmudict[base_word]
    next if base_prons.nil? || base_prons.empty?

    base_pron = base_prons.first
    form_pairs.each do |inflected_word, _|
      next if cmudict.key?(inflected_word)
      next if ignore_cmudict_word?(inflected_word, cmudict)

      syllabified = morph_derived_syllabified_pronunciation(base_pron, base_word, inflected_word)
      next if syllabified.nil?

      cmudict[inflected_word] = [syllabified]
      added += 1
    end
  end
  puts "Generated #{added} inflected-form pronunciations"
end
