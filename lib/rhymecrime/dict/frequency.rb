# encoding: utf-8
# SUBTLEX / wordfreq I/O, compute_frequency, add_frequency_info phases, filter_word_dict, build_word_dict.

require "set"
require_relative "utils_rhyme"
require_relative "constants"
require_relative "lexical"
require_relative "morphology"
require_relative "phonology"
require_relative "rime"

#
# SUBTLEX-US (movie subtitle corpus, 51M words, 74K unique word forms)
# Source: Brysbaert & New (2009), full TSV from openlexicon.fr
# We use FREQlow (lowercase occurrences only) to avoid counting
# sentence-initial capitalization and proper noun uses.
#

def load_subtlex()
  subtlex_hash = Hash.new(0)
  first = true
  IO.readlines(SUBTLEX_FILENAME, encoding: 'UTF-8').each do |line|
    if first
      first = false
      next
    end
    fields = line.chomp.split("\t")
    word_lower = fields[0].downcase
    freq_low = fields[3].to_i
    subtlex_hash[word_lower] = freq_low if freq_low > subtlex_hash[word_lower]
  end
  puts "Loaded #{subtlex_hash.length} words from SUBTLEX-US"
  return subtlex_hash
end

# True if +w+ hits at least one external lexicon used for runtime relatedness / audit (wordfreq TSV,
# SUBTLEX FREQlow, WordNet lemma, pre-merge CMU headword, USF cue/target, ConceptNet lemma cache,
# Numberbatch embedding list). Used to block morph phases from copying base_freq>RARE_FREQ_MAX onto
# surfaces that exist only via Kaikki/Inflect (e.g. *necrophilias*).
def inflection_surface_reference_attested?(w, subtlex_hash, wordfreq_hash, original_cmudict_headwords, cn_vocab, nb_token_set, usf_word_set)
  return true if wordfreq_hash.key?(w)
  return true if (subtlex_hash[w] || 0).to_i > 0
  return true if wn_has_entry?(w)
  return true if original_cmudict_headwords.include?(w)
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
    return wordfreq_hash
  end
  File.foreach(WORDFREQ_FILENAME, encoding: 'UTF-8') do |line|
    word, zipf_str = line.chomp.split("\t")
    next if word.nil? || zipf_str.nil?
    wordfreq_hash[word] = zipf_str.to_f
  end
  puts "Loaded #{wordfreq_hash.length} words from wordfreq"
  wordfreq_hash
end
def filter_word_dict(word_dict)
  filtered_word_dict = Hash.new
  for word, entry in word_dict
    freq, prons = entry
    if(!prons.empty? || freq > 0)
      filtered_word_dict[word] = entry
      dict_trace_puts(word, "filter_word_dict: freq=#{freq} prons=#{prons.size} passed filters") if dict_trace_word?(word)
    end
  end
  puts "#{filtered_word_dict.length} out of #{word_dict.length} entries remain in the dictionary after removing words with no rhymes and zero frequency"
  return filtered_word_dict
end

# Kaikki +wordfreq+ OOV rescue (idea 2b): forms in +forms_map+ whose +base+ has wordfreq Zipf ≥ +zipf_floor+.
# Does not use Inflect forward derivation (idea 2a) — too many FPs.
def kaikki_form_oov_rescue_headwords(forms_map, wordfreq_hash, zipf_floor, wiktionary_words = nil)
  out = Set.new
  wk = wiktionary_words || Set.new
  forms_map.each do |base, pairs|
    z = wordfreq_hash[base] || 0
    anchored = z >= zipf_floor ||
      (wk.include?(base) && z >= WORDFREQ_KAIKKI_FORM_BASE_MIN)
    next unless anchored
    pairs.each do |form, b|
      out.add(form) if b == base
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
            others = cohort.reject { |x| x == w }
            dict_trace_puts(w, "disconnect: rime=#{pron.rime} bucket=#{cohort.size} others=#{others.take(10).inspect}#{' …' if others.size > 10}")
          end
        end
      end
      in_wordfreq_tsv = wordfreq_hash.key?(w)
      keep = if in_wordfreq_tsv
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
      word_dict.delete(w)
      removed += 1
    end
    total_removed += removed
    prune_rdict_to_headwords!(rdict, word_dict.keys)
    delete_rare_only_rime_buckets!(rdict, word_dict)
    break if removed == 0 || rounds >= 12
  end
  if total_removed > 0
    puts "#{total_removed} headwords removed (freq==0 disconnect filter)"
  end
  word_dict
end

def compute_frequency(word, subtlex_hash, wordfreq_hash)
  return 0 if morph_spurious_plural_s_on_invariant_noun?(word)

  _, wn_all_proper = wn_frequency(word)
  in_wordnet = wn_has_entry?(word)
  sub_raw = subtlex_hash[word] || 0
  zipf = wordfreq_hash[word] || 0
  syn_n = wn_synset_count(word)

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

  return 0 if wn_all_proper

  # e.g. atm: WordNet lemma + high Zipf but almost no lowercase subtitle hits — encyclopedic initialism.
  weak_lexical_anchor = short_initialism_shape?(word) && in_wordnet && sub_raw < SUBTLEX_OVERRIDE_PROPER_MIN && zipf >= WORDFREQ_COMMON_ZIPF

  lexically_anchored = in_wordnet && !weak_lexical_anchor

  subtlex_freq = subtlex_frequency(word, subtlex_hash)
  if zipf > 0 && zipf < WORDFREQ_RARE_ZIPF && subtlex_freq > RARE_FREQ_MAX
    subtlex_freq = RARE_FREQ_MAX
  end

  # Without a lexical anchor, high Zipf often reflects encyclopedic/person-name hits; do not let
  # SUBTLEX alone push past the rare threshold (e.g. nam ~ Viet Nam fragments in subtitles).
  if !lexically_anchored && zipf >= WORDFREQ_COMMON_ZIPF
    subtlex_freq = [subtlex_freq, RARE_FREQ_MAX].min
  end

  block_short_initialism_wordfreq = acronym_shape_wordfreq_only?(word) && subtlex_freq == 0 && !in_wordnet
  wordfreq_boost = (zipf >= WORDFREQ_COMMON_ZIPF && !block_short_initialism_wordfreq) ? 5 : 0

  # Zipf-only boost with no anchor and zero SUBTLEX FREQlow: usually Wikipedia names (graeme, platt).
  if !lexically_anchored && sub_raw == 0
    wordfreq_boost = 0
  end

  # Short initialism-shaped strings with high Zipf but no anchor: treat Zipf as noisy.
  if !lexically_anchored && short_initialism_shape?(word) && zipf >= WORDFREQ_COMMON_ZIPF
    wordfreq_boost = 0
  end

  freq = [subtlex_freq, wordfreq_boost].max

  dict_trace_puts(word, "compute_frequency: subtlex=#{subtlex_freq} zipf=#{zipf} in_wn=#{in_wordnet} lexical_anchor=#{lexically_anchored} wordfreq_boost=#{wordfreq_boost} (needs zipf≥#{WORDFREQ_COMMON_ZIPF} for boost) block_short_init=#{block_short_initialism_wordfreq} all_proper=#{wn_all_proper} => #{freq}") if dict_trace_word?(word)
  return freq
end

# Phase 9: try to lift +word+ to donor freq via +listed+ (common_words.txt), forward or reverse Inflect match.
def phase9_inherit_once!(word, listed, forward, hash, rare_words, common_words, pos_map, forms_map, kaikki_verb_morph, subtlex_hash, wordfreq_hash, cmudict_orig, ref_cn, ref_nb, ref_usf)
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
    tr = dict_trace_phase9?(word, listed, base, infl)
    dict_trace_puts(word, "Phase9 listed=#{listed}: skip (Kaikki lists #{inflect_stem} as form of #{$inflection_base_words[inflect_stem]})") if tr
    return false
  end

  tr = dict_trace_phase9?(word, listed, base, infl)
  inflection_suffix_kind = Inflect.send(:match_suffix_kind, base, infl)
  if inflection_suffix_kind.nil?
    dict_trace_puts(word, "Phase9 listed=#{listed} base=#{base} infl=#{infl}: skip (no suffix kind)") if tr
    return false
  end
  wf_infl = wordfreq_hash[infl] || 0
  if inflection_suffix_kind == :s && !morph_base_allows_plural_s?(base, pos_map, forms_map, infl, wordfreq_hash: wordfreq_hash, subtlex_hash: subtlex_hash)
    dict_trace_puts(infl, "Phase9 ← #{base} (listed=#{listed}): skip (plural :s not allowed)") if tr
    return false
  end
  list_auth = common_words.include?(base)
  if (inflection_suffix_kind == :ed || inflection_suffix_kind == :ing) && !morph_base_allows_verb_forms?(base, infl, pos_map, forms_map, wf_infl, wordfreq_hash, list_authoritative_base: list_auth, kaikki_verb_morph: kaikki_verb_morph)
    dict_trace_puts(infl, "Phase9 ← #{base} (listed=#{listed}): skip (verb forms blocked; suffix=#{inflection_suffix_kind} list_auth=#{list_auth} zipf=#{wf_infl})") if tr
    return false
  end
  if inflection_suffix_kind == :er || inflection_suffix_kind == :est
    base_p0 = hash[base]&.dig(1)&.first
    unless morph_base_allows_comparative_er_est?(base, infl, pos_map, base_p0, forms_map, wf_infl)
      dict_trace_puts(infl, "Phase9 ← #{base}: skip (:er/:est not allowed)") if tr
      return false
    end
  end
  listed_freq = hash.key?(listed) ? hash[listed][0] : 0
  donor = listed_freq > RARE_FREQ_MAX ? listed_freq : 99
  if donor > RARE_FREQ_MAX && !common_words.include?(listed) && !inflection_surface_reference_attested?(word, subtlex_hash, wordfreq_hash, cmudict_orig, ref_cn, ref_nb, ref_usf)
    dict_trace_puts(word, "Phase9 ← base=#{base} (listed=#{listed}): skip (surface not in wordfreq/SUBTLEX/WN/CMU/USF/CN/NB)") if tr
    return false
  end
  entry[0] = donor
  dict_trace_puts(word, "Phase9: set freq=#{donor} via listed=#{listed} base=#{base} infl=#{infl} suffix=#{inflection_suffix_kind}") if tr
  true
end

def add_frequency_info(cmudict, subtlex_hash, wordfreq_hash, wiktionary_words, pos_map, forms_map, kaikki_verb_morph = nil, original_cmudict_headwords = nil)
  count = 0
  hash = Hash.new
  rare_words = IO.readlines(RARE_WORDS_FILENAME, chomp: true, encoding: 'UTF-8')
  common_words = IO.readlines(COMMON_WORDS_FILENAME, chomp: true, encoding: 'UTF-8')
  cmudict_orig = original_cmudict_headwords || Set.new
  ref_cn = conceptnet_lemma_vocab_for_attestation
  ref_nb_path = numberbatch_txt_path
  ref_nb = ref_nb_path ? numberbatch_corpus_token_set(ref_nb_path) : nil
  ref_usf = usf_corpus_word_set
  for word, prons in cmudict
    if(stop_word?(word))
      freq = 999999
    elsif(common_words.include?(word))
      freq = 99
    elsif(rare_words.include?(word))
      freq = 0
    else
      freq = compute_frequency(word, subtlex_hash, wordfreq_hash)
    end
    if(freq > 0)
      count += 1
    end
    hash[word] = [freq, prons]
  end
  puts "#{count} of those entries have frequency data (from cmudict/wiktionary words)"

  # Phase 4: add words from SUBTLEX that aren't in cmudict.
  extra = 0
  subtlex_hash.each_key do |word|
    next if hash.key?(word)
    next unless word.match?(/\A[a-z]([a-z'\-]*[a-z])?\z/)
    if(stop_word?(word))
      freq = 999999
    elsif(common_words.include?(word))
      freq = 99
    elsif(rare_words.include?(word))
      freq = 0
    else
      freq = compute_frequency(word, subtlex_hash, wordfreq_hash)
    end
    if freq > 0
      hash[word] = [freq, []]
      extra += 1
    end
  end
  puts "#{extra} extra words added from SUBTLEX"

  # Phase 5: add words from common_words.txt not already in the dict.
  common_extra = 0
  common_words.each do |word|
    next if hash.key?(word)
    hash[word] = [99, []]
    puts "  Added #{word} to the dictionary with frequency 99"
    common_extra += 1
  end
  puts "#{common_extra} extra words added from common_words.txt" if common_extra > 0

  # Phase 6: Wiktionary floor for modern words absent from all traditional corpora, e.g. throuple, yeet.
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
    next if short_initialism_shape?(word) && subtlex_hash[word] <= 0
    # 2-4 letter strings with strong wordfreq but no lexical anchor: skip floor so
    # IMAX/DVD-style tokens stay rare; Zipf < 3 keeps yeet
    next if acronym_shape_wordfreq_only?(word) && subtlex_hash[word] <= 0 && !wn_has_entry?(word) && zipf >= WORDFREQ_COMMON_ZIPF
    entry[0] = 5
    floor_applied += 1
  end
  puts "#{floor_applied} words received Wiktionary existence floor" if floor_applied > 0

  # Phase 7 (hyphenated word existence floor) disabled: it promoted many proper names / junk;
  # hyphenated headwords now rely on compute_frequency, Phase 6, and later phases only.

  # Phase 8: frequency inheritance for inflected forms.
  # Inherit from any common base word. Skip only when wordfreq shows the inflection itself
  # as independently common (Zipf >= COMMON); a mere corpus key with low Zipf still inherits
  # (yeeted, twerks) so slang bases propagate.
  # Skip -ing → base when WordNet has the base but only as noun/adj/etc.: prevents
  # spurious "kitchening" inheriting from "kitchen" (FP-4). Verbal -ing still inherits
  # when the base has a verb lemma, or when the base is absent from WordNet (slang).
  inherited = 0
  $inflection_base_words.each do |inflected, base|
    tr = dict_trace_morph?(base, inflected)
    unless hash.key?(inflected)
      dict_trace_puts(inflected, "Phase8 ← #{base}: skip (not in hash)") if tr
      next
    end
    if rare_words.include?(inflected)
      dict_trace_puts(inflected, "Phase8 ← #{base}: skip (in rare_words.txt)") if tr
      next
    end
    if hash[inflected][0] > 0
      dict_trace_puts(inflected, "Phase8 ← #{base}: skip (freq already #{hash[inflected][0]})") if tr
      next
    end
    # Do not copy frequency from hyphenated base to hyphenated inflection (hoity-toity → hoity-toities).
    if inflected.include?("-") && base.include?("-")
      dict_trace_puts(inflected, "Phase8 ← #{base}: skip (hyphenated base↔inflection)") if tr
      next
    end
    base_freq = hash.key?(base) ? hash[base][0] : 0
    if base_freq <= RARE_FREQ_MAX
      dict_trace_puts(inflected, "Phase8 ← #{base}: skip (base_freq=#{base_freq} ≤ #{RARE_FREQ_MAX})") if tr
      next
    end
    wf_inf = wordfreq_hash[inflected]
    if wf_inf && wf_inf >= WORDFREQ_COMMON_ZIPF
      dict_trace_puts(inflected, "Phase8 ← #{base}: skip (Zipf #{wf_inf} ≥ #{WORDFREQ_COMMON_ZIPF})") if tr
      next
    end
    inflection_suffix_kind = Inflect.send(:match_suffix_kind, base, inflected)
    if inflection_suffix_kind == :s && !morph_base_allows_plural_s?(base, pos_map, forms_map, inflected, wordfreq_hash: wordfreq_hash, subtlex_hash: subtlex_hash)
      dict_trace_puts(inflected, "Phase8 ← #{base}: skip (plural :s not allowed)") if tr
      next
    end
    zf_w = wordfreq_hash[inflected] || 0
    if (inflection_suffix_kind == :ed || inflection_suffix_kind == :ing) && !morph_base_allows_verb_forms?(base, inflected, pos_map, forms_map, zf_w, wordfreq_hash, kaikki_verb_morph: kaikki_verb_morph)
      dict_trace_puts(inflected, "Phase8 ← #{base}: skip (verb forms blocked; suffix=#{inflection_suffix_kind} zipf_inf=#{zf_w})") if tr
      next
    end
    if inflection_suffix_kind == :er || inflection_suffix_kind == :est
      base_p0 = hash[base]&.dig(1)&.first
      unless morph_base_allows_comparative_er_est?(base, inflected, pos_map, base_p0, forms_map, zf_w)
        dict_trace_puts(inflected, "Phase8 ← #{base}: skip (:er/:est not allowed)") if tr
        next
      end
    end
    if base_freq > RARE_FREQ_MAX && !common_words.include?(base) && !inflection_surface_reference_attested?(inflected, subtlex_hash, wordfreq_hash, cmudict_orig, ref_cn, ref_nb, ref_usf)
      dict_trace_puts(inflected, "Phase8 ← #{base}: skip (not in wordfreq/SUBTLEX/WN/CMU/USF/CN/NB)") if tr
      next
    end
    hash[inflected][0] = base_freq
    dict_trace_puts(inflected, "Phase8 ← #{base}: inherited freq=#{base_freq} suffix=#{inflection_suffix_kind}") if tr
    inherited += 1
  end
  puts "#{inherited} inflected forms inherited frequency from base words" if inherited > 0

  # Phase 9: suffix inheritance from common_words.txt (Inflect spelling patterns).
  # Phase 8 only fills entries with frequency 0; listed headwords still leave plurals / -ing, etc.
  # in the rare bins (1..RARE_FREQ_MAX). Match forward (listed + suffix = word) or reverse (word + suffix = listed,
  # e.g. regionalize… ← regionalized). Structural junk guards only; list headwords skip Kaikki verb
  # attestation (see +list_authoritative_base+ on +morph_base_allows_verb_forms?+). When +listed+ is in
  # common_words.txt, also skip +inflection_surface_reference_attested?+ so curated lemmas can lift OOV inflections.
  cw_sorted = common_words.uniq.sort_by { |b| -b.length }
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
          dict_trace_puts(w, "Phase9: skip row (freq #{entry[0]} already > #{RARE_FREQ_MAX})") if dict_trace_word?(w)
          next
        end
        if rare_words.include?(w)
          dict_trace_puts(w, "Phase9: skip row (in rare_words.txt)") if dict_trace_word?(w)
          next
        end
        next unless phase9_inherit_once!(w, listed, true, hash, rare_words, common_words, pos_map, forms_map, kaikki_verb_morph, subtlex_hash, wordfreq_hash, cmudict_orig, ref_cn, ref_nb, ref_usf)
        claimed[w] = true
        round += 1
        cw_inherited += 1
      end

      Inflect.each_candidate_base_for_inflected(listed) do |w|
        next unless hash.key?(w)
        next if claimed[w]
        entry = hash[w]
        if entry[0] > RARE_FREQ_MAX
          dict_trace_puts(w, "Phase9: skip row (freq #{entry[0]} already > #{RARE_FREQ_MAX})") if dict_trace_word?(w)
          next
        end
        if rare_words.include?(w)
          dict_trace_puts(w, "Phase9: skip row (in rare_words.txt)") if dict_trace_word?(w)
          next
        end
        next unless phase9_inherit_once!(w, listed, false, hash, rare_words, common_words, pos_map, forms_map, kaikki_verb_morph, subtlex_hash, wordfreq_hash, cmudict_orig, ref_cn, ref_nb, ref_usf)
        claimed[w] = true
        round += 1
        cw_inherited += 1
      end
    end
    break if round == 0
  end
  puts "#{cw_inherited} forms inherited frequency from common_words.txt bases" if cw_inherited > 0

  # Phase 10: morphological extensions from common_words.txt headwords only (Inflect matcher).
  # Unlike an “any freq>RARE_FREQ_MAX lemma” scan, this avoids promoting foxed/gooses/bruisers from ordinary
  # common nouns and avoids hyphenated blast (topsy-turvy → topsy-turvys).
  # OOV rows: list headwords are authoritative (no SUBTLEX/Wikt gate). Existing keys may be raised.
  # -ing from a base requires a WordNet verb lemma (same FP-4 guard as Phase 8).
  morph_inherited = 0
  loop do
    round = 0
    # Snapshot keys so new OOV entries do not disturb this pass; multi-round picks them up as donors.
    hash.keys.each do |base|
      bent = hash[base]
      tb = dict_trace_word?(base)
      unless bent && bent[0] > RARE_FREQ_MAX
        dict_trace_puts(base, "Phase10: skip (no row or freq #{bent ? bent[0] : 'nil'} ≤ #{RARE_FREQ_MAX})") if tb
        next
      end
      unless common_words.include?(base)
        dict_trace_puts(base, "Phase10: skip (not in common_words.txt)") if tb
        next
      end
      if stop_word?(base)
        dict_trace_puts(base, "Phase10: skip (stop word)") if tb
        next
      end
      if rare_words.include?(base)
        dict_trace_puts(base, "Phase10: skip (in rare_words.txt)") if tb
        next
      end
      if base.include?("-")
        dict_trace_puts(base, "Phase10: skip (hyphenated)") if tb
        next
      end
      if morph_kaikki_lists_surface_as_inflected_nonlemma?(base)
        dict_trace_puts(base, "Phase10: skip (Kaikki form of #{$inflection_base_words[base]}, not an Inflect stem)") if tb
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
          dict_trace_puts(w, "Phase10 ← #{base}: skip (hyphenated form)") if tr
          next
        end
        if rare_words.include?(w)
          dict_trace_puts(w, "Phase10 ← #{base}: skip (in rare_words.txt)") if tr
          next
        end
        unless Inflect.inflection_of_base?(base, w)
          dict_trace_puts(w, "Phase10 ← #{base}: skip (not inflection_of_base?)") if tr
          next
        end
        inflection_suffix_kind = Inflect.send(:match_suffix_kind, base, w)
        wf = wordfreq_hash[w] || 0
        if inflection_suffix_kind == :s && !morph_base_allows_plural_s?(base, pos_map, forms_map, w, wordfreq_hash: wordfreq_hash, subtlex_hash: subtlex_hash)
          dict_trace_puts(w, "Phase10 ← #{base}: skip (plural :s not allowed)") if tr
          next
        end
        if (inflection_suffix_kind == :ed || inflection_suffix_kind == :ing) && !morph_base_allows_verb_forms?(base, w, pos_map, forms_map, wf, wordfreq_hash, kaikki_verb_morph: kaikki_verb_morph)
          dict_trace_puts(w, "Phase10 ← #{base}: skip (verb forms blocked; suffix=#{inflection_suffix_kind} zipf=#{wf})") if tr
          next
        end
        if inflection_suffix_kind == :er || inflection_suffix_kind == :est
          unless morph_base_allows_comparative_er_est?(base, w, pos_map, base_prons&.first, forms_map, wf)
            dict_trace_puts(w, "Phase10 ← #{base}: skip (:er/:est not allowed)") if tr
            next
          end
        end
        if wf >= WORDFREQ_COMMON_ZIPF
          dict_trace_puts(w, "Phase10 ← #{base}: skip (Zipf #{wf} ≥ #{WORDFREQ_COMMON_ZIPF})") if tr
          next
        end
        # Phase 10 scans only common_words.txt bases; list headwords are authoritative (no reference-corpus gate).
        if hash.key?(w)
          if hash[w][0] > RARE_FREQ_MAX
            dict_trace_puts(w, "Phase10 ← #{base}: skip (existing freq #{hash[w][0]} > #{RARE_FREQ_MAX})") if tr
            next
          end
          hash[w][0] = donor
          if hash[w][1].empty?
            promo = morph_derived_prons_for_promotion(base_prons, base, w)
            hash[w][1] = promo unless promo.empty?
          end
          dict_trace_puts(w, "Phase10 ← #{base}: set freq=#{donor} suffix=#{inflection_suffix_kind} (existing row)") if tr
        else
          hash[w] = [donor, morph_derived_prons_for_promotion(base_prons, base, w)]
          dict_trace_puts(w, "Phase10 ← #{base}: new row freq=#{donor} suffix=#{inflection_suffix_kind}") if tr
        end
        round += 1
        morph_inherited += 1
      end
    end
    break if round == 0
  end
  puts "#{morph_inherited} morphological extensions inherited from freq>#{RARE_FREQ_MAX} bases" if morph_inherited > 0

  # Phase 11: non-list bases with strong SUBTLEX dialogue use may promote attested inflections.
  # Tighter than old “any freq>RARE_FREQ_MAX”: no hyphen, min length; plural :s can also use a lower SUBTLEX
  # floor when WordNet has the base as noun-only (gramophone → gramophones); blocks gooses-style
  # verbal plurals via wn_base_has_verb?. Non-plural suffixes still require MORPH_CORPUS_SUBTLEX_MIN.
  morph_corpus = 0
  loop do
    round = 0
    hash.keys.each do |base|
      tb = dict_trace_word?(base)
      if common_words.include?(base)
        dict_trace_puts(base, "Phase11: skip (in common_words.txt)") if tb
        next
      end
      if base.include?("-")
        dict_trace_puts(base, "Phase11: skip (hyphenated)") if tb
        next
      end
      bent = hash[base]
      unless bent && bent[0] > RARE_FREQ_MAX
        dict_trace_puts(base, "Phase11: skip (no row or freq #{bent ? bent[0] : 'nil'} ≤ #{RARE_FREQ_MAX})") if tb
        next
      end
      if stop_word?(base) || rare_words.include?(base)
        dict_trace_puts(base, "Phase11: skip (stop/rare_words)") if tb
        next
      end
      if base.bytesize < 5
        dict_trace_puts(base, "Phase11: skip (too short)") if tb
        next
      end
      sub_raw = subtlex_hash[base] || 0
      corpus_ok = sub_raw >= MORPH_CORPUS_SUBTLEX_MIN
      lexical_plural_ok = wn_has_entry?(base) && !wn_base_has_verb?(base) &&
        sub_raw >= MORPH_LEXICAL_NOUN_PLURAL_SUBTLEX_MIN
      unless corpus_ok || lexical_plural_ok
        dict_trace_puts(base, "Phase11: skip (sub_raw=#{sub_raw}; corpus_ok=#{corpus_ok} lexical_plural_ok=#{lexical_plural_ok})") if tb
        next
      end
      donor = bent[0] > RARE_FREQ_MAX ? bent[0] : 99
      base_prons = bent[1]
      Inflect.each_derivable_form(base) do |w|
        tr = dict_trace_morph?(base, w)
        if w == base || w.include?("-") || rare_words.include?(w)
          dict_trace_puts(w, "Phase11 ← #{base}: skip (same/hyphen/rare_words)") if tr && w != base
          next
        end
        unless Inflect.inflection_of_base?(base, w)
          dict_trace_puts(w, "Phase11 ← #{base}: skip (not inflection_of_base?)") if tr
          next
        end
        inflection_suffix_kind = Inflect.send(:match_suffix_kind, base, w)
        unless inflection_suffix_kind
          dict_trace_puts(w, "Phase11 ← #{base}: skip (no suffix kind)") if tr
          next
        end
        wf = wordfreq_hash[w] || 0
        if inflection_suffix_kind == :s && !morph_base_allows_plural_s?(base, pos_map, forms_map, w, wordfreq_hash: wordfreq_hash, subtlex_hash: subtlex_hash)
          dict_trace_puts(w, "Phase11 ← #{base}: skip (plural :s not allowed)") if tr
          next
        end
        if (inflection_suffix_kind == :ed || inflection_suffix_kind == :ing) && !morph_base_allows_verb_forms?(base, w, pos_map, forms_map, wf, wordfreq_hash, kaikki_verb_morph: kaikki_verb_morph)
          dict_trace_puts(w, "Phase11 ← #{base}: skip (verb forms blocked; suffix=#{inflection_suffix_kind} zipf=#{wf})") if tr
          next
        end
        if inflection_suffix_kind == :er || inflection_suffix_kind == :est
          unless morph_base_allows_comparative_er_est?(base, w, pos_map, base_prons&.first, forms_map, wf)
            dict_trace_puts(w, "Phase11 ← #{base}: skip (:er/:est not allowed)") if tr
            next
          end
        end
        if wf >= WORDFREQ_COMMON_ZIPF
          dict_trace_puts(w, "Phase11 ← #{base}: skip (Zipf #{wf} ≥ #{WORDFREQ_COMMON_ZIPF})") if tr
          next
        end
        base_zipf = wordfreq_hash[base] || 0
        if donor > RARE_FREQ_MAX && base_zipf < WORDFREQ_COMMON_ZIPF && !inflection_surface_reference_attested?(w, subtlex_hash, wordfreq_hash, cmudict_orig, ref_cn, ref_nb, ref_usf)
          dict_trace_puts(w, "Phase11 ← #{base}: skip (not in wordfreq/SUBTLEX/WN/CMU/USF/CN/NB; base Zipf #{base_zipf} < #{WORDFREQ_COMMON_ZIPF})") if tr
          next
        end
        if inflection_suffix_kind == :s
          unless hash.key?(w)
            dict_trace_puts(w, "Phase11 ← #{base}: skip (:s branch, not in hash)") if tr
            next
          end
          if wn_base_has_verb?(base)
            dict_trace_puts(w, "Phase11 ← #{base}: skip (:s branch, base has verb)") if tr
            next
          end
          if hash[w][0] > RARE_FREQ_MAX
            dict_trace_puts(w, "Phase11 ← #{base}: skip (:s branch, freq already high)") if tr
            next
          end
          unless corpus_ok || lexical_plural_ok
            dict_trace_puts(w, "Phase11 ← #{base}: skip (:s branch, corpus gates)") if tr
            next
          end
          hash[w][0] = donor
          if hash[w][1].empty?
            promo = morph_derived_prons_for_promotion(base_prons, base, w)
            hash[w][1] = promo unless promo.empty?
          end
          dict_trace_puts(w, "Phase11 ← #{base}: set freq=#{donor} (:s plural path)") if tr
        elsif corpus_ok
          if hash.key?(w)
            if hash[w][0] > RARE_FREQ_MAX
              dict_trace_puts(w, "Phase11 ← #{base}: skip (corpus path, existing freq high)") if tr
              next
            end
            hash[w][0] = donor
            if hash[w][1].empty?
              promo = morph_derived_prons_for_promotion(base_prons, base, w)
              hash[w][1] = promo unless promo.empty?
            end
            dict_trace_puts(w, "Phase11 ← #{base}: set freq=#{donor} suffix=#{inflection_suffix_kind} (existing row)") if tr
          else
            hash[w] = [donor, morph_derived_prons_for_promotion(base_prons, base, w)]
            dict_trace_puts(w, "Phase11 ← #{base}: new row freq=#{donor} suffix=#{inflection_suffix_kind}") if tr
          end
        else
          dict_trace_puts(w, "Phase11 ← #{base}: skip (not :s and !corpus_ok)") if tr
          next
        end
        round += 1
        morph_corpus += 1
      end
    end
    break if round == 0
  end
  puts "#{morph_corpus} morphological extensions from strong-corpus bases (not in common_words list)" if morph_corpus > 0

  strip_gdrop_bare_homographs!(hash, cmudict_orig)

  forbidden_scrub = 0
  hash.keys.each do |word|
    next unless explicitly_forbidden?(word)
    hash.delete(word)
    forbidden_scrub += 1
  end
  puts "#{forbidden_scrub} explicitly forbidden surface forms removed after frequency phases" if forbidden_scrub > 0

  hyp_edge = delete_headwords_with_edge_hyphen!(hash)
  puts "#{hyp_edge} headwords with a leading or trailing '-' removed after frequency phases" if hyp_edge > 0

  puts "#{count + extra + common_extra + floor_applied + inherited + cw_inherited + morph_inherited + morph_corpus} total entries with frequency data"
  return hash
end

def build_word_dict(cmudict, rdict, subtlex_hash, wordfreq_hash, wiktionary_words, pos_map, forms_map, kaikki_verb_morph = nil, original_cmudict_headwords = nil)
  cmudict = filter_cmudict(cmudict, rdict)
  word_dict = add_frequency_info(cmudict, subtlex_hash, wordfreq_hash, wiktionary_words, pos_map, forms_map, kaikki_verb_morph, original_cmudict_headwords)
  word_dict = filter_word_dict(word_dict)
  merge_word_dict_pronunciations_into_rdict!(rdict, word_dict)
  delete_rare_only_rime_buckets!(rdict, word_dict)
  filter_word_dict_disconnected!(word_dict, rdict, subtlex_hash, wordfreq_hash, pos_map, forms_map, original_cmudict_headwords, wiktionary_words)
  word_dict
end
