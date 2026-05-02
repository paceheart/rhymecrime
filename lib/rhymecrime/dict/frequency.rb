# encoding: utf-8
# SUBTLEX / wordfreq I/O, compute_frequency, add_frequency_info phases, build_word_dict.

require "set"
require_relative "utils_rhyme"
require_relative "constants"
require_relative "lexical"
require_relative "morphology"
require_relative "phonology"
require_relative "rime"
require_relative "rarity_signals"
require_relative "rarity_classifier"

#
# SUBTLEX-US (movie subtitle corpus, 51M words, 74K unique word forms)
# Source: Brysbaert & New (2009), full TSV from openlexicon.fr
# We use FREQlow (lowercase occurrences only) to avoid counting
# sentence-initial capitalization and proper noun uses.
#

def load_word_list_set(path)
  s = Set.new
  File.foreach(path, chomp: true, encoding: "UTF-8") do |line|
    next if line.empty?

    s.add(line)
  end
  s
end

def load_subtlex()
  subtlex_hash = Hash.new(0)
  subtlex_total_hash = Hash.new(0)
  first = true
  File.foreach(SUBTLEX_FILENAME, encoding: "UTF-8") do |line|
    if first
      first = false
      next
    end
    fields = line.chomp.split("\t")
    word_lower = fields[0].downcase
    freq_total = fields[1].to_i
    freq_low = fields[3].to_i
    subtlex_hash[word_lower] = freq_low if freq_low > subtlex_hash[word_lower]
    # Sum across case variants so Cabot(85)+cabot(?) both roll into cabot's total.
    subtlex_total_hash[word_lower] += freq_total
  end
  puts "Loaded #{subtlex_hash.length} words from SUBTLEX-US"
  install_hyphen_collapse_fallback_default_proc!(subtlex_hash, 0)
  install_hyphen_collapse_fallback_default_proc!(subtlex_total_hash, 0)
  return subtlex_hash, subtlex_total_hash
end

# SUBTLEX-US and wordfreq both strip hyphens during tokenization, so *so-so* /
# *mafioso* / *ha-ha* / *good-bye* never appear under their hyphenated spelling;
# every occurrence is silently rolled into the dehyphenated key (*soso*,
# *hahaha*, *goodbye*). Verified empirically against our corpus snapshots: both
# files have zero hyphenated headwords. Without a bridge every hyphenated CMU /
# authoritative surface reads as freq=0, and bucket pruning kills pairs like
# +so-so+/+mafioso+ (+OW_S_OW+): one common anchor + a rare partner trips
# +rime_bucket_one_common_preferred_with_any_rare?+ even though the "rare"
# partner is really a perfectly ordinary English word whose corpus evidence is
# hiding under the dehyphenated spelling.
#
# Install a +default_proc+ that transparently falls back from +foo-bar+ reads to
# +foobar+'s value. Reads only: +key?+, +fetch+ with no default, and iteration
# stay literal so "is this token in the TSV?" checks (+in_wordfreq_tsv+,
# +wordfreq_hash.key?+) still reflect the raw corpus contents.
def install_hyphen_collapse_fallback_default_proc!(hash, missing_value)
  hash.default_proc = proc do |h, k|
    if k.is_a?(String) && k.include?("-")
      dh = k.delete("-")
      next missing_value if dh == k || dh.empty?
      h.key?(dh) ? h[dh] : missing_value
    else
      missing_value
    end
  end
  hash
end

# Fraction of SUBTLEX occurrences that are capitalized (proxy for proper-noun-ness).
# Returns nil when total occurrences are too few to be reliable.
def subtlex_capitalized_ratio(word, subtlex_hash, subtlex_total_hash)
  total = (subtlex_total_hash && subtlex_total_hash[word]) || 0
  return nil if total < SUBTLEX_PROPER_NOUN_MIN_TOTAL
  low = subtlex_hash[word] || 0
  1.0 - (low.to_f / total.to_f)
end

# True when case distribution across SUBTLEX and Kaikki indicates the word is predominantly a
# proper noun / encyclopedic entry. Both signals require SUBTLEX FREQlow ≤ max_low so real common
# names used in dialogue (*Michael* FREQlow 5, *Italian* 24, *Cajun* 3) are not swept up with
# obscure proper nouns (*Cabot* 1, *Leicester* 0, *Kant* 0).
#
#   - Kaikki capitalized-only: headword never appears lowercase in any Wiktionary entry (*Modena*,
#     *Cabot*, *Lawton*).
#   - SUBTLEX capitalized ratio ≥ threshold (*Cabot* 0.99, *Mott* 1.0, *Patricia* 1.0, *Brant* 0.88).
#
# +max_low+ defaults to SUBTLEX_PROPER_NOUN_MAX_FREQLOW (2), the strict setting used with a WN
# anchor (where pentagon 12 / chicago 12 are legitimate common-noun senses we must preserve).
# Callers may raise +max_low+ to SUBTLEX_OVERRIDE_PROPER_MIN (12) when the word is OOV in WordNet,
# to catch mid-FREQlow names (*shi* 12, *strom* 5, *mong* 3) that have no WN common-noun risk.
def likely_proper_noun_by_case?(word, subtlex_hash, subtlex_total_hash, kaikki_capitalized_only,
                                 max_low: SUBTLEX_PROPER_NOUN_MAX_FREQLOW)
  sub_low = (subtlex_hash && subtlex_hash[word]) || 0
  return false if sub_low > max_low
  return true if kaikki_capitalized_only && kaikki_capitalized_only.include?(word)
  ratio = subtlex_capitalized_ratio(word, subtlex_hash, subtlex_total_hash)
  return true if ratio && ratio >= SUBTLEX_PROPER_NOUN_RATIO_MIN
  false
end

# True if +w+ hits at least one external lexicon used for runtime relatedness / audit (wordfreq TSV,
# SUBTLEX FREQlow, WordNet lemma, pre-merge CMU headword, USF cue/target, ConceptNet lemma cache,
# Numberbatch embedding list). Used to block morph phases from copying base_freq>RARE_FREQ_MAX onto
# surfaces that exist only via Kaikki/Inflect (e.g. *necrophilias*).
def inflection_surface_reference_attested?(w, subtlex_hash, wordfreq_hash, original_cmudict_headwords, cn_vocab, nb_token_set, usf_word_set, neol_words: nil)
  return true if wordfreq_hash.key?(w)
  return true if (subtlex_hash[w] || 0).to_i > 0
  return true if wn_has_entry?(w)
  return true if original_cmudict_headwords.include?(w)
  return true if neol_words&.include?(w)
  return true if usf_word_set.include?(w)

  u = hyphens_to_underscores(w)
  return true if cn_vocab&.include?(u)
  return true if nb_token_set&.include?(u)

  false
end

def subtlex_frequency(word, subtlex_hash)
  count = subtlex_hash[word]
  return 0 if count == 0
  SUBTLEX_PRESENCE_BONUS + Math.log2(count).round
end

#
# wordfreq (frozen 2021, aggregates Wikipedia/Reddit/Twitter/OpenSubtitles/Common Crawl)
#

def load_wordfreq()
  wordfreq_hash = Hash.new
  unless File.exist?(WORDFREQ_FILENAME)
    puts "Warning: #{WORDFREQ_FILENAME} not found, skipping wordfreq"
    install_hyphen_collapse_fallback_default_proc!(wordfreq_hash, nil)
    return wordfreq_hash
  end
  File.foreach(WORDFREQ_FILENAME, encoding: 'UTF-8') do |line|
    word, zipf_str = line.chomp.split("\t")
    next if word.nil? || zipf_str.nil?
    wordfreq_hash[word] = zipf_str.to_f
  end
  puts "Loaded #{wordfreq_hash.length} words from wordfreq"
  install_hyphen_collapse_fallback_default_proc!(wordfreq_hash, nil)
  wordfreq_hash
end
# Kaikki +wordfreq+ OOV rescue (idea 2b): forms in +forms_map+ whose +base+ has wordfreq Zipf ≥ +zipf_floor+.
# Does not use Inflect forward derivation (idea 2a) — too many FPs.
# Skip -ing / -ed forms whose base is a non-verb in WordNet (*kitchen* noun ⇒ *kitchening* rescue
# denied): Kaikki often lists deverbal participle-shape forms for nouns that English doesn't
# verbify. The morph inheritance / expansion passes already refuse to promote these, but the disconnect rescue kept them at
# freq 0 which reads as :rare (*jealousing*, *opinioning*, *attorneying*, *conversationing*).
def kaikki_form_oov_rescue_headwords(forms_map, wordfreq_hash, zipf_floor, wiktionary_words = nil)
  out = Set.new
  wk = wiktionary_words || Set.new
  forms_map.each do |base, pairs|
    z = wordfreq_hash[base] || 0
    anchored = z >= zipf_floor ||
      (wk.include?(base) && z >= WORDFREQ_KAIKKI_FORM_BASE_MIN)
    next unless anchored
    base_wn_noun_only = wn_has_entry?(base) && !wn_base_has_verb?(base)
    pairs.each do |form, b|
      next unless b == base
      if base_wn_noun_only && (form.end_with?("ing") || form.end_with?("ed")) && form != base
        next
      end
      # Forms with zero wordfreq trace are Wiktionary-paradigm junk (*bravados*, *gollies*,
      # *polyed*, *hocused*). Legitimate rare inflections of attested bases register at least
      # a floor Zipf. Skip this rescue path for them; the disconnect filter's Kaikki-paradigm
      # branch still rescues zero-wordfreq forms when the base has a POS-appropriate WordNet
      # entry (agoraphobias, necrophilias, nostalgias).
      next unless wordfreq_hash.key?(form)
      out.add(form)
    end
  end
  out
end

def subtlex_freqlow_positive?(w, subtlex_hash)
  (subtlex_hash[w] || 0).positive?
end

# Strict wordfreq-OOV anchors: Kaikki form-of-Zipf≥RARE base (2b) ∪ SUBTLEX FREQlow>0 ∪ WordNet lemma.
# Kaikki lexical POS alone is excluded (CMU artefacts like +mopus+). +pos_map+ unused; kept for call-site API.
def wordfreq_oov_lexical_rescue?(w, subtlex_hash, wordfreq_hash, pos_map, kaikki_form_rescue_set)
  return false if wordfreq_hash.key?(w)
  kaikki_form_rescue_set.include?(w) ||
    subtlex_freqlow_positive?(w, subtlex_hash) ||
    wn_has_entry?(w)
end

# Drop freq==0 headwords that fail the disconnect policy, then prune rime index until fixed point.
#
# Has a +wordfreq_hash+ row (exported wordfreq TSV): never drop here — the token is corpus-attested. Rhyme-only
# OOV junk was removed in earlier rounds; without this, those removals would cascade and evict attested rares
# that no longer have a live rhyme partner and lack a NB/CN/WN hit.
#
# Strict OOV (no wordfreq row): keep only if Kaikki form-of-Zipf≥RARE base (2b) ∪ SUBTLEX FREQlow>0 ∪ WordNet
# lemma — rhyme neighbors alone do not rescue; Kaikki POS alone does not (see +wordfreq_oov_lexical_rescue?+).
# Inflect-from-strong-base (2a) is intentionally not used here (too noisy).
#
# Exception: CMU surface forms written with a hyphen or apostrophe (e.g. okey-dokey, takin') often lack
# WordNet / wordfreq rows but share a live rime bucket; keep them when they were original CMU headwords.
# *-in'* merged after original CMU snapshot (Wiktionary/Inflect, e.g. fakin'): same disconnect case as takin'
# but +original_cmudict_headwords+ does not include them. Pattern is tight (*…in'*); +kitchenin'+ is removed
# earlier if +explicitly_forbidden?+.
# Prunes +rdict+ and re-runs +delete_rare_only_rime_buckets!+ until fixed point so partner removal can cascade.
def cmudict_surface_rhyme_rescue?(word, prons, has_rhyme, original_cmudict_headwords)
  return false unless word.is_a?(String)
  return false if prons.nil? || prons.empty?
  return false unless has_rhyme
  o = original_cmudict_headwords
  return false if o.nil? || (o.respond_to?(:empty?) && o.empty?)

  hyphen_surface = word.include?("-")
  apostrophe_surface = word.include?("'") || word.include?("\u2019")

  if o.include?(word)
    return hyphen_surface || apostrophe_surface
  end

  apostrophe_surface && word.match?(/\A[a-z]+in['\u2019]\z/)
end

# Colloquial g-dropping: prefer *…in'* as the headword. Drop bare *…in* when the apostrophe form is also
# present, *…in* is not an original CMU headword (keeps *puffin*, *bobbin*, …), or *makin* (CMU surname
# homograph) when *makin'* is in original CMU.
def strip_gdrop_bare_homographs!(hash, cmudict_orig)
  removed = 0
  hash.keys.dup.each do |ap|
    next unless ap.is_a?(String)
    next unless ap.match?(/\A[a-z]+in['\u2019]\z/)

    bare = ap.sub(/['\u2019]\z/, "")
    next unless hash.key?(bare)

    strip = !cmudict_orig.include?(bare) || (bare == "makin" && cmudict_orig.include?("makin'"))
    next unless strip

    hash.delete(bare)
    removed += 1
    if dict_trace_word?(bare) || dict_trace_word?(ap)
      focus = [bare, ap].find { |x| dict_trace_word?(x) }
      dict_trace_puts(focus, "g-drop strip: removed bare #{bare} (paired #{ap})")
    end
  end
  puts "Removed #{removed} bare *…in headwords shadowed by colloquial *…in' (g-drop policy)" if removed > 0
  removed
end

def filter_word_dict_disconnected!(word_dict, rdict, subtlex_hash, wordfreq_hash, pos_map, forms_map, original_cmudict_headwords = nil, wiktionary_words = nil)
  dict_set = word_dict.keys.to_set
  nb = nil
  cn = nil
  kaikki_form_rescue_set = kaikki_form_oov_rescue_headwords(forms_map, wordfreq_hash, WORDFREQ_RARE_ZIPF, wiktionary_words)
  rounds = 0
  total_removed = 0
  loop do
    rounds += 1
    removed = 0
    word_dict.keys.each do |w|
      freq, prons = word_dict[w]
      next if freq > 0
      has_rhyme = headword_has_nonidentical_rhyme_partner?(w, prons, rdict, word_dict)
      if dict_trace_word?(w) && freq == 0
        prons.each do |pron|
          next if pron.rime.empty?
          cohort = rdict[pron.rime]
          if cohort.nil? || cohort.empty?
            dict_trace_puts(w, "disconnect: rime=#{pron.rime} has no rdict bucket (dropped as singleton/rare-only cohort earlier) — explains has_rhyme=false vs filter_cmudict message")
          else
            w_pf = preferred_form_in_build_lexicon(w, word_dict)
            others = cohort.reject { |x| x == w_pf }
            dict_trace_puts(w, "disconnect: rime=#{pron.rime} bucket=#{cohort.size} others=#{others.take(10).inspect}#{' …' if others.size > 10}")
          end
        end
      end
      in_wordfreq_tsv = wordfreq_hash.key?(w)
      # Kaikki-documented non-lemma paradigm forms (+polys+ form_of +poly+, +gollies+ form_of +golly+)
      # with weak corpus evidence are Wiktionary-paradigm-only junk: Zipf < RARE (tiny document
      # tail), SUBTLEX FREQcount 1-2 (caption noise). The default "any wordfreq row / any SUBTLEX
      # trickle" rescue keeps them as freq=0 rows which later surface as +:rare+ in +rarity_spec+
      # rather than the expected +:forbidden+. Require a stronger signal — Zipf ≥ RARE, SUBTLEX
      # dialogue above trickle, WN entry, or explicit NB/CN presence — for Kaikki paradigm surfaces.
      # Non-paradigm freq=0 words fall through the normal rescue paths below.
      kaikki_paradigm = morph_kaikki_lists_surface_as_inflected_nonlemma?(w)
      keep = if kaikki_paradigm
               zipf_w = wordfreq_hash[w] || 0
               sub_w = subtlex_hash[w] || 0
               strong_wordfreq = zipf_w >= WORDFREQ_RARE_ZIPF
               strong_subtlex = sub_w >= MORPH_CORPUS_SUBTLEX_MIN
               wnw = wn_has_entry?(w)
               # Base-of-inflection anchor: when Kaikki's +form_of+ lemma has a POS-appropriate
               # WordNet entry (noun for *-s* plural, verb for *-ing* / *-ed*), the Wiktionary
               # paradigm form is a legitimate rare inflection of an attested lexeme and should
               # survive as freq=0 (rarity_spec +:rare+). POS-aware, not "any WN POS", because
               # Kaikki aggressively documents deverbal participles for WN noun-only lemmas
               # (+opinion+→+opinioning+, +kitchen+→+kitchening+, +attorney+→+attorneying+,
               # +conversation+→+conversationing+) that English does not actually verbify.
               # Without this anchor the filter drops +agoraphobias+ / +foxed+ / +sacristies+
               # for the same weak-corpus reason we drop +polys+ / +gollies+ / +gettered+ (whose
               # bases are _not_ in WordNet at all). Junk bases never acquire a WN entry because
               # WN's lexicographic gate is stricter than Wiktionary's.
               base_wn = kaikki_paradigm_base_has_pos_appropriate_wn?(w)
               r = strong_wordfreq || strong_subtlex || wnw || base_wn
               dict_trace_puts(w, "disconnect round=#{rounds}: freq=0 Kaikki-paradigm form of #{$inflection_base_words[w]}: zipf=#{zipf_w} sub=#{sub_w} wn=#{wnw} base_wn=#{base_wn} keep=#{r}") if dict_trace_word?(w)
               r
             elsif in_wordfreq_tsv
               if dict_trace_word?(w)
                 nb ||= numberbatch_headwords_intersecting(dict_set)
                 cn ||= conceptnet_headwords_intersecting(dict_set)
                 nbw = nb.include?(w)
                 cnw = cn.include?(w)
                 wnw = wn_has_entry?(w)
                 dict_trace_puts(w, "disconnect round=#{rounds}: freq=0 wordfreq_row=yes nb=#{nbw} cn=#{cnw} wn=#{wnw} has_rhyme=#{has_rhyme} keep=true (TSV attested; not dropped here)")
               end
               true
             else
               f2b = kaikki_form_rescue_set.include?(w)
               s4 = subtlex_freqlow_positive?(w, subtlex_hash)
               wnw = wn_has_entry?(w)
               surf_r = cmudict_surface_rhyme_rescue?(w, prons, has_rhyme, original_cmudict_headwords)
               r = f2b || s4 || wnw || surf_r
               if dict_trace_word?(w)
                 dict_trace_puts(w, "disconnect round=#{rounds}: freq=0 wordfreq_row=no oov_2b=#{f2b} oov_subtlex=#{s4} wn=#{wnw} cmudict_surface_rhyme=#{surf_r} has_rhyme=#{has_rhyme} keep=#{r} remove=#{!r}")
               end
               r
             end
      next if keep
      dict_trace_puts(w, "filter_disconnected round=#{rounds}: DELETE (freq=0, no rescue)") if dict_trace_word?(w)
      word_dict.delete(w)
      removed += 1
    end
    total_removed += removed
    prune_rdict_to_headwords!(rdict, word_dict.keys)
    delete_rare_only_rime_buckets!(rdict, word_dict)
    delete_common_identical_only_rime_buckets!(rdict, word_dict)
    break if removed == 0 || rounds >= 12
  end
  if total_removed > 0
    puts "#{total_removed} headwords removed (freq==0 disconnect filter)"
  end
  word_dict
end

# True if +word+ is a Kaikki non-lemma form whose +form_of+ base has a POS-appropriate
# WordNet entry: +-ing+/+-ed+ wants a verb base (WN participle paradigm), +-s+/-+es+/+-er+/
# +-est+ wants any WN entry (plurals and comparatives often substantivize adjectives —
# *alpines*, *agoraphobics* — so noun-only gating drops them; the surface's wordfreq floor
# in +compute_frequency+ still guards against truly empty paradigms). Used to shield
# legitimate rare inflections of attested lexemes (*sacristies*, *foxed*, *alpines*,
# *agoraphobics*) while still catching the junk (*polys*, *gollies*, *gettered*, *hocused*,
# *finnaed*, *taserred*, *rizzed* — whose bases are not in WordNet at all).
def kaikki_paradigm_base_has_pos_appropriate_wn?(word)
  base = $inflection_base_words[word]
  return false if base.nil? || base == word
  return false unless wn_has_entry?(base)
  if word.end_with?("ing") || word.end_with?("ed")
    wn_base_has_verb?(base)
  else
    true
  end
end

def compute_frequency(word, subtlex_hash, wordfreq_hash, subtlex_total_hash: nil, kaikki_capitalized_only: nil, pos_map: nil)
  return 0 if morph_spurious_plural_s_on_invariant_noun?(word)

  _, wn_all_proper = wn_frequency(word)
  in_wordnet = wn_has_entry?(word)
  sub_raw = subtlex_hash[word] || 0
  zipf = wordfreq_hash[word] || 0
  syn_n = wn_synset_count(word)

  # Kaikki-documented paradigm form (surface is a form_of some other lemma): do not score off
  # marginal SUBTLEX / sub-rare Zipf. Wiktionary documents the full verb/plural paradigm for
  # obscure senses — jargon, obsolete, regional, noun-coined-to-verb — and the surfaces show
  # up with FREQcount of 1-2 in SUBTLEX (caption noise) or Zipf < 2.0 in wordfreq (single-digit
  # document hits). Example junk: *gollies* (SUBTLEX count=2, Zipf 0), *polys* (SUBTLEX count=1,
  # Zipf 1.71), *bravados* (SUBTLEX 0, NB-only). These should stay freq=0 and be pruned by the
  # disconnect filter unless Kaikki/SUBTLEX morph passes rescue them via strong surface attestation of the form
  # itself. Guard is narrow: only fires when (a) the surface is a Kaikki non-lemma form of a
  # different base, (b) no WordNet anchor on the surface, (c) Zipf below RARE threshold, and
  # (d) SUBTLEX is trickle-level (< SUBTLEX_OVERRIDE_PROPER_MIN). Legit common plurals and
  # inflections all carry strong wordfreq Zipf, WN entries, or high SUBTLEX FREQcount and
  # bypass this gate.
  #
  # Exception: if the Kaikki +form_of+ base has a POS-appropriate WordNet entry (noun for +-s+
  # plural, verb for +-ed+ / +-ing+), leave compute_frequency alone. These are legitimate rare
  # inflections of attested lexemes (+sacristies+ ← +sacristy+, +alpines+ ← +alpine+,
  # +agoraphobics+ ← +agoraphobic+) that must keep their weak-signal frequency so they reach
  # +filter_word_dict_disconnected!+'s base-WN rescue — zeroing them here would orphan them at
  # the disconnect filter instead. Bases for the junk cases (+poly+, +golly+, +bravado+-as-verb,
  # +hocus+, +getter+) have no matching WN entry so this clause does not apply to them.
  if !in_wordnet && zipf < WORDFREQ_RARE_ZIPF &&
      sub_raw < SUBTLEX_OVERRIDE_PROPER_MIN &&
      morph_kaikki_lists_surface_as_inflected_nonlemma?(word) &&
      !kaikki_paradigm_base_has_pos_appropriate_wn?(word)
    dict_trace_puts(word, "compute_frequency: Kaikki form_of paradigm with weak signal (sub=#{sub_raw} zipf=#{zipf}) => 0") if dict_trace_word?(word)
    return 0
  end

  # Short-base Kaikki paradigm plurals (+or+→+ors+, +o+→+os+, +pos+→+poss+, +bo+→+bos+): 1-3
  # char bases whose Wiktionary-documented +-s+ surface inherits web/SUBTLEX noise that looks
  # conversational but is mostly function-word / acronym / abbreviation fragment spam. Zero
  # when the surface has no WN entry of its own and Zipf stays sub-COMMON — legit short-base
  # plurals (+bees+ from +bee+ Zipf 4.86, +toes+ from +toe+) either sit well above COMMON or
  # show up in WN; their Kaikki form remains undisturbed. +poss+ SUBTLEX 7 is all-lowercase
  # tweet slang for +possible+, not a real plural of WN +pos+. Does not apply to +-es+/+-ing+/
  # +-ed+ which have verb paradigms with different noise profiles.
  if !in_wordnet && zipf < WORDFREQ_COMMON_ZIPF &&
      morph_kaikki_lists_surface_as_inflected_nonlemma?(word) &&
      word.end_with?("s")
    base = $inflection_base_words[word]
    if base && base.length <= 3 && base != word &&
        (word == "#{base}s" || word == "#{base}es")
      dict_trace_puts(word, "compute_frequency: Kaikki short-base (#{base}) plural with sub-COMMON Zipf (#{zipf}) => 0") if dict_trace_word?(word)
      return 0
    end
  end

  # Two-letter all-proper: usually chemical/state abbreviations in WordNet (Al, Bi, AL).
  # Multiple synsets → keep 0 (al, ba). Single synset → only trust subtitles below a ceiling
  # so bi can score as dialogue while ni stays 0 despite fragment counts.
  if wn_all_proper && two_letter_alpha?(word)
    return 0 if syn_n >= 2
    return 0 if syn_n == 1 && sub_raw >= SUBTLEX_SINGLE_PROPER_OVERRIDE_MAX
    if syn_n == 1 && sub_raw >= SUBTLEX_SINGLE_PROPER_OVERRIDE_MIN && sub_raw < SUBTLEX_SINGLE_PROPER_OVERRIDE_MAX
      wn_all_proper = false
    elsif syn_n == 1
      return 0
    end
  end

  # Case-based proper-noun gate: without a WordNet anchor, a word that Kaikki only ever records
  # capitalized (Modena, Srebrenica) — or that SUBTLEX records mostly capitalized (Carlin 0/34) — is
  # an encyclopedic/name token. Demote so wordfreq's Wikipedia-driven Zipf and any case-flattened
  # SUBTLEX FREQlow cannot pull it into rare/common.
  case_proper = likely_proper_noun_by_case?(word, subtlex_hash, subtlex_total_hash, kaikki_capitalized_only)

  # WordNet synset strings are title-cased; demonyms and many names still appear lowercase in SUBTLEX /
  # wordfreq. All-proper with zero SUBTLEX is encyclopedic-only (high Zipf reflects Wikipedia, not usage).
  # Extend to all-proper + case_proper: tiny FREQlow trickle (Cabot 1/85, Kant, Lawton) is still
  # encyclopedic even though the lowercase count is non-zero.
  return 0 if wn_all_proper && (sub_raw.zero? || case_proper)

  # All-proper + single-synset + trickle SUBTLEX FREQlow (< 5) in +noun.animal+ / +noun.plant+
  # captures Latin scientific binomials (+pseudomonas+ bacterial genus, lexed +noun.animal+)
  # whose 4-word dialogue trickle keeps them just above the +case_proper+ bar (sub_low ≤ 2).
  # Restricted to biology lex categories to avoid +cajun+ (noun.person demonym with the same
  # syn=1 + all_proper + sub=3 signal). Demonyms stay commmon through this gate.
  if wn_all_proper && syn_n == 1 && sub_raw > 0 && sub_raw < 5
    lexnames = wn_noun_synsets_unified(word).map { |s| wn_synset_noun_lexname(s) }.compact
    if lexnames.any? { |ln| WN_ALL_PROPER_BIOLOGY_LEXNAMES.include?(ln) }
      return 0
    end
  end

  # Without any WordNet anchor we can tolerate a higher FREQlow band for the proper-noun gate
  # (names with dialogue trickle: shi 12, strom 5, mong 3) because we're not risking common-noun
  # senses (pentagon / chicago / easter are in WordNet and go through the strict path above).
  case_proper_oov = likely_proper_noun_by_case?(word, subtlex_hash, subtlex_total_hash,
                                                 kaikki_capitalized_only,
                                                 max_low: SUBTLEX_OVERRIDE_PROPER_MIN)
  return 0 if case_proper_oov && !in_wordnet

  # e.g. atm: WordNet lemma + high Zipf but almost no lowercase subtitle hits — encyclopedic initialism.
  weak_lexical_anchor = short_initialism_shape?(word) && in_wordnet && sub_raw < SUBTLEX_OVERRIDE_PROPER_MIN && zipf >= WORDFREQ_COMMON_ZIPF

  lexically_anchored = in_wordnet && !weak_lexical_anchor

  subtlex_freq = subtlex_frequency(word, subtlex_hash)
  # Low wordfreq Zipf with strong SUBTLEX is often a real headword in subtitles but rare in wordfreq's web mix.
  # Applies to OOV (no WordNet anchor) AND to WN-anchored obscure English where dialogue trickle
  # inflates SUBTLEX_PRESENCE_BONUS past rare (paregoric 1.26, pellagra 1.85, cohosh 1.56,
  # scrod 1.16, soubrette 1.43, breadline 1.76, pukka 1.91). These are genuine WN lemmas but
  # medical/archaic/foreign terms the test treats as forbidden. Loss on borderline commons like
  # entomb/moralize/skulduggery (≈10 _ish/common rows) is outweighed by the 25+ common→forbidden
  # corrections this unlocks.
  if zipf > 0 && zipf < WORDFREQ_RARE_ZIPF && subtlex_freq > RARE_FREQ_MAX
    subtlex_freq = RARE_FREQ_MAX
  end

  # Case-based proper-noun homographs with a WN non-proper anchor (brant waterfowl ≈ mostly the
  # Brant surname): clamp SUBTLEX FREQlow trickle to rare so the homograph doesn't register as
  # common off a few lowercase subtitle hits. Use the lax FREQlow band (≤ 12) only when the
  # anchor is NOT all-proper — pentagon / chicago / easter (all-proper=true elsewhere excluded;
  # pentagon all-proper=false but zipf≥COMMON keeps wordfreq_boost 5, masking the clamp).
  if (case_proper || (case_proper_oov && in_wordnet && !wn_all_proper)) && subtlex_freq > RARE_FREQ_MAX
    subtlex_freq = RARE_FREQ_MAX
  end

  # Without a lexical anchor, high Zipf often reflects encyclopedic/person-name hits; do not let
  # SUBTLEX alone push past the rare threshold (e.g. nam ~ Viet Nam fragments in subtitles).
  if !lexically_anchored && zipf >= WORDFREQ_COMMON_ZIPF
    # 2–3-letter OOV with sustained SUBTLEX FREQlow that Kaikki tags as interjection (+yum+, +duh+,
    # +nah+, +meh+, +hmm+, +ugh+, +wow+) is real dialogue, not an initialism artifact. Prior version
    # used +sub_raw >= SUBTLEX_OVERRIDE_PROPER_MIN+ alone which also let through encyclopedic /
    # caption-fragment shapes (+bom+, +hee+, +ing+, +hor+, +oe+) whose SUBTLEX trickle is noise.
    intj_anchor = pos_map && Array(pos_map[word]).include?("intj")
    unless short_initialism_shape?(word) && intj_anchor
      subtlex_freq = [subtlex_freq, RARE_FREQ_MAX].min
    end
  end

  block_short_initialism_wordfreq = acronym_shape_wordfreq_only?(word) && subtlex_freq == 0 && !in_wordnet
  wordfreq_boost = (zipf >= WORDFREQ_COMMON_ZIPF && !block_short_initialism_wordfreq) ? 5 : 0

  # Zipf-only boost with no anchor and zero SUBTLEX FREQlow: usually Wikipedia names (graeme, platt).
  if !lexically_anchored && sub_raw == 0
    wordfreq_boost = 0
  end

  # Case-based proper-noun signal: wordfreq Zipf is Wikipedia-heavy for names — do not let it lift
  # an otherwise-capitalized word into common.
  if case_proper
    wordfreq_boost = 0
  end

  # Short initialism-shaped strings with high Zipf but no anchor: treat Zipf as noisy.
  if !lexically_anchored && short_initialism_shape?(word) && zipf >= WORDFREQ_COMMON_ZIPF
    wordfreq_boost = 0
  end

  # No WordNet lemma: tiny SUBTLEX FREQlow counts are often surname fragments or one-off lines — do not pair
  # them with a strong Zipf score into a common bin (*anders*). Always drop Zipf boost here; only clamp
  # SUBTLEX when Zipf is strong (encyclopedic web) or zero (*yegg*), so dialogue-backed OOV headwords
  # with mid Zipf (*flyby*, *getter*) can exceed the rare ceiling from SUBTLEX alone. Inflections of WN
  # lemmas (*successors*) skip the clamp when Zipf is strong so they are not stuck at rare with a WN base.
  #
  # R2b: Kaikki noun-attested bypass — OOV lemmas Kaikki tags as +noun+ (and not capitalized-only)
  # with Zipf in the modern [COMMON, OOV_STRONG_MODERN) band represent productive neologism nouns
  # (*biopic*, *meetup*) rather than surname trickle. Skip the clamp so SUBTLEX + wordfreq lift
  # them out of rare. Capitalized-only Kaikki entries (proper nouns) still fall through to the
  # standard OOV clamp.
  kaikki_common_noun_oov = pos_map && Array(pos_map[word]).include?("noun") &&
    !(kaikki_capitalized_only && kaikki_capitalized_only.include?(word))
  if !in_wordnet && sub_raw.positive? && sub_raw < SUBTLEX_OVERRIDE_PROPER_MIN &&
      !(kaikki_common_noun_oov && zipf >= WORDFREQ_COMMON_ZIPF && zipf < WORDFREQ_OOV_STRONG_MODERN_ZIPF)
    strong_modern = zipf >= WORDFREQ_OOV_STRONG_MODERN_ZIPF
    wordfreq_boost = 0 unless strong_modern && zipf >= WORDFREQ_COMMON_ZIPF
    if (zipf >= WORDFREQ_COMMON_ZIPF || zipf.zero?) && !strong_modern && !wn_oov_subtlex_cap_skip_via_inflection_anchor?(word)
      subtlex_freq = [subtlex_freq, RARE_FREQ_MAX].min
    end
  end

  # OOV with Kaikki tagging the word exclusively as a function-word POS (pron / particle /
  # det / conj / prep / num) is nonstandard (+hisself+, +theirselves+) or foreign closed-class
  # (+raison+… unattested, +hor+ particle). Genuine common function words (+of+, +his+,
  # +yours+) are stop words that bypass compute_frequency entirely, so clamping here is safe.
  if !in_wordnet && pos_map && (tags = pos_map[word]) && !tags.empty? &&
      tags.all? { |t| OOV_FUNCTION_WORD_POS_TAGS.include?(t) }
    subtlex_freq = [subtlex_freq, RARE_FREQ_MAX].min
    wordfreq_boost = [wordfreq_boost, RARE_FREQ_MAX].min
  end

  # 2–3 char OOV tokens with mid Zipf (in [2.0, COMMON)) and trickle SUBTLEX FREQlow (< 5)
  # are caption-fragment noise or foreign letter-name residue (+oe+, +hor+, +ae+). Different
  # band from the earlier short-initialism Zipf≥COMMON clamp at line ~371. Real dialogue
  # interjections (+yum+, +wow+, +huh+) have either Kaikki +intj+ anchoring or SUBTLEX FREQlow
  # ≥ 12, so they don't fall into the low-sub cell.
  if !in_wordnet && word.length <= 3 && word.match?(/\A[a-z]+\z/) &&
      sub_raw > 0 && sub_raw < 5 && zipf > 0 && zipf < WORDFREQ_COMMON_ZIPF
    subtlex_freq = [subtlex_freq, RARE_FREQ_MAX].min
    wordfreq_boost = [wordfreq_boost, RARE_FREQ_MAX].min
  end

  # Obscure single-synset WN nouns in highly specialized lex categories (+noun.plant+ Latin
  # binomial-style anatomy, +noun.quantity+ foreign numeral units, +noun.group+ gens / clan
  # tokens) are genuine WN lemmas but encyclopedic rather than conversational. When SUBTLEX
  # FREQlow < 5 they lack the dialogue signature of everyday noun.plant commons (+tulip+,
  # +orchid+) and noun.group commons (+posse+, +linemen+), so clamp the computed freq to
  # rare. Catches +anther+, +gens+, +lakh+ while leaving +pseudomonas+ (noun.animal, conflicts
  # with +tapir+ / +axolotl+ / +puffin+) and +mem+ (noun.communication, conflicts with
  # +skulduggery+ / +malware+) to other gates.
  if in_wordnet && syn_n == 1 && zipf > 0 && zipf < WORDFREQ_COMMON_ZIPF + 0.5 && sub_raw < 5
    lexnames = wn_noun_synsets_unified(word).map { |s| wn_synset_noun_lexname(s) }.compact
    if lexnames.any? { |ln| WN_ENCYCLOPEDIC_SINGLE_SYNSET_LEXNAMES.include?(ln) }
      subtlex_freq = [subtlex_freq, RARE_FREQ_MAX].min
      wordfreq_boost = [wordfreq_boost, RARE_FREQ_MAX].min
    end
  end

  freq = [subtlex_freq, wordfreq_boost].max

  # R5a + R1: Multi-synset WN-anchored lemmas represent established English with multiple
  # senses. The default pipeline leaves them at freq ≤ RARE when SUBTLEX is absent / clamped
  # and Zipf hasn't crossed the common boost threshold (*append* 0-sub Zipf 2.64 → freq 0;
  # *moralize* Zipf 1.74 → freq 4 via SUBTLEX-clamp). Floor these to just-common
  # (+RARE_FREQ_MAX+1+) so the WN anchor carries weight independent of +sub_raw+. Single-synset
  # lemmas stay at the cautious default (earlier demotions already caught encyclopedic cases
  # like +cohosh+, +paregoric+). Exclude +wn_all_proper+ (proper-noun senses only).
  #
  # Zipf ≥ RARE is the default threshold. Highly multi-sense lemmas (+syn_n ≥ 3+) with any
  # SUBTLEX presence (+sub_raw > 0+) also qualify below RARE — catches *moralize* (3 syn,
  # Zipf 1.74, sub 4) and *entomb*/*arachnophobia* stay at the cautious floor.
  if in_wordnet && lexically_anchored && !wn_all_proper && syn_n >= 2 && freq <= RARE_FREQ_MAX &&
      (zipf >= WORDFREQ_RARE_ZIPF || (syn_n >= 3 && sub_raw > 0))
    freq = RARE_FREQ_MAX + 1
  end

  dict_trace_puts(word, "compute_frequency: subtlex=#{subtlex_freq} zipf=#{zipf} in_wn=#{in_wordnet} lexical_anchor=#{lexically_anchored} wordfreq_boost=#{wordfreq_boost} (needs zipf≥#{WORDFREQ_COMMON_ZIPF} for boost) block_short_init=#{block_short_initialism_wordfreq} all_proper=#{wn_all_proper} => #{freq}") if dict_trace_word?(word)
  return freq
end

# List-pivot Inflect inheritance: try to lift +word+ to donor freq via +listed+
# (rarity.csv: common/common_ish), forward or reverse Inflect match.
def morph_inherit_listed_once!(word, listed, forward, hash, rare_words, common_words, pos_map, forms_map, kaikki_verb_morph, subtlex_hash, wordfreq_hash, cmudict_orig, ref_cn, ref_nb, ref_usf, neol_words)
  entry = hash[word]
  return false unless entry
  return false if entry[0] > RARE_FREQ_MAX
  return false if rare_words.include?(word)
  return false if listed == word

  if forward
    return false unless Inflect.inflection_of_base?(listed, word)
    base = listed
    infl = word
    inflect_stem = listed
  else
    return false unless Inflect.inflection_of_base?(word, listed)
    base = word
    infl = listed
    inflect_stem = word
  end

  if morph_kaikki_lists_surface_as_inflected_nonlemma?(inflect_stem)
    tr = dict_trace_morph_inherit_listed?(word, listed, base, infl)
    dict_trace_puts(word, "morph_inherit_listed listed=#{listed}: skip (Kaikki lists #{inflect_stem} as form of #{$inflection_base_words[inflect_stem]})") if tr
    return false
  end

  tr = dict_trace_morph_inherit_listed?(word, listed, base, infl)
  inflection_suffix_kind = Inflect.send(:match_suffix_kind, base, infl)
  if inflection_suffix_kind.nil?
    dict_trace_puts(word, "morph_inherit_listed listed=#{listed} base=#{base} infl=#{infl}: skip (no suffix kind)") if tr
    return false
  end
  wf_infl = wordfreq_hash[infl] || 0
  if inflection_suffix_kind == :s && !morph_base_allows_plural_s?(base, pos_map, forms_map, infl, wordfreq_hash: wordfreq_hash, subtlex_hash: subtlex_hash)
    dict_trace_puts(infl, "morph_inherit_listed ← #{base} (listed=#{listed}): skip (plural :s not allowed)") if tr
    return false
  end
  if (inflection_suffix_kind == :ed || inflection_suffix_kind == :ing) && base.end_with?("ing")
    dict_trace_puts(infl, "morph_inherit_listed ← #{base} (listed=#{listed}): skip (#{inflection_suffix_kind} on -ing base)") if tr
    return false
  end
  list_auth = common_words.include?(base)
  if (inflection_suffix_kind == :ed || inflection_suffix_kind == :ing) && !morph_base_allows_verb_forms?(base, infl, pos_map, forms_map, wf_infl, wordfreq_hash, list_authoritative_base: list_auth, kaikki_verb_morph: kaikki_verb_morph)
    dict_trace_puts(infl, "morph_inherit_listed ← #{base} (listed=#{listed}): skip (verb forms blocked; suffix=#{inflection_suffix_kind} list_auth=#{list_auth} zipf=#{wf_infl})") if tr
    return false
  end
  if inflection_suffix_kind == :er || inflection_suffix_kind == :est
    base_p0 = hash[base]&.dig(1)&.first
    unless morph_base_allows_comparative_er_est?(base, infl, pos_map, base_p0, forms_map, wf_infl)
      dict_trace_puts(infl, "morph_inherit_listed ← #{base}: skip (:er/:est not allowed)") if tr
      return false
    end
  end
  listed_freq = hash.key?(listed) ? hash[listed][0] : 0
  donor = listed_freq > RARE_FREQ_MAX ? listed_freq : 99
  if donor > RARE_FREQ_MAX && !common_words.include?(listed) && !neol_words.include?(base) && !neol_words.include?(listed) && !inflection_surface_reference_attested?(word, subtlex_hash, wordfreq_hash, cmudict_orig, ref_cn, ref_nb, ref_usf, neol_words: neol_words)
    dict_trace_puts(word, "morph_inherit_listed ← base=#{base} (listed=#{listed}): skip (surface not in wordfreq/SUBTLEX/WN/CMU/USF/CN/NB/neol)") if tr
    return false
  end
  entry[0] = donor
  # +donor_anchored+ uses the corpus-only predicate (no +common_words+ clause)
  # so the +received_donor_from_common_base_flag+ feature can't read the
  # curated label off its own input. See +donor_has_corpus_anchor?+ in dict.rb.
  record_freq_propagation!(word, phase: :morph_inherit_listed, donor: base, donor_anchored: donor_has_corpus_anchor?(base, wordfreq_hash, neol_words))
  dict_trace_puts(word, "morph_inherit_listed: set freq=#{donor} via listed=#{listed} base=#{base} infl=#{infl} suffix=#{inflection_suffix_kind}") if tr
  true
end

def add_frequency_info(cmudict, subtlex_hash, subtlex_total_hash, wordfreq_hash, wiktionary_words, pos_map, forms_map, kaikki_verb_morph = nil, original_cmudict_headwords = nil, kaikki_capitalized_only = nil)
  $freq_propagation_metadata = {}
  count = 0
  hash = Hash.new
  rare_words = rarity_csv_rare_words
  common_words = rarity_csv_common_words
  cmudict_orig = original_cmudict_headwords || Set.new
  ref_cn = conceptnet_lemma_vocab_for_attestation
  ref_nb_path = numberbatch_txt_path
  ref_nb = ref_nb_path ? numberbatch_corpus_token_set(ref_nb_path) : nil
  ref_usf = usf_corpus_word_set
  for word, prons in cmudict
    if(semantically_promiscuous?(word))
      freq = 999999
    elsif(common_words.include?(word))
      freq = 99
    elsif(rare_words.include?(word))
      freq = 0
    else
      freq = compute_frequency(word, subtlex_hash, wordfreq_hash, subtlex_total_hash: subtlex_total_hash, kaikki_capitalized_only: kaikki_capitalized_only, pos_map: pos_map)
    end
    if(freq > 0)
      count += 1
    end
    hash[word] = [freq, prons]
    dict_trace_puts(word, "cmudict_seed: freq=#{freq}") if dict_trace_word?(word)
  end
  puts "#{count} of those entries have frequency data (from cmudict/wiktionary words)"

  # SUBTLEX expansion: add words from SUBTLEX that aren't in cmudict.
  extra = 0
  subtlex_hash.each_key do |word|
    next if hash.key?(word)
    next unless word.match?(/\A[a-z]([a-z'\-]*[a-z])?\z/)
    if(semantically_promiscuous?(word))
      freq = 999999
    elsif(common_words.include?(word))
      freq = 99
    elsif(rare_words.include?(word))
      freq = 0
    else
      freq = compute_frequency(word, subtlex_hash, wordfreq_hash, subtlex_total_hash: subtlex_total_hash, kaikki_capitalized_only: kaikki_capitalized_only, pos_map: pos_map)
    end
    if freq > 0
      hash[word] = [freq, []]
      extra += 1
    end
  end
  puts "#{extra} extra words added from SUBTLEX"

  # Common-list floor: add (or sentinel-floor) words tagged common/common_ish in
  # +curated/rarity.csv+. Freq 99 is a structural sentinel: it lands above
  # +RARITY_CLASSIFIER_RESCORE_MAX_FREQ+ so the rarity-classifier rescore pass won't
  # delete these curated headwords as forbidden. Pre-existing entries at or below
  # +RARE_FREQ_MAX+ get bumped (otherwise a word like +mitten+ — legit but sparse in
  # SUBTLEX — can be floored at freq 4 and then nuked by the classifier).
  common_extra = 0
  common_bumped = 0
  common_words.each do |word|
    if hash.key?(word)
      next if hash[word][0] > RARE_FREQ_MAX
      hash[word][0] = 99
      common_bumped += 1
    else
      hash[word] = [99, []]
      puts "  Added #{word} to the dictionary with frequency 99"
      common_extra += 1
    end
  end
  puts "#{common_extra} extra words added from rarity.csv (common/common_ish)" if common_extra > 0
  puts "#{common_bumped} existing rare-band headwords floored by rarity.csv (common/common_ish)" if common_bumped > 0

  # Neol promotion: modern neologisms from neol2016 (12dicts) + supplement.
  # Neither list is a complete inventory of inflections, so the union serves as attestation
  # for the downstream morph inheritance / expansion passes (e.g. +yeeted+ from +yeet+).
  neol_words = load_word_list_set(NEOL2016_FILENAME)
  neol_words.merge(load_word_list_set(NEOL_SUPPLEMENT_FILENAME))
  neol_promoted = 0
  neol_words.each do |word|
    if hash.key?(word)
      next if hash[word][0] > RARE_FREQ_MAX
      hash[word][0] = 98
    else
      hash[word] = [98, []]
    end
    neol_promoted += 1
  end
  puts "#{neol_promoted} words promoted/added from neol2016 + supplement" if neol_promoted > 0

  # Wiktionary existence floor for modern words absent from all traditional corpora, e.g. throuple, yeet.
  # Require Zipf >= RARE to avoid junk words
  floor_applied = 0
  hash.each do |word, entry|
    next if entry[0] > RARE_FREQ_MAX
    next if rare_words.include?(word)
    next unless wiktionary_words.include?(word)
    zipf = wordfreq_hash[word] || 0
    next unless zipf >= WORDFREQ_RARE_ZIPF
    next if subtlex_hash[word] > 0
    next if wn_has_entry?(word)
    # Four-letter Wiktionary junk: Zipf in [RARE, 2.5) with no WN/SUBTLEX — surnames (~stam);
    # at/above 2.5 keep the floor for neologisms (yeet).
    next if four_letter_alpha?(word) && zipf >= WORDFREQ_RARE_ZIPF && zipf < WIKT_FLOOR_4L_WEAK_ZIPF_BELOW
    # Longer OOV headwords: require evidence beyond Wiktionary lemma + mid Zipf, else Wikipedia /
    # encyclopedic strings flood the floor (abbasi 2.28, modena 2.56, hilal 2.63, ozzie 2.81,
    # sault 2.65, srebrenica 2.44). Admit the floor when *any* of: SUBTLEX dialogue attestation
    # (FREQlow > 0, which catches biopic 2/3.03, chocolatey 9/2.26), modern-neologism list
    # membership (twerk 0/2.54, throuple 0/1.31), or Zipf ≥ COMMON (jpeg 3.04, selfie 3.75,
    # lgbtq 3.41). Retains the prior very-low-Zipf gate too.
    next if !wn_has_entry?(word) && word.match?(/\A[a-z]{5,}\z/) && zipf < WIKT_FLOOR_LONG_OOV_MIN_ZIPF
    next if !wn_has_entry?(word) && word.match?(/\A[a-z]{5,}\z/) &&
            subtlex_hash[word] <= 0 &&
            !neol_words.include?(word) &&
            zipf < WORDFREQ_COMMON_ZIPF
    next if short_initialism_shape?(word) && subtlex_hash[word] <= 0
    # 2-4 letter strings with strong wordfreq but no lexical anchor: skip floor so
    # IMAX/DVD-style tokens stay rare; Zipf < 3 keeps yeet
    next if acronym_shape_wordfreq_only?(word) && subtlex_hash[word] <= 0 && !wn_has_entry?(word) && zipf >= WORDFREQ_COMMON_ZIPF
    # Case-based proper-noun gate: Kaikki capitalized-only (abbasi, batavia, modena, srebrenica)
    # or SUBTLEX mostly-capitalized (carling) should not receive the existence floor — their
    # Wiktionary presence is encyclopedic, not evidence of common-noun usage.
    next if likely_proper_noun_by_case?(word, subtlex_hash, subtlex_total_hash, kaikki_capitalized_only)
    entry[0] = 5
    floor_applied += 1
  end
  puts "#{floor_applied} words received Wiktionary existence floor" if floor_applied > 0

  # Hyphenated existence floor (DISABLED): it promoted many proper names / junk; hyphenated
  # headwords now rely on compute_frequency, the Wiktionary existence floor, and the later
  # morph inheritance / expansion passes only.

  # Kaikki morph inheritance: frequency inheritance for inflected forms.
  # Inherit from any common base word. Skip only when wordfreq shows the inflection itself
  # as independently common (Zipf >= COMMON); a mere corpus key with low Zipf still inherits
  # (yeeted, twerks) so slang bases propagate.
  # Skip -ing → base when WordNet has the base but only as noun/adj/etc.: prevents
  # spurious "kitchening" inheriting from "kitchen" (FP-4). Verbal -ing still inherits
  # when the base has a verb lemma, or when the base is absent from WordNet (slang).
  #
  # Promote Kaikki-linked inflections stuck at 1..RARE_FREQ_MAX (compute_frequency rare ceiling), not only
  # freq==0 — otherwise *blogs* / *blogging* stay rare while *blog* is common.
  inherited = 0
  $inflection_base_words.each do |inflected, base|
    tr = dict_trace_morph?(base, inflected)
    unless hash.key?(inflected)
      dict_trace_puts(inflected, "morph_inherit_kaikki ← #{base}: skip (not in hash)") if tr
      next
    end
    if rare_words.include?(inflected)
      dict_trace_puts(inflected, "morph_inherit_kaikki ← #{base}: skip (in rarity.csv: rare)") if tr
      next
    end
    infl_freq = hash[inflected][0]
    if infl_freq > RARE_FREQ_MAX
      dict_trace_puts(inflected, "morph_inherit_kaikki ← #{base}: skip (freq #{infl_freq} already > #{RARE_FREQ_MAX})") if tr
      next
    end
    # Respect the specialized-lex demotion applied by +compute_frequency+ (+gens+ syn=1
    # noun.group, +anthers+ syn=1 noun.plant). Without this guard, Kaikki morph inheritance
    # re-promotes +gens+ off its base +gen+ (freq≥common), undoing the Option 2 clamp.
    if wn_encyclopedic_single_synset_demoted?(inflected, subtlex_hash, wordfreq_hash)
      dict_trace_puts(inflected, "morph_inherit_kaikki ← #{base}: skip (WN single-synset specialized-lex demotion)") if tr
      next
    end
    # Do not copy frequency from hyphenated base to hyphenated inflection (hoity-toity → hoity-toities).
    if inflected.include?("-") && base.include?("-")
      dict_trace_puts(inflected, "morph_inherit_kaikki ← #{base}: skip (hyphenated base↔inflection)") if tr
      next
    end
    base_freq = hash.key?(base) ? hash[base][0] : 0
    if base_freq >= 999999
      dict_trace_puts(inflected, "morph_inherit_kaikki ← #{base}: skip (stop word donor)") if tr
      next
    end
    if base_freq <= RARE_FREQ_MAX
      dict_trace_puts(inflected, "morph_inherit_kaikki ← #{base}: skip (base_freq=#{base_freq} ≤ #{RARE_FREQ_MAX})") if tr
      next
    end
    if infl_freq >= base_freq
      dict_trace_puts(inflected, "morph_inherit_kaikki ← #{base}: skip (infl_freq=#{infl_freq} ≥ base_freq=#{base_freq})") if tr
      next
    end
    wf_inf = wordfreq_hash[inflected]
    # High Zipf can still be freq≤RARE after OOV SUBTLEX clamps (*blogging*); only skip when already common.
    if wf_inf && wf_inf >= WORDFREQ_COMMON_ZIPF && infl_freq > RARE_FREQ_MAX
      dict_trace_puts(inflected, "morph_inherit_kaikki ← #{base}: skip (Zipf #{wf_inf} ≥ #{WORDFREQ_COMMON_ZIPF} and infl already common)") if tr
      next
    end
    inflection_suffix_kind = Inflect.send(:match_suffix_kind, base, inflected)
    # Kaikki forms_map sometimes links archaic / dialectal / mock-Latinate surfaces to a modern
    # lemma with no regular-English suffix relationship (*house*→*hice*, *os*→*ossa*, *dye*→*dyce*,
    # *glide*→*glid*). When Inflect can't identify a suffix kind, require a WordNet entry for the
    # surface or Zipf ≥ COMMON before letting it inherit donor frequency. A sub-COMMON Zipf is a
    # Wikipedia / Common Crawl tail signal that typically reflects Wiktionary paradigm echo rather
    # than running-text usage. Legitimate irregular inflections (*bought* Zipf 4.92, *knew* 5.21,
    # *children* 5.04, *feet* 4.74, *teeth* 4.02, *mice* 3.89) all sit well above COMMON.
    if inflection_suffix_kind.nil?
      sub_raw_inf = subtlex_hash[inflected] || 0
      wf_raw_inf = (wordfreq_hash[inflected] || 0).to_f
      wn_inf = wn_has_entry?(inflected)
      unless wn_inf || wf_raw_inf >= WORDFREQ_COMMON_ZIPF || sub_raw_inf >= SUBTLEX_OVERRIDE_PROPER_MIN
        dict_trace_puts(inflected, "morph_inherit_kaikki ← #{base}: skip (Kaikki irregular form, wf=#{wf_raw_inf} sub=#{sub_raw_inf} no WN)") if tr
        next
      end
    end
    if inflection_suffix_kind == :s && !morph_base_allows_plural_s?(base, pos_map, forms_map, inflected, wordfreq_hash: wordfreq_hash, subtlex_hash: subtlex_hash)
      dict_trace_puts(inflected, "morph_inherit_kaikki ← #{base}: skip (plural :s not allowed)") if tr
      next
    end
    # Non-standard consonant+y plurals: English pluralizes +lady+→+ladies+, +teddy+→+teddies+,
    # +eddy+→+eddies+. Kaikki sometimes documents the dialectal +-ys+ surface (*teddys*, *eddys*,
    # *gettys*) as an "alternative form of" the lemma; these inherit donor frequency from the
    # common base. The -ies surface is the preferred/canonical inflection in CMUdict/wordfreq, so
    # the -ys form adds noise. Skip unless the -ys surface has its own Zipf ≥ RARE or WN entry
    # (+boys+/+guys+ are not cons+y, so they do not match this pattern).
    if inflection_suffix_kind == :s && base.length >= 2 &&
        base.end_with?("y") && !%w[a e i o u y].include?(base[-2]) &&
        inflected == "#{base}s"
      wf_raw_inf = (wordfreq_hash[inflected] || 0).to_f
      unless wn_has_entry?(inflected) || wf_raw_inf >= WORDFREQ_RARE_ZIPF
        dict_trace_puts(inflected, "morph_inherit_kaikki ← #{base}: skip (nonstandard cons+ys plural; standard is -ies)") if tr
        next
      end
    end
    zf_w = wordfreq_hash[inflected] || 0
    if (inflection_suffix_kind == :ed || inflection_suffix_kind == :ing) && !morph_base_allows_verb_forms?(base, inflected, pos_map, forms_map, zf_w, wordfreq_hash, kaikki_verb_morph: kaikki_verb_morph)
      dict_trace_puts(inflected, "morph_inherit_kaikki ← #{base}: skip (verb forms blocked; suffix=#{inflection_suffix_kind} zipf_inf=#{zf_w})") if tr
      next
    end
    if inflection_suffix_kind == :er || inflection_suffix_kind == :est
      base_p0 = hash[base]&.dig(1)&.first
      unless morph_base_allows_comparative_er_est?(base, inflected, pos_map, base_p0, forms_map, zf_w)
        dict_trace_puts(inflected, "morph_inherit_kaikki ← #{base}: skip (:er/:est not allowed)") if tr
        next
      end
    end
    # Surface attestation: require real corpus evidence for the inflected form when the base
    # lacks a "common" anchor (neither common_words nor wordfreq Zipf ≥ COMMON). Stronger than
    # "any SUBTLEX trickle / Numberbatch vector" because Wiktionary documents full paradigms
    # for obscure verbal / plural senses (*getter* physics jargon, *bravado* obsolete swagger-
    # verb, *golly* Australian spit-verb, *poly* fantasy polymorph-verb, *hocus* obsolete) whose
    # surfaces show up in SUBTLEX with FREQcount of 1-2 or as a Numberbatch vector but never in
    # running text. Require wordfreq presence, WN entry, original CMUdict, or neol membership of
    # the inflected form itself. neol-only on the _base_ (rizz → rizzed) does not license OOV
    # inflections; real neol inflections (*yeeted*, *twerked*) show up in wordfreq at low Zipf.
    # Bases whose own Zipf ≥ WORDFREQ_COMMON_ZIPF (sacristy 3.36, agoraphobic 3.13, alpine 3.79,
    # foxy 3.61) remain authoritative and skip this gate so their Kaikki-documented rare
    # inflections (*sacristies*, *agoraphobics*, *alpines*, *foxier*) still receive donor
    # frequency via the usual propagation.
    base_zipf = wordfreq_hash[base] || 0
    surf_ok = wordfreq_hash.key?(inflected) ||
      wn_has_entry?(inflected) ||
      cmudict_orig.include?(inflected) ||
      neol_words.include?(inflected)
    # +base_has_corpus_anchor+ is the inheritance-gate's anchor predicate
    # MINUS the +common_words.include?(base)+ clause: real corpus / lexical
    # evidence only (WordNet entry, neol membership, or Zipf ≥
    # +WORDFREQ_COMMON_ZIPF+). +base_has_real_anchor+ adds curated commons
    # back in for the gate so curated-list-only words still license their
    # Kaikki-linked inflections (the curators' authoritative call). Only the
    # corpus-anchor flavor flows into +donor_anchored+ metadata, because
    # otherwise the rarity-classifier feature
    # +received_donor_from_common_base_flag+ leaks the curated-list label
    # via inflection — every inflected form of a +common+ row in
    # +curated/rarity.csv+ ends up with the flag set, which is
    # indistinguishable from "this word's lemma is labeled common in
    # rarity.csv" — exactly the leak we just spent items 1–3 plugging.
    base_has_corpus_anchor = wn_has_entry?(base) ||
      neol_words.include?(base) ||
      base_zipf >= WORDFREQ_COMMON_ZIPF
    base_has_real_anchor = base_has_corpus_anchor || common_words.include?(base)
    if base_freq > RARE_FREQ_MAX && !base_has_real_anchor && !surf_ok
      dict_trace_puts(inflected, "morph_inherit_kaikki ← #{base}: skip (base not in common_words/WN/neol, Zipf #{base_zipf} < COMMON, surface not in wordfreq/WN/CMU/neol)") if tr
      next
    end
    hash[inflected][0] = base_freq
    record_freq_propagation!(inflected, phase: :morph_inherit_kaikki, donor: base, donor_anchored: base_has_corpus_anchor)
    dict_trace_puts(inflected, "morph_inherit_kaikki ← #{base}: inherited freq=#{base_freq} suffix=#{inflection_suffix_kind} corpus_anchored=#{base_has_corpus_anchor} (real_anchor=#{base_has_real_anchor})") if tr
    inherited += 1
  end
  puts "#{inherited} inflected forms inherited frequency from base words" if inherited > 0

  # List-pivot Inflect inheritance: suffix inheritance from rarity.csv common rows (Inflect
  # spelling patterns). Kaikki morph inheritance lifts Kaikki-linked inflections through
  # the rare bins; this pass still handles list-driven cases. Match forward (listed +
  # suffix = word) or reverse (word + suffix = listed, e.g. regionalize… ← regionalized).
  # Structural junk guards only; list headwords skip Kaikki verb attestation (see
  # +list_authoritative_base+ on +morph_base_allows_verb_forms?+). When +listed+ is in
  # rarity.csv (common), also skip +inflection_surface_reference_attested?+ so curated lemmas
  # can lift OOV inflections.
  cw_sorted = common_words.sort_by { |b| -b.length }
  cw_inherited = 0
  # Multiple rounds: e.g. regionalized → regionalize → regionalizing in one build.
  # Iterate common_words × small candidate sets (derivations / inverse stems) instead of hash × common_words.
  loop do
    round = 0
    claimed = {}
    cw_sorted.each do |listed|
      Inflect.each_derivable_form(listed) do |w|
        next if w == listed
        next unless hash.key?(w)
        next if claimed[w]
        entry = hash[w]
        if entry[0] > RARE_FREQ_MAX
          dict_trace_puts(w, "morph_inherit_listed: skip row (freq #{entry[0]} already > #{RARE_FREQ_MAX})") if dict_trace_word?(w)
          next
        end
        if rare_words.include?(w)
          dict_trace_puts(w, "morph_inherit_listed: skip row (in rarity.csv: rare)") if dict_trace_word?(w)
          next
        end
        next unless morph_inherit_listed_once!(w, listed, true, hash, rare_words, common_words, pos_map, forms_map, kaikki_verb_morph, subtlex_hash, wordfreq_hash, cmudict_orig, ref_cn, ref_nb, ref_usf, neol_words)
        claimed[w] = true
        round += 1
        cw_inherited += 1
      end

      Inflect.each_candidate_base_for_inflected(listed) do |w|
        next unless hash.key?(w)
        next if claimed[w]
        entry = hash[w]
        if entry[0] > RARE_FREQ_MAX
          dict_trace_puts(w, "morph_inherit_listed: skip row (freq #{entry[0]} already > #{RARE_FREQ_MAX})") if dict_trace_word?(w)
          next
        end
        if rare_words.include?(w)
          dict_trace_puts(w, "morph_inherit_listed: skip row (in rarity.csv: rare)") if dict_trace_word?(w)
          next
        end
        next unless morph_inherit_listed_once!(w, listed, false, hash, rare_words, common_words, pos_map, forms_map, kaikki_verb_morph, subtlex_hash, wordfreq_hash, cmudict_orig, ref_cn, ref_nb, ref_usf, neol_words)
        claimed[w] = true
        round += 1
        cw_inherited += 1
      end
    end
    break if round == 0
  end
  puts "#{cw_inherited} forms inherited frequency from rarity.csv (common) bases" if cw_inherited > 0

  # Common-list Inflect expansion: morphological extensions from rarity.csv common headwords
  # only (Inflect matcher). Unlike an “any freq>RARE_FREQ_MAX lemma” scan, this avoids
  # promoting foxed/gooses/bruisers from ordinary common nouns and avoids hyphenated blast
  # (topsy-turvy → topsy-turvys). OOV rows: list headwords are authoritative (no SUBTLEX/Wikt
  # gate). Existing keys may be raised. -ing from a base requires a WordNet verb lemma (same
  # FP-4 guard as Kaikki morph inheritance).
  morph_inherited = 0
  loop do
    round = 0
    # Snapshot keys so new OOV entries do not disturb this pass; multi-round picks them up as donors.
    hash.keys.each do |base|
      bent = hash[base]
      tb = dict_trace_word?(base)
      unless bent && bent[0] > RARE_FREQ_MAX
        dict_trace_puts(base, "morph_expand_listed: skip (no row or freq #{bent ? bent[0] : 'nil'} ≤ #{RARE_FREQ_MAX})") if tb
        next
      end
      unless common_words.include?(base)
        dict_trace_puts(base, "morph_expand_listed: skip (not in rarity.csv: common)") if tb
        next
      end
      if semantically_promiscuous?(base)
        dict_trace_puts(base, "morph_expand_listed: skip (semantically promiscuous)") if tb
        next
      end
      if rare_words.include?(base)
        dict_trace_puts(base, "morph_expand_listed: skip (in rarity.csv: rare)") if tb
        next
      end
      if base.include?("-")
        dict_trace_puts(base, "morph_expand_listed: skip (hyphenated)") if tb
        next
      end
      if morph_kaikki_lists_surface_as_inflected_nonlemma?(base)
        dict_trace_puts(base, "morph_expand_listed: skip (Kaikki form of #{$inflection_base_words[base]}, not an Inflect stem)") if tb
        next
      end
      donor = bent[0] > RARE_FREQ_MAX ? bent[0] : 99
      base_prons = bent[1]
      Inflect.each_derivable_form(base) do |w|
        tr = dict_trace_morph?(base, w)
        if w == base
          next
        end
        if w.include?("-")
          dict_trace_puts(w, "morph_expand_listed ← #{base}: skip (hyphenated form)") if tr
          next
        end
        if rare_words.include?(w)
          dict_trace_puts(w, "morph_expand_listed ← #{base}: skip (in rarity.csv: rare)") if tr
          next
        end
        unless Inflect.inflection_of_base?(base, w)
          dict_trace_puts(w, "morph_expand_listed ← #{base}: skip (not inflection_of_base?)") if tr
          next
        end
        inflection_suffix_kind = Inflect.send(:match_suffix_kind, base, w)
        wf = wordfreq_hash[w] || 0
        if inflection_suffix_kind == :s && !morph_base_allows_plural_s?(base, pos_map, forms_map, w, wordfreq_hash: wordfreq_hash, subtlex_hash: subtlex_hash)
          dict_trace_puts(w, "morph_expand_listed ← #{base}: skip (plural :s not allowed)") if tr
          next
        end
        if (inflection_suffix_kind == :ed || inflection_suffix_kind == :ing) && base.end_with?("ing")
          dict_trace_puts(w, "morph_expand_listed ← #{base}: skip (#{inflection_suffix_kind} on -ing base)") if tr
          next
        end
        if (inflection_suffix_kind == :ed || inflection_suffix_kind == :ing) && !morph_base_allows_verb_forms?(base, w, pos_map, forms_map, wf, wordfreq_hash, kaikki_verb_morph: kaikki_verb_morph)
          dict_trace_puts(w, "morph_expand_listed ← #{base}: skip (verb forms blocked; suffix=#{inflection_suffix_kind} zipf=#{wf})") if tr
          next
        end
        if inflection_suffix_kind == :er || inflection_suffix_kind == :est
          unless morph_base_allows_comparative_er_est?(base, w, pos_map, base_prons&.first, forms_map, wf)
            dict_trace_puts(w, "morph_expand_listed ← #{base}: skip (:er/:est not allowed)") if tr
            next
          end
        end
        if wf >= WORDFREQ_COMMON_ZIPF
          dict_trace_puts(w, "morph_expand_listed ← #{base}: skip (Zipf #{wf} ≥ #{WORDFREQ_COMMON_ZIPF})") if tr
          next
        end
        # Common-list Inflect expansion scans only rarity.csv (common) bases; list headwords are authoritative (no reference-corpus gate).
        if hash.key?(w)
          if hash[w][0] > RARE_FREQ_MAX
            dict_trace_puts(w, "morph_expand_listed ← #{base}: skip (existing freq #{hash[w][0]} > #{RARE_FREQ_MAX})") if tr
            next
          end
          hash[w][0] = donor
          if hash[w][1].empty?
            promo = morph_derived_prons_for_promotion(base_prons, base, w)
            hash[w][1] = promo unless promo.empty?
          end
          dict_trace_puts(w, "morph_expand_listed ← #{base}: set freq=#{donor} suffix=#{inflection_suffix_kind} (existing row)") if tr
        else
          hash[w] = [donor, morph_derived_prons_for_promotion(base_prons, base, w)]
          dict_trace_puts(w, "morph_expand_listed ← #{base}: new row freq=#{donor} suffix=#{inflection_suffix_kind}") if tr
        end
        # +donor_anchored+ corpus-only — see comment in +morph_inherit_listed+.
        record_freq_propagation!(w, phase: :morph_expand_listed, donor: base, donor_anchored: donor_has_corpus_anchor?(base, wordfreq_hash, neol_words))
        round += 1
        morph_inherited += 1
      end
    end
    break if round == 0
  end
  puts "#{morph_inherited} morphological extensions inherited from freq>#{RARE_FREQ_MAX} bases" if morph_inherited > 0

  # SUBTLEX-anchored Inflect expansion: non-list bases with strong SUBTLEX dialogue use may promote attested inflections.
  # Tighter than old “any freq>RARE_FREQ_MAX”: no hyphen, min length; plural :s can also use a lower SUBTLEX
  # floor when WordNet has the base as noun-only (gramophone → gramophones); blocks gooses-style
  # verbal plurals via wn_base_has_verb?. Non-plural suffixes still require MORPH_CORPUS_SUBTLEX_MIN.
  morph_corpus = 0
  loop do
    round = 0
    hash.keys.each do |base|
      tb = dict_trace_word?(base)
      if common_words.include?(base)
        dict_trace_puts(base, "morph_expand_subtlex: skip (in rarity.csv: common)") if tb
        next
      end
      if base.include?("-")
        dict_trace_puts(base, "morph_expand_subtlex: skip (hyphenated)") if tb
        next
      end
      bent = hash[base]
      unless bent && bent[0] > RARE_FREQ_MAX
        dict_trace_puts(base, "morph_expand_subtlex: skip (no row or freq #{bent ? bent[0] : 'nil'} ≤ #{RARE_FREQ_MAX})") if tb
        next
      end
      if semantically_promiscuous?(base) || rare_words.include?(base)
        dict_trace_puts(base, "morph_expand_subtlex: skip (semantically promiscuous/rare_words)") if tb
        next
      end
      if morph_kaikki_lists_surface_as_inflected_nonlemma?(base)
        dict_trace_puts(base, "morph_expand_subtlex: skip (Kaikki form of #{$inflection_base_words[base]}, not an Inflect stem)") if tb
        next
      end
      base_zipf_pre = (wordfreq_hash[base] || 0).to_f
      if base.bytesize < 5 && base_zipf_pre < WORDFREQ_COMMON_ZIPF
        dict_trace_puts(base, "morph_expand_subtlex: skip (too short; Zipf #{base_zipf_pre} < #{WORDFREQ_COMMON_ZIPF})") if tb
        next
      end
      # Proper-noun bases (SUBTLEX majority capitalized, Kaikki capitalized-only) without any WN
      # common-noun anchor must not drive Inflect derivation. Without this gate, surname CMU
      # headwords (*ferris* with +ferris wheel+-driven Zipf 4.10 but SUBTLEX capitalized 185/209
      # vs lowercase 24) reach SUBTLEX-anchored Inflect expansion and spin up junk plural surfaces (*ferriss* — Inflect's
      # consonant-doubling fallback for unstressed *-is* endings). Real common nouns (+blog+,
      # +twerk+, +gramophone+) have WN noun entries or an almost-entirely-lowercase SUBTLEX
      # profile and skip this gate. The +likely_proper_noun_by_case?+ helper is gated by a very
      # low +max_low+ so we compute the capitalization ratio directly here for high-SUBTLEX-total
      # surname bases where the proper-noun signal is strong but the lowercase trickle (ferris
      # wheel / ferris-wheel idiom) inflates FREQlow above the normal gate.
      unless wn_has_entry?(base) && wn_base_has_noun?(base)
        sub_total_b = (subtlex_total_hash && subtlex_total_hash[base]) || 0
        ratio_b = subtlex_capitalized_ratio(base, subtlex_hash, subtlex_total_hash)
        proper_noun_by_ratio = sub_total_b > 0 && ratio_b && ratio_b >= SUBTLEX_PROPER_NOUN_RATIO_MIN
        kaikki_cap_only = kaikki_capitalized_only && kaikki_capitalized_only.include?(base)
        if proper_noun_by_ratio || kaikki_cap_only
          dict_trace_puts(base, "morph_expand_subtlex: skip (proper-noun base: cap_ratio=#{ratio_b} kaikki_cap_only=#{kaikki_cap_only})") if tb
          next
        end
      end
      sub_raw = subtlex_hash[base] || 0
      # SUBTLEX floor *or* conversational web Zipf (*blog* is dialogue-light in SUBTLEX but Zipf≈4.7).
      # Curated neol bases also qualify so modern lemmas (*doomscroll*) spread to their inflections.
      corpus_ok = sub_raw >= MORPH_CORPUS_SUBTLEX_MIN || base_zipf_pre >= WORDFREQ_COMMON_ZIPF ||
        neol_words.include?(base)
      lexical_plural_ok = wn_has_entry?(base) && !wn_base_has_verb?(base) &&
        sub_raw >= MORPH_LEXICAL_NOUN_PLURAL_SUBTLEX_MIN
      unless corpus_ok || lexical_plural_ok
        dict_trace_puts(base, "morph_expand_subtlex: skip (sub_raw=#{sub_raw}; zipf=#{base_zipf_pre}; corpus_ok=#{corpus_ok} lexical_plural_ok=#{lexical_plural_ok})") if tb
        next
      end
      donor = bent[0] > RARE_FREQ_MAX ? bent[0] : 99
      base_prons = bent[1]
      Inflect.each_derivable_form(base) do |w|
        tr = dict_trace_morph?(base, w)
        if w == base || w.include?("-") || rare_words.include?(w)
          dict_trace_puts(w, "morph_expand_subtlex ← #{base}: skip (same/hyphen/rare_words)") if tr && w != base
          next
        end
        unless Inflect.inflection_of_base?(base, w)
          dict_trace_puts(w, "morph_expand_subtlex ← #{base}: skip (not inflection_of_base?)") if tr
          next
        end
        inflection_suffix_kind = Inflect.send(:match_suffix_kind, base, w)
        unless inflection_suffix_kind
          dict_trace_puts(w, "morph_expand_subtlex ← #{base}: skip (no suffix kind)") if tr
          next
        end
        wf = wordfreq_hash[w] || 0
        if inflection_suffix_kind == :s && !morph_base_allows_plural_s?(base, pos_map, forms_map, w, wordfreq_hash: wordfreq_hash, subtlex_hash: subtlex_hash)
          dict_trace_puts(w, "morph_expand_subtlex ← #{base}: skip (plural :s not allowed)") if tr
          next
        end
        if (inflection_suffix_kind == :ed || inflection_suffix_kind == :ing) && base.end_with?("ing")
          dict_trace_puts(w, "morph_expand_subtlex ← #{base}: skip (#{inflection_suffix_kind} on -ing base)") if tr
          next
        end
        if (inflection_suffix_kind == :ed || inflection_suffix_kind == :ing) && !morph_base_allows_verb_forms?(base, w, pos_map, forms_map, wf, wordfreq_hash, kaikki_verb_morph: kaikki_verb_morph)
          dict_trace_puts(w, "morph_expand_subtlex ← #{base}: skip (verb forms blocked; suffix=#{inflection_suffix_kind} zipf=#{wf})") if tr
          next
        end
        if inflection_suffix_kind == :er || inflection_suffix_kind == :est
          unless morph_base_allows_comparative_er_est?(base, w, pos_map, base_prons&.first, forms_map, wf)
            dict_trace_puts(w, "morph_expand_subtlex ← #{base}: skip (:er/:est not allowed)") if tr
            next
          end
        end
        if wf >= WORDFREQ_COMMON_ZIPF
          dict_trace_puts(w, "morph_expand_subtlex ← #{base}: skip (Zipf #{wf} ≥ #{WORDFREQ_COMMON_ZIPF})") if tr
          next
        end
        # Surface attestation: require wordfreq / WN / CMU / neol for the inflection itself (not just
        # the trickle signals — SUBTLEX count of 1, lone Numberbatch vector — that Kaikki morph inheritance also rejects).
        # Base membership in neol does not license Inflect-generated inflections (*taserred*,
        # *taserring*, *finnaed*, *rizzed*): the real neol paradigms (*tasered*, *tasering*, *yeeted*)
        # show up in wordfreq at low Zipf. Without this gate, even high-Zipf bases (*poly* Zipf 3.64)
        # hand donor frequency to Kaikki-documented jargon inflections (*polyed*) that have zero
        # running-text presence; the existing-row branch below would otherwise lift them without any
        # surface check. Short *-s* plurals of true WordNet noun-only bases (*gramophones*) still
        # surf_attested via WN / CMUdict so legitimate rare plurals are unaffected.
        surf_attested = wordfreq_hash.key?(w) ||
          wn_has_entry?(w) ||
          cmudict_orig.include?(w) ||
          neol_words.include?(w)
        base_zipf = wordfreq_hash[base] || 0
        # Only require form-level surf_attested when the base itself lacks a "real word" anchor.
        # Bases in common_words, WordNet, neol, or wordfreq at Zipf ≥ COMMON are authoritative
        # enough that their Kaikki-documented inflections get donor frequency on the base's
        # reputation alone (sacristy→sacristies, alpine→alpines, yeet→yeets). Without this
        # base-anchor escape, the surface-level gate would drop legit rare plurals / comparatives
        # of common-ish English lemmas whose inflected forms never accumulate enough SUBTLEX /
        # wordfreq volume to self-attest. The junk cases (poly, golly, hocus, bravado-as-verb,
        # taser, rizz, finna, getter, fox-as-verb-beyond-WN, ferris-as-plural) all fail every
        # clause of this anchor: no common_words / WN / neol entry, and Zipf < COMMON.
        # Mirror the +morph_inherit_kaikki+ split: corpus-only anchor for the
        # metadata flag (no leakage into +received_donor_from_common_base_flag+),
        # broad anchor (with curated commons) for the inheritance gate. See the
        # long comment on the same split in +morph_inherit_kaikki+ above.
        base_has_corpus_anchor = wn_has_entry?(base) ||
          neol_words.include?(base) ||
          base_zipf >= WORDFREQ_COMMON_ZIPF
        base_has_real_anchor = base_has_corpus_anchor || common_words.include?(base)
        if donor > RARE_FREQ_MAX && !base_has_real_anchor && !surf_attested
          dict_trace_puts(w, "morph_expand_subtlex ← #{base}: skip (base not in common_words/WN/neol, Zipf #{base_zipf} < COMMON, surface not in wordfreq/WN/CMU/neol)") if tr
          next
        end
        if inflection_suffix_kind == :s
          unless hash.key?(w) || neol_words.include?(base)
            dict_trace_puts(w, "morph_expand_subtlex ← #{base}: skip (:s branch, not in hash)") if tr
            next
          end
          # Verb-only bases: *-s* is 3sg (*twerks*), not a noun plural — +morph_base_allows_plural_s?+ already
          # allows that path elsewhere. Noun+verb lemmas (*blog*) still get plural promotion when morph allows.
          if wn_base_has_verb?(base) && !wn_base_has_noun?(base)
            dict_trace_puts(w, "morph_expand_subtlex ← #{base}: skip (:s branch, verb-only base)") if tr
            next
          end
          if hash.key?(w) && hash[w][0] > RARE_FREQ_MAX
            dict_trace_puts(w, "morph_expand_subtlex ← #{base}: skip (:s branch, freq already high)") if tr
            next
          end
          # Respect the specialized-lex demotion applied by +compute_frequency+ (+gens+ syn=1
          # noun.group). SUBTLEX-anchored Inflect expansion's plural-s path would otherwise re-promote +gens+ off its
          # +gen+ base (Zipf 4.33, passes corpus_ok), undoing the Option 2 clamp.
          if wn_encyclopedic_single_synset_demoted?(w, subtlex_hash, wordfreq_hash)
            dict_trace_puts(w, "morph_expand_subtlex ← #{base}: skip (:s branch, WN single-synset specialized-lex demotion)") if tr
            next
          end
          # Mirror the Kaikki morph inheritance nonstandard consonant+y plural gate: English canonical plural of
          # +teddy+/+lady+/+eddy+ is +teddies+/+ladies+/+eddies+. Kaikki sometimes records the
          # +-ys+ alternative; without its own Zipf ≥ RARE or WN entry, that surface is Wiktionary
          # paradigm echo and should not receive donor frequency here either.
          if base.length >= 2 && base.end_with?("y") && !%w[a e i o u y].include?(base[-2]) &&
              w == "#{base}s" &&
              !wn_has_entry?(w) && (wordfreq_hash[w] || 0) < WORDFREQ_RARE_ZIPF
            dict_trace_puts(w, "morph_expand_subtlex ← #{base}: skip (:s branch, nonstandard cons+ys plural)") if tr
            next
          end
          unless corpus_ok || lexical_plural_ok
            dict_trace_puts(w, "morph_expand_subtlex ← #{base}: skip (:s branch, corpus gates)") if tr
            next
          end
          if hash.key?(w)
            hash[w][0] = donor
            if hash[w][1].empty?
              promo = morph_derived_prons_for_promotion(base_prons, base, w)
              hash[w][1] = promo unless promo.empty?
            end
          else
            hash[w] = [donor, morph_derived_prons_for_promotion(base_prons, base, w)]
          end
          dict_trace_puts(w, "morph_expand_subtlex ← #{base}: set freq=#{donor} (:s plural path)") if tr
        elsif corpus_ok
          if hash.key?(w)
            if hash[w][0] > RARE_FREQ_MAX
              dict_trace_puts(w, "morph_expand_subtlex ← #{base}: skip (corpus path, existing freq high)") if tr
              next
            end
            hash[w][0] = donor
            if hash[w][1].empty?
              promo = morph_derived_prons_for_promotion(base_prons, base, w)
              hash[w][1] = promo unless promo.empty?
            end
            dict_trace_puts(w, "morph_expand_subtlex ← #{base}: set freq=#{donor} suffix=#{inflection_suffix_kind} (existing row)") if tr
          else
            unless surf_attested
              dict_trace_puts(w, "morph_expand_subtlex ← #{base}: skip (new row, not attested in any reference corpus)") if tr
              next
            end
            hash[w] = [donor, morph_derived_prons_for_promotion(base_prons, base, w)]
            dict_trace_puts(w, "morph_expand_subtlex ← #{base}: new row freq=#{donor} suffix=#{inflection_suffix_kind}") if tr
          end
        else
          dict_trace_puts(w, "morph_expand_subtlex ← #{base}: skip (not :s and !corpus_ok)") if tr
          next
        end
        record_freq_propagation!(w, phase: :morph_expand_subtlex, donor: base, donor_anchored: base_has_corpus_anchor)
        round += 1
        morph_corpus += 1
      end
    end
    break if round == 0
  end
  puts "#{morph_corpus} morphological extensions from strong-corpus bases (not in common_words list)" if morph_corpus > 0

  # G-drop frequency inheritance: +failin'+/+wailin'+/+somethin'+ inherit from +failing+/+wailing+/
  # +something+ when the base is common. The apostrophe surface is merged in
  # +merge_gdropped_in_apostrophe_forms!+ before the frequency phases, but none of the
  # downstream morph inheritance / expansion passes
  # see it as an Inflect stem, so it sits at freq 0 and reads as :forbidden. Cap the inherited
  # frequency at +RARE_FREQ_MAX+ so g-drop never surfaces as :common (it's informal dialect, not
  # the base lemma).
  gdrop_inherited = 0
  hash.keys.each do |word|
    next unless word.end_with?("in'") || word.end_with?("in\u2019")
    entry = hash[word]
    next unless entry && entry[0] == 0
    base = word.sub(/in['\u2019]\z/, "ing")
    base_entry = hash[base]
    next unless base_entry && base_entry[0] > 0
    hash[word][0] = [base_entry[0], RARE_FREQ_MAX].min
    # +donor_anchored+ corpus-only — see comment in +morph_inherit_listed+.
    record_freq_propagation!(word, phase: :gdrop, donor: base, donor_anchored: donor_has_corpus_anchor?(base, wordfreq_hash, neol_words))
    gdrop_inherited += 1
  end
  puts "#{gdrop_inherited} -in' g-drop surfaces inherited frequency from -ing base (rare-capped)" if gdrop_inherited > 0

  strip_gdrop_bare_homographs!(hash, cmudict_orig)

  # Drop bare possessive surface forms (+X's+) whose stem +X+ has freq 0 or is missing from the
  # dict. CMU ships encyclopedic surname / place-name possessives (+cardenas's+, +chinn's+,
  # +hammas's+, +wallich's+, +baton-rouge's+) whose stem is either absent or sits at freq 0 after
  # the proper-noun gates above. These surface forms then survive the disconnect rescue via their
  # rime cohort and get classified as :rare, but they're purely encyclopedic noise. Common
  # possessives (+it's+, +let's+, +john's+) have freq-positive stems and are preserved.
  possessive_scrub = 0
  hash.keys.each do |word|
    next unless word.end_with?("'s") || word.end_with?("\u2019s")
    stem = word.sub(/['\u2019]s\z/, "")
    next if stem.empty?
    stem_entry = hash[stem]
    stem_freq = stem_entry ? stem_entry[0] : 0
    next if stem_freq > 0
    dict_trace_puts(word, "possessive_scrub: DELETE (stem='#{stem}' freq=#{stem_freq})") if dict_trace_word?(word)
    hash.delete(word)
    possessive_scrub += 1
  end
  puts "#{possessive_scrub} bare possessive headwords dropped (X's with freq==0 or missing stem X)" if possessive_scrub > 0

  # Drop hyphenated freq==0 headwords whose only WordNet senses are noun.location / noun.person /
  # noun.group / noun.animal (race/breed style proper-noun taxonomies). CMU carries *hong-kong*,
  # *buenos-aires*, *addis-ababa*, *burkina-faso*, *el-paso*, *cro-magnon*, *corpus-christi* as
  # encyclopedic multi-word expressions that the test expects forbidden; they survive the rhyme-
  # rescue path because Kaikki/WN back them, but they're just place/proper-noun noise. Keeps
  # artifact/communication/cognition compounds (*bain-marie*, *double-entendre*, *anti-semitism*,
  # *ad-hoc*) which the tests accept as rare via the normal disconnect rescue.
  # Drop freq==0 spurious invariant/irregular plurals (*sheeps*, *oxes*, *gooses*, *chaoses*):
  # +compute_frequency+ already returned 0 via +morph_spurious_plural_s_on_invariant_noun?+, but
  # wordfreq's encyclopedic mix sometimes ships a low-Zipf row for them which the disconnect filter
  # treats as corpus-attested and keeps. They then read as :rare; remove outright so they're forbidden.
  invariant_plural_scrub = 0
  hash.keys.each do |word|
    entry = hash[word]
    next unless entry && entry[0] == 0
    next unless morph_spurious_plural_s_on_invariant_noun?(word)
    dict_trace_puts(word, "invariant_plural_scrub: DELETE") if dict_trace_word?(word)
    hash.delete(word)
    invariant_plural_scrub += 1
  end
  puts "#{invariant_plural_scrub} spurious invariant/irregular plural headwords dropped" if invariant_plural_scrub > 0

  proper_lexfiles = Set.new(%w[noun.location noun.person noun.group noun.animal]).freeze
  hyphenated_proper_scrub = 0
  hash.keys.each do |word|
    next unless word.include?("-")
    entry = hash[word]
    next unless entry && entry[0] == 0
    lexnames = wn_noun_synsets_unified(word.tr("-", "_")).map { |s| wn_synset_noun_lexname(s) }.compact.uniq
    next if lexnames.empty?
    next unless lexnames.all? { |l| proper_lexfiles.include?(l) }
    dict_trace_puts(word, "hyphenated_proper_scrub: DELETE") if dict_trace_word?(word)
    hash.delete(word)
    hyphenated_proper_scrub += 1
  end
  puts "#{hyphenated_proper_scrub} hyphenated zero-frequency headwords dropped (WN proper-noun lexfiles only)" if hyphenated_proper_scrub > 0

  forbidden_scrub = 0
  forbidden_scrub_non_ascii = 0
  hash.keys.each do |word|
    next unless explicitly_forbidden?(word)
    is_non_ascii = non_ascii_only?(word)
    if dict_trace_word?(word)
      reason = is_non_ascii ? "non_ascii_only" : "in forbid_list"
      dict_trace_puts(word, "forbidden_scrub: DELETE (#{reason})")
    end
    hash.delete(word)
    forbidden_scrub += 1
    forbidden_scrub_non_ascii += 1 if is_non_ascii
  end
  if forbidden_scrub > 0
    detail = forbidden_scrub_non_ascii > 0 ? " (#{forbidden_scrub_non_ascii} non-ASCII-only)" : ""
    puts "#{forbidden_scrub} explicitly forbidden surface forms removed after frequency phases#{detail}"
  end

  unrhymable_scrub = 0
  hash.keys.each do |word|
    next unless unrhymable_stop_word?(word)
    dict_trace_puts(word, "unrhymable_scrub: DELETE (in unrhymable_stop_words)") if dict_trace_word?(word)
    hash.delete(word)
    unrhymable_scrub += 1
  end
  puts "#{unrhymable_scrub} unrhymable stop words removed after frequency phases" if unrhymable_scrub > 0

  hyp_edge = delete_headwords_with_edge_hyphen!(hash)
  puts "#{hyp_edge} headwords with a leading or trailing '-' removed after frequency phases" if hyp_edge > 0

  # Rarity classifier rescore: post-propagation rescore / signal dump (no-op when the
  # classifier JSON is absent AND dump is not enabled). See
  # +lib/rhymecrime/dict/rarity_classifier.rb+ for the rescore semantics; the dump
  # path is driven by +RHYMECRIME_RARITY_DUMP_SIGNALS+.
  rarity_rescore_and_dump!(
    hash,
    subtlex_hash: subtlex_hash,
    subtlex_total_hash: subtlex_total_hash,
    wordfreq_hash: wordfreq_hash,
    pos_map: pos_map,
    wiktionary_words: wiktionary_words,
    rare_words: rare_words,
    common_words: common_words,
    neol_words: neol_words,
    cmudict_orig: cmudict_orig,
    ref_cn: ref_cn,
    ref_nb: ref_nb,
    ref_usf: ref_usf,
    # Forwarded so the dump path can call +compute_frequency+ with the same
    # +kaikki_capitalized_only+ guard the seed loop uses; keeps the dump's
    # corpus-only freq aligned with what the non-curated fall-through branch
    # of the seed loop would have produced.
    kaikki_capitalized_only: kaikki_capitalized_only,
  )

  puts "#{count + extra + common_extra + floor_applied + inherited + cw_inherited + morph_inherited + morph_corpus} total entries with frequency data"
  return hash
end

def build_word_dict(cmudict, rdict, subtlex_hash, subtlex_total_hash, wordfreq_hash, wiktionary_words, pos_map, forms_map, kaikki_verb_morph = nil, original_cmudict_headwords = nil, kaikki_capitalized_only = nil, kaikki_variant_map = nil, varcon_variant_map = nil)
  cmudict = filter_cmudict(cmudict, rdict)
  word_dict = add_frequency_info(cmudict, subtlex_hash, subtlex_total_hash, wordfreq_hash, wiktionary_words, pos_map, forms_map, kaikki_verb_morph, original_cmudict_headwords, kaikki_capitalized_only)
  append_r_to_orthographic_r_pronunciations!(word_dict, label: "word_dict")
  insert_r_before_final_d_for_red_pronunciations!(word_dict, label: "word_dict")
  insert_r_before_final_sibilant_for_s_pronunciations!(word_dict, label: "word_dict")
  merge_word_dict_pronunciations_into_rdict!(rdict, word_dict)
  emit_spelling_variants_auto!(word_dict, wordfreq_hash, kaikki_variant_map, varcon_variant_map)
  strip_dispreferred_headwords_from_rdict!(rdict, word_dict)
  delete_rare_only_rime_buckets!(rdict, word_dict)
  delete_common_identical_only_rime_buckets!(rdict, word_dict)
  filter_word_dict_disconnected!(word_dict, rdict, subtlex_hash, wordfreq_hash, pos_map, forms_map, original_cmudict_headwords, wiktionary_words)
  word_dict
end
