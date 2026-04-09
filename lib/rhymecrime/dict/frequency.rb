# encoding: utf-8
# SUBTLEX / wordfreq I/O, compute_frequency, add_frequency_info phases, filter_word_dict, build_word_dict.

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
      if(word == TRACE_WORD)
        puts "TRACE freq #{freq} passed filters"
      end
    end
  end
  puts "#{filtered_word_dict.length} out of #{word_dict.length} entries remain in the dictionary after removing words with no rhymes and zero frequency"
  return filtered_word_dict
end
def compute_frequency(word, subtlex_hash, wordfreq_hash)
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

  if(word == TRACE_WORD)
    puts "TRACE compute_frequency: subtlex=#{subtlex_freq} zipf=#{zipf} wordfreq_boost=#{wordfreq_boost} block_short_init=#{block_short_initialism_wordfreq} all_proper=#{wn_all_proper} => #{freq}"
  end
  return freq
end

def add_frequency_info(cmudict, subtlex_hash, wordfreq_hash, wiktionary_words, pos_map, forms_map)
  count = 0
  hash = Hash.new
  rare_words = IO.readlines(RARE_WORDS_FILENAME, chomp: true, encoding: 'UTF-8')
  common_words = IO.readlines(COMMON_WORDS_FILENAME, chomp: true, encoding: 'UTF-8')
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

  # Phase 7: Hyphenated word existence floor.
  # SUBTLEX and wordfreq tokenize on hyphens, so hyphenated words systematically score 0.
  # Grant floor when the compound is attested (Wiktionary headword or WordNet MWE) and
  # the final segment is not independently useful for rhyming: no WordNet lemma, and raw SUBTLEX < 12.
  # Skip inflected forms of hyphenated bases — those are handled by Phase 8 (or blocked).
  hyp_floor = 0
  hash.each do |word, entry|
    next if entry[0] > RARE_FREQ_MAX
    next if rare_words.include?(word)
    next unless word.include?('-')
    next if $inflection_base_words.key?(word) && $inflection_base_words[word].include?('-')
    next unless wiktionary_words.include?(word) || wn_has_entry?(word)
    final = word.split('-').last
    next if wn_has_entry?(final)
    next if subtlex_hash[final] >= 12
    entry[0] = 5
    hyp_floor += 1
  end
  puts "#{hyp_floor} hyphenated words received existence floor" if hyp_floor > 0

  # Phase 8: frequency inheritance for inflected forms.
  # Inherit from any common base word. Skip only when wordfreq shows the inflection itself
  # as independently common (Zipf >= COMMON); a mere corpus key with low Zipf still inherits
  # (yeeted, twerks) so slang bases propagate.
  # Skip -ing → base when WordNet has the base but only as noun/adj/etc.: prevents
  # spurious "kitchening" inheriting from "kitchen" (FP-4). Verbal -ing still inherits
  # when the base has a verb lemma, or when the base is absent from WordNet (slang).
  inherited = 0
  $inflection_base_words.each do |inflected, base|
    next unless hash.key?(inflected)
    next if hash[inflected][0] > 0
    # Do not copy frequency from hyphenated base to hyphenated inflection (hoity-toity → hoity-toities).
    next if inflected.include?("-") && base.include?("-")
    base_freq = hash.key?(base) ? hash[base][0] : 0
    next unless base_freq > RARE_FREQ_MAX
    wf_inf = wordfreq_hash[inflected]
    next if wf_inf && wf_inf >= WORDFREQ_COMMON_ZIPF
    inflection_suffix_kind = Inflect.send(:match_suffix_kind, base, inflected)
    next if inflection_suffix_kind == :s && !morph_base_allows_plural_s?(base, pos_map, forms_map, inflected)
    zf_w = wordfreq_hash[inflected] || 0
    next if (inflection_suffix_kind == :ed || inflection_suffix_kind == :ing) && !morph_base_allows_verb_forms?(base, inflected, pos_map, forms_map, zf_w, wordfreq_hash)
    if inflection_suffix_kind == :er || inflection_suffix_kind == :est
      base_p0 = hash[base]&.dig(1)&.first
      next unless morph_base_allows_comparative_er_est?(base, inflected, pos_map, base_p0, forms_map, zf_w)
    end
    hash[inflected][0] = base_freq
    inherited += 1
  end
  puts "#{inherited} inflected forms inherited frequency from base words" if inherited > 0

  # Phase 9: suffix inheritance from common_words.txt (Inflect spelling patterns).
  # Phase 8 only fills entries with frequency 0; listed headwords still leave plurals / -ing, etc.
  # in the rare bins (1..RARE_FREQ_MAX). Match forward (listed + suffix = word) or reverse (word + suffix = listed,
  # e.g. regionalize… ← regionalized). Structural junk guards only; list headwords skip Kaikki verb
  # attestation (see +list_authoritative_base+ on +morph_base_allows_verb_forms?+).
  cw_sorted = common_words.uniq.sort_by { |b| -b.length }
  cw_inherited = 0
  # Multiple rounds: e.g. regionalized → regionalize → regionalizing in one build.
  loop do
    round = 0
    hash.each do |word, entry|
      next if entry[0] > RARE_FREQ_MAX
      next if rare_words.include?(word)
      cw_sorted.each do |listed|
        next if listed == word
        forward = Inflect.inflection_of_base?(listed, word)
        reverse = !forward && Inflect.inflection_of_base?(word, listed)
        next unless forward || reverse
        base, infl = forward ? [listed, word] : [word, listed]
        inflection_suffix_kind = Inflect.send(:match_suffix_kind, base, infl)
        next if inflection_suffix_kind.nil?
        wf_infl = wordfreq_hash[infl] || 0
        next if inflection_suffix_kind == :s && !morph_base_allows_plural_s?(base, pos_map, forms_map, infl)
        list_auth = common_words.include?(base)
        next if (inflection_suffix_kind == :ed || inflection_suffix_kind == :ing) && !morph_base_allows_verb_forms?(base, infl, pos_map, forms_map, wf_infl, wordfreq_hash, list_authoritative_base: list_auth)
        if inflection_suffix_kind == :er || inflection_suffix_kind == :est
          base_p0 = hash[base]&.dig(1)&.first
          next unless morph_base_allows_comparative_er_est?(base, infl, pos_map, base_p0, forms_map, wf_infl)
        end
        listed_freq = hash.key?(listed) ? hash[listed][0] : 0
        donor = listed_freq > RARE_FREQ_MAX ? listed_freq : 99
        entry[0] = donor
        round += 1
        cw_inherited += 1
        break
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
      next unless bent && bent[0] > RARE_FREQ_MAX
      next unless common_words.include?(base)
      next if stop_word?(base)
      next if rare_words.include?(base)
      next if base.include?("-")
      donor = bent[0] > RARE_FREQ_MAX ? bent[0] : 99
      base_prons = bent[1]
      Inflect.each_derivable_form(base) do |w|
        next if w == base
        next if w.include?("-")
        next if rare_words.include?(w)
        next unless Inflect.inflection_of_base?(base, w)
        inflection_suffix_kind = Inflect.send(:match_suffix_kind, base, w)
        wf = wordfreq_hash[w] || 0
        next if inflection_suffix_kind == :s && !morph_base_allows_plural_s?(base, pos_map, forms_map, w)
        next if (inflection_suffix_kind == :ed || inflection_suffix_kind == :ing) && !morph_base_allows_verb_forms?(base, w, pos_map, forms_map, wf, wordfreq_hash)
        if inflection_suffix_kind == :er || inflection_suffix_kind == :est
          next unless morph_base_allows_comparative_er_est?(base, w, pos_map, base_prons&.first, forms_map, wf)
        end
        next if wf >= WORDFREQ_COMMON_ZIPF
        if hash.key?(w)
          next if hash[w][0] > RARE_FREQ_MAX
          hash[w][0] = donor
          if hash[w][1].empty?
            promo = morph_derived_prons_for_promotion(base_prons, base, w)
            hash[w][1] = promo unless promo.empty?
          end
        else
          hash[w] = [donor, morph_derived_prons_for_promotion(base_prons, base, w)]
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
      next if common_words.include?(base)
      next if base.include?("-")
      bent = hash[base]
      next unless bent && bent[0] > RARE_FREQ_MAX
      next if stop_word?(base) || rare_words.include?(base)
      next if base.bytesize < 5
      sub_raw = subtlex_hash[base] || 0
      corpus_ok = sub_raw >= MORPH_CORPUS_SUBTLEX_MIN
      lexical_plural_ok = wn_has_entry?(base) && !wn_base_has_verb?(base) &&
        sub_raw >= MORPH_LEXICAL_NOUN_PLURAL_SUBTLEX_MIN
      next unless corpus_ok || lexical_plural_ok
      donor = bent[0] > RARE_FREQ_MAX ? bent[0] : 99
      base_prons = bent[1]
      Inflect.each_derivable_form(base) do |w|
        next if w == base || w.include?("-") || rare_words.include?(w)
        next unless Inflect.inflection_of_base?(base, w)
        inflection_suffix_kind = Inflect.send(:match_suffix_kind, base, w)
        next unless inflection_suffix_kind
        wf = wordfreq_hash[w] || 0
        next if inflection_suffix_kind == :s && !morph_base_allows_plural_s?(base, pos_map, forms_map, w)
        next if (inflection_suffix_kind == :ed || inflection_suffix_kind == :ing) && !morph_base_allows_verb_forms?(base, w, pos_map, forms_map, wf, wordfreq_hash)
        if inflection_suffix_kind == :er || inflection_suffix_kind == :est
          next unless morph_base_allows_comparative_er_est?(base, w, pos_map, base_prons&.first, forms_map, wf)
        end
        next if wf >= WORDFREQ_COMMON_ZIPF
        if inflection_suffix_kind == :s
          next unless hash.key?(w)
          next if wn_base_has_verb?(base)
          next if hash[w][0] > RARE_FREQ_MAX
          next unless corpus_ok || lexical_plural_ok
          hash[w][0] = donor
          if hash[w][1].empty?
            promo = morph_derived_prons_for_promotion(base_prons, base, w)
            hash[w][1] = promo unless promo.empty?
          end
        elsif corpus_ok
          if hash.key?(w)
            next if hash[w][0] > RARE_FREQ_MAX
            hash[w][0] = donor
            if hash[w][1].empty?
              promo = morph_derived_prons_for_promotion(base_prons, base, w)
              hash[w][1] = promo unless promo.empty?
            end
          else
            hash[w] = [donor, morph_derived_prons_for_promotion(base_prons, base, w)]
          end
        else
          next
        end
        round += 1
        morph_corpus += 1
      end
    end
    break if round == 0
  end
  puts "#{morph_corpus} morphological extensions from strong-corpus bases (not in common_words list)" if morph_corpus > 0

  forbidden_scrub = 0
  hash.keys.each do |word|
    next unless explicitly_forbidden?(word)
    hash.delete(word)
    forbidden_scrub += 1
  end
  puts "#{forbidden_scrub} explicitly forbidden surface forms removed after frequency phases" if forbidden_scrub > 0

  hyp_edge = delete_headwords_with_edge_hyphen!(hash)
  puts "#{hyp_edge} headwords with a leading or trailing '-' removed after frequency phases" if hyp_edge > 0

  puts "#{count + extra + common_extra + floor_applied + hyp_floor + inherited + cw_inherited + morph_inherited + morph_corpus} total entries with frequency data"
  return hash
end

def build_word_dict(cmudict, rdict, subtlex_hash, wordfreq_hash, wiktionary_words, pos_map, forms_map)
  cmudict = filter_cmudict(cmudict, rdict)
  word_dict = add_frequency_info(cmudict, subtlex_hash, wordfreq_hash, wiktionary_words, pos_map, forms_map)
  return filter_word_dict(word_dict)
end
