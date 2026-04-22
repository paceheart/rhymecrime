# encoding: utf-8
# Derives pronunciations for inflected word forms from a base pronunciation.
# Uses English suffix phonology rules to append the correct phonemes.

require "set"
require "rwordnet"
require_relative "pronunciation"

module Inflect
  VOICELESS = Set.new(%w[P T K F TH S SH CH])
  SIBILANTS = Set.new(%w[S Z SH ZH CH JH])

  # Closed-class English number lemmas (1–10): block *+er* / *+est* bleed (*eighter*, …).
  ENGLISH_CARDINAL_ONE_TO_TEN = /\A(one|two|three|four|five|six|seven|eight|nine|ten)\z/i

  # Given a base word's Pronunciation and the inflected spelling,
  # detect which suffix was added and return a new Pronunciation
  # with the appropriate phonemes appended. Returns nil if the
  # suffix can't be determined or doesn't apply.
  def self.derive(base_pron, base_word, inflected_word)
    return nil if base_pron.nil? || base_pron.empty?

    base_phonemes = base_pron.phonemes.each_with_object([]) { |p, a| a << p unless p == "." }
    return nil if base_phonemes.empty?

    suffix = match_suffix_kind(base_word, inflected_word)
    return nil if suffix.nil?

    final = base_phonemes.last
    final_bare = Phoneme.bare_base(final)

    new_phonemes = case suffix
    when :s
      if SIBILANTS.include?(final_bare)
        base_phonemes + ["IH0", "Z"]
      elsif VOICELESS.include?(final_bare)
        base_phonemes + ["S"]
      else
        base_phonemes + ["Z"]
      end
    when :ed
      if final_bare == "T" || final_bare == "D"
        base_phonemes + ["IH0", "D"]
      elsif VOICELESS.include?(final_bare)
        base_phonemes + ["T"]
      else
        base_phonemes + ["D"]
      end
    when :ing
      trimmed = trim_for_ing(base_phonemes, base_word)
      trimmed + ["IH0", "NG"]
    when :er
      base_phonemes + ["ER0"]
    when :est
      base_phonemes + ["AH0", "S", "T"]
    else
      nil
    end

    return nil if new_phonemes.nil?
    Pronunciation.new(new_phonemes)
  end

  # True if +inflected+ matches one of the English suffix patterns handled by +derive+
  # (+s+/+es+, +ed+, +ing+, +er+, +est+, y→ies, doubled consonant, etc.) for this +base+.
  def self.inflection_of_base?(base, inflected)
    return false if base.nil? || inflected.nil?
    return false if inflected.length < base.length
    !match_suffix_kind(base, inflected).nil?
  end

  # Possible morphological bases for +inflected+ before +inflection_of_base?+ filtering (small set).
  # Empty when no English suffix pattern applies — skips expensive WordNet work in +compute_lemma_map+.
  def self.raw_candidate_bases_for_inflected(inflected)
    il = inflected.bytesize
    return Set.new if il < 2

    cands = Set.new
    add_cand = lambda do |b|
      next if b.nil? || b.empty?

      shorter = b.bytesize < il
      same_len_ly = b.bytesize == il && match_suffix_kind(b, inflected) == :ly
      cands.add(b) if shorter || same_len_ly
    end

    # y → ies / ied / ier / iest
    if inflected.end_with?("iest") && il >= 5
      stem = inflected.byteslice(0, il - 4)
      add_cand.call(stem + "y") if stem.bytesize >= 1
    end
    %w[ies ied ier].each do |suf|
      next unless inflected.end_with?(suf) && il >= suf.bytesize + 1

      stem = inflected.byteslice(0, il - suf.bytesize)
      add_cand.call(stem + "y") if stem.bytesize >= 1
    end

    # silent trailing e → stem + ed / ing / er / est
    if inflected.end_with?("ed") && il >= 3
      stem = inflected.byteslice(0, il - 2)
      add_cand.call(stem + "e") if stem.bytesize >= 1
    end
    if inflected.end_with?("ing") && il >= 4
      stem = inflected.byteslice(0, il - 3)
      add_cand.call(stem + "e") if stem.bytesize >= 1
    end
    if inflected.end_with?("er") && il >= 3 && !inflected.end_with?("ier")
      stem = inflected.byteslice(0, il - 2)
      add_cand.call(stem + "e") if stem.bytesize >= 1
    end
    if inflected.end_with?("est") && il >= 4 && !inflected.end_with?("iest")
      stem = inflected.byteslice(0, il - 3)
      add_cand.call(stem + "e") if stem.bytesize >= 1
    end

    # consonant doubling undo (B + c + ed / ing / er / est)
    if inflected.end_with?("ed") && il >= 5 &&
        inflected.getbyte(il - 3) == inflected.getbyte(il - 4)
      add_cand.call(inflected.byteslice(0, il - 3))
    end
    if inflected.end_with?("ing") && il >= 6 &&
        inflected.getbyte(il - 4) == inflected.getbyte(il - 5)
      add_cand.call(inflected.byteslice(0, il - 4))
    end
    if inflected.end_with?("er") && il >= 5 && !inflected.end_with?("ier") &&
        inflected.getbyte(il - 3) == inflected.getbyte(il - 4)
      add_cand.call(inflected.byteslice(0, il - 3))
    end
    if inflected.end_with?("est") && il >= 6 && !inflected.end_with?("iest") &&
        inflected.getbyte(il - 4) == inflected.getbyte(il - 5)
      add_cand.call(inflected.byteslice(0, il - 4))
    end

    # deadjectival -ly (flawlessly→flawless; happily→happy) and -e→…ly (gently→gentle)
    if inflected.end_with?("ily") && il >= 6
      stem = inflected.byteslice(0, il - 3)
      add_cand.call(stem + "y") if stem.bytesize >= 1
    end
    if inflected.end_with?("ly") && il >= 4 && !inflected.end_with?("ily")
      # *gentle*→*gently*: drop final *y* and restore silent *e*. *flawlessly*→*flawless*: drop *ly*.
      stem_drop_y = inflected.byteslice(0, il - 1)
      add_cand.call(stem_drop_y + "e") if stem_drop_y.bytesize >= 2
      stem_drop_ly = inflected.byteslice(0, il - 2)
      add_cand.call(stem_drop_ly + "e") if stem_drop_ly.bytesize >= 1
      add_cand.call(stem_drop_ly) if stem_drop_ly.bytesize >= 2
    end
    # -ful (delightful→delight); min stem 3 and |word|≥6 skips *awful*→*aw*
    if inflected.end_with?("ful") && il >= 6
      stem = inflected.byteslice(0, il - 3)
      add_cand.call(stem) if stem.bytesize >= 3
    end

    # direct suffix after base
    if inflected.end_with?("s") && il >= 2
      add_cand.call(inflected.byteslice(0, il - 1))
    end
    if inflected.end_with?("es") && il >= 3
      add_cand.call(inflected.byteslice(0, il - 2))
    end
    if inflected.end_with?("ed") && il >= 3
      add_cand.call(inflected.byteslice(0, il - 2))
    end
    if inflected.end_with?("ing") && il >= 4
      add_cand.call(inflected.byteslice(0, il - 3))
    end
    if inflected.end_with?("er") && il >= 3
      add_cand.call(inflected.byteslice(0, il - 2))
    end
    if inflected.end_with?("est") && il >= 4
      add_cand.call(inflected.byteslice(0, il - 3))
    end

    # Colloquial g-drop: +fooin'+/+gluin'+/+stoppin'+/+tryin'+ share a base with
    # +fooing+/+gluing+/+stopping+/+trying+. Mirror the surface rule by recursing on
    # the reconstituted +-ing+ form (one level deep — the +-ing+ form no longer ends
    # in +in'+) and merging the candidates the +-ing+ case would have produced. Kept
    # as a recursion rather than copy-pasted case analysis so the silent-e / y-stem /
    # consonant-doubling branches stay authoritative in one place.
    if inflected.end_with?("in'") && il >= 4
      ing_form = inflected.byteslice(0, il - 3) + "ing"
      raw_candidate_bases_for_inflected(ing_form).each { |b| cands.add(b) }
    end

    cands
  end

  # Yields spellings derivable from +base+ by the same surface rules as +match_suffix_kind+
  # (forward direction only). Used to propagate frequency from high-frequency bases without
  # O(n²) “every rare word × every base” scans.
  # Yields base spellings +b+ such that +inflection_of_base?(b, inflected)+ (inverse of
  # +each_derivable_form+). Bounded small set per word; used to avoid Phase 9 O(|hash|×|common|).
  def self.each_candidate_base_for_inflected(inflected)
    return enum_for(__method__, inflected) unless block_given?

    cands = raw_candidate_bases_for_inflected(inflected)
    return if cands.empty?

    cands.each do |b|
      yield b if inflection_of_base?(b, inflected)
    end

    nil
  end

  def self.each_derivable_form(base)
    return if base.nil? || base.empty?

    bl = base.bytesize
    # Character length for [-1]/[-2] indexing (bytesize can be ≥2 while .length is 1, e.g. one UTF-8 letter).
    cl = base.length
    yield base + "s"
    # Plural -es attaches to the stem after silent-e (fox→foxes), not as base+"es" (annualizees junk).
    yield base + "es" unless base.end_with?("e") && !base.end_with?("ee")

    participle_like_ed = base.end_with?("ed") && cl >= 5
    irregular_wn_verb_surface = wn_irregular_verb_surface?(base)
    no_cmp_sup = participle_like_ed || irregular_wn_verb_surface || english_cardinal_one_to_ten?(base)
    skip_ed_ing = irregular_wn_verb_surface

    penult_vowel = cl >= 2 && base[-2].match?(/[aeiouy]/i)
    final_cons = !base[-1].match?(/\A[aeiouy]\z/i)
    cluster_final = base.match?(/[^aeiouy]{2}\z/i)
    long_double_letters = base.match?(/ee|oo/i)
    structural_double = penult_vowel && final_cons && !cluster_final && !long_double_letters
    lc = base[-1]

    lemma_memo = {}
    lemma = lambda do |w|
      lemma_memo[w] = wn_lemma?(w) unless lemma_memo.key?(w)
      lemma_memo[w]
    end

    adj_memo = {}
    adj_roots = lambda do |w|
      adj_memo[w] = wn_adj_morphy_list(w) unless adj_memo.key?(w)
      adj_memo[w]
    end
    adj_roots_nonempty = lambda do |w|
      !adj_roots[w].empty?
    end

    only_doubled_ed = structural_double && !lemma[base + "ed"] && lemma[base + lc + "ed"]

    suppress_simple = lambda do |kind|
      case kind
      when :ed
        return true if skip_ed_ing
        if structural_double
          return true if !lemma[base + "ed"] && lemma[base + lc + "ed"]
          return true if !lemma[base + "er"] && lemma[base + lc + "er"] && !lemma[base + "ed"]
        end
        false
      when :ing
        return true if skip_ed_ing
        if structural_double
          return true if !lemma[base + "ing"] && lemma[base + lc + "ing"]
          return true if !lemma[base + "er"] && lemma[base + lc + "er"] && !lemma[base + "ing"]
        end
        false
      when :er
        if structural_double
          return true if !lemma[base + "er"] && lemma[base + lc + "er"]
          return true if only_doubled_ed && !lemma[base + "er"] && !lemma[base + lc + "er"]
        end
        false
      when :est
        if structural_double
          se = base + "est"
          de = base + lc + "est"
          sr = adj_roots[se].sort
          dr = adj_roots[de].sort
          # *squatest* / *flatest* / *fatest*: undoubled and doubled superlatives share the same adj roots → keep doubled only.
          return true if sr.any? && sr == dr
          # *splitest*: adj morphy ties the surface to this lemma but there is no lexical row — doubled *splittest* is suppressed separately.
          roots_se = adj_roots[se]
          return true if roots_se.any? && roots_se.include?(base) && !lemma[se]
          return true if !lemma[base + "est"] && lemma[base + lc + "est"]
          return true if only_doubled_ed && !lemma[base + "est"] && !lemma[base + lc + "est"]
        end
        false
      else
        false
      end
    end

    suppress_doubled = lambda do |kind|
      return false unless structural_double
      case kind
      when :ed
        lemma[base + "ed"] && !lemma[base + lc + "ed"]
      when :ing
        lemma[base + "ing"] && !lemma[base + lc + "ing"]
      when :er
        s = base + "er"
        d = base + lc + "er"
        (lemma[s] && !lemma[d]) || (!lemma[s] && !lemma[d] && adj_roots_nonempty[s] && !adj_roots_nonempty[d])
      when :est
        s = base + "est"
        d = base + lc + "est"
        (lemma[s] && !lemma[d]) || (!lemma[s] && !lemma[d] && adj_roots_nonempty[s] && !adj_roots_nonempty[d])
      else
        false
      end
    end

    skip_y_cmp_sup = lambda do
      return true if bl >= 8 && base.end_with?("y")
      return true if base.end_with?("way") && bl >= 5
      return true if base == "nearby"

      false
    end

    if base.end_with?("y") && bl >= 2
      stem = base.byteslice(0, bl - 1)
      yield stem + "ies"
      yield stem + "ied"
      unless skip_y_cmp_sup.call
        # *straier* / *canarier* / *eightier*: if *base+er* / *base+est* analyze as the adjective but *stem+ier* / *stem+iest* do not, keep *strayer* / *eightyer*-style forms only.
        plain_er = base + "er"
        plain_est = base + "est"
        unless adj_roots_nonempty[plain_er] && !adj_roots_nonempty[stem + "ier"]
          yield stem + "ier"
        end
        unless adj_roots_nonempty[plain_est] && !adj_roots_nonempty[stem + "iest"]
          yield stem + "iest"
        end
      end
    end

    if base.end_with?("e") && bl >= 2 && !base.end_with?("ee")
      stem = base.byteslice(0, bl - 1)
      yield stem + "ed" unless skip_ed_ing
      yield stem + "ing" unless skip_ed_ing
      unless no_cmp_sup
        yield stem + "er"
        yield stem + "est"
      end
    else
      yield base + "ed" unless suppress_simple.call(:ed)
      yield base + "ing" unless suppress_simple.call(:ing)
      unless no_cmp_sup
        yield base + "er" unless suppress_simple.call(:er)
        yield base + "est" unless suppress_simple.call(:est)
      end
    end

    # Consonant doubling (stop→stopped). Skip:
    # - vowel-final bases (annualize+e+ed junk)
    # - final consonant cluster (*faint*→*fainttest*, *blank*→*blankker*)
    # - *ee* / *oo* in the spelling (*fleet*→*fleetter*, *need*→*needded*)
    # - WordNet says only the undoubled spelling is attested (*edited* vs *editted*)
    if cl >= 2 && !no_cmp_sup && structural_double
      unless lc.match?(/\A[aeiouy]\z/i)
        skip_er_est_double = suppress_doubled.call(:ed)
        yield base + lc + "ed" unless suppress_doubled.call(:ed)
        yield base + lc + "ing" unless suppress_doubled.call(:ing)
        yield base + lc + "er" unless suppress_doubled.call(:er) || skip_er_est_double
        yield base + lc + "est" unless suppress_doubled.call(:est) || skip_er_est_double
      end
    end

    nil
  end

  # Colloquial g-dropped spelling *…in'* from verbal *…ing* and the same +base+ as +match_suffix_kind+.
  # Returns nil unless +ing_w+ is the canonical Inflect participle of +base+ (same cases as +:ing+).
  def self.gdropped_in_apostrophe_spelling(base, ing_w)
    return nil unless inflection_of_base?(base, ing_w)
    return nil unless match_suffix_kind(base, ing_w) == :ing

    bl = base.bytesize
    il = ing_w.bytesize

    if base.end_with?("y") && bl >= 2
      stem = base.byteslice(0, bl - 1)
      return stem + "yin'" if ing_w == stem + "ying"
    end

    if base.end_with?("e") && bl >= 2 && !base.end_with?("ee")
      stem = base.byteslice(0, bl - 1)
      return stem + "in'" if ing_w == stem + "ing"
    end

    return nil unless ing_w.start_with?(base)
    rest = ing_w.byteslice(bl, il - bl)
    return base + "in'" if rest == "ing"

    if bl >= 2 && il == bl + 1 + 3 && ing_w.end_with?("ing") && ing_w.getbyte(bl) == base.getbyte(bl - 1)
      return base + base[-1] + "in'"
    end

    nil
  end

  def self.configure_wordnet_db_path!
    return if defined?(@@wordnet_db_path_configured) && @@wordnet_db_path_configured

    @@wordnet_db_path_configured = true
    return unless defined?(WordNet::DB)

    if WordNet::DB.path.nil? || WordNet::DB.path.to_s.empty?
      WordNet::DB.path = File.expand_path("../../../corpora/wordnet/3.1", __dir__)
    end
  rescue StandardError
    nil
  end

  def self.wn_lemma?(word)
    configure_wordnet_db_path!
    return false unless defined?(WordNet::Lemma)

    p = WordNet::DB.path
    return false if p.nil? || p.to_s.empty?

    !WordNet::Lemma.find_all(word.to_s.downcase).empty?
  rescue StandardError
    false
  end

  def self.wn_verb_morph_stems(base)
    configure_wordnet_db_path!
    return [] unless defined?(WordNet::Synset)

    p = WordNet::DB.path
    return [] if p.nil? || p.to_s.empty?

    (WordNet::Synset.morphy(base.to_s.downcase, "verb") || []).uniq
  rescue StandardError
    []
  end

  # True when WordNet's verb analyzer maps this surface to exactly one different lemma (e.g. *born*→*bear*).
  # Suppresses junk *+ed* / *+ing* / *+er* / *+est* from that surface without maintaining a word list.
  def self.wn_irregular_verb_surface?(base)
    stems = wn_verb_morph_stems(base)
    stems.size == 1 && stems.first != base
  end

  def self.english_cardinal_one_to_ten?(base)
    !!(base =~ ENGLISH_CARDINAL_ONE_TO_TEN)
  end

  # Adjective morphy roots for +word+ (empty when WordNet has no adj analysis). Used to gate *-er/-est* doubling and *y→ier*.
  def self.wn_adj_morphy_list(word)
    configure_wordnet_db_path!
    return [] unless defined?(WordNet::Synset)

    p = WordNet::DB.path
    return [] if p.nil? || p.to_s.empty?

    (WordNet::Synset.morphy(word.to_s.downcase, "adj") || []).uniq
  rescue StandardError
    []
  end

  private

  # Returns :s, :ed, :ing, :er, :est, :ly, :ful, or nil. Shared by +derive+ and +inflection_of_base?+.
  # Ordered for cheap rejects: length, y/silent-e, then byte-wise rest (avoid stem+suffix string temps).
  def self.match_suffix_kind(base, inflected)
    bl = base.bytesize
    il = inflected.bytesize
    return nil if il < bl

    # --- y → ies / ied / ier / iest (does not start_with?(base)) ---
    if base.end_with?("y") && bl >= 2
      stem = base.byteslice(0, bl - 1)
      if il == bl + 2 && inflected.start_with?(stem)
        return :ly if inflected.end_with?("ily")
        return :s if inflected.end_with?("ies")
        return :ed if inflected.end_with?("ied")
        return :er if inflected.end_with?("ier")
      elsif il == bl + 3 && inflected.start_with?(stem) && inflected.end_with?("iest")
        return :est
      end
    end

    # --- silent trailing e → stem + ed/ing/er/est; stem + y (gentle→gently) ---
    if base.end_with?("e") && bl >= 2 && !base.end_with?("ee")
      stem = base.byteslice(0, bl - 1)
      if inflected.start_with?(stem)
        if il == bl && inflected == stem + "y"
          return :ly
        elsif il == bl + 1
          return :ed if inflected.end_with?("ed")
          return :er if inflected.end_with?("er")
        elsif il == bl + 2
          return :ing if inflected.end_with?("ing")
          return :est if inflected.end_with?("est")
        end
      end
    end

    # --- direct suffix after base ---
    return nil unless inflected.start_with?(base)

    rest_len = il - bl
    # annualize+es→annualizees is not English; real plural is annualize+s (annualizes).
    if rest_len == 2 &&
        base.end_with?("e") && !base.end_with?("ee") &&
        inflected.getbyte(bl) == 101 && inflected.getbyte(bl + 1) == 115 # "es"
      return nil
    end

    case rest_len
    when 1
      return :s if inflected.getbyte(bl) == 115 # "s"
    when 2
      b0 = inflected.getbyte(bl)
      b1 = inflected.getbyte(bl + 1)
      if b0 == 101 && b1 == 115
        return :s
      end
      return :ed if b0 == 101 && b1 == 100
      return :er if b0 == 101 && b1 == 114
      return :ly if b0 == 108 && b1 == 121 # "ly"
    when 3
      return :ing if inflected.end_with?("ing")
      return :est if inflected.end_with?("est")
      return :ful if inflected.end_with?("ful")
    end

    # --- consonant doubling: stop → stopped / stopping / stopper / stoppest ---
    return nil if bl < 2
    doubled = base.getbyte(bl - 1)
    return nil unless inflected.getbyte(bl) == doubled

    return :ed if inflected.end_with?("ed") && il == bl + 1 + 2
    return :ing if inflected.end_with?("ing") && il == bl + 1 + 3
    return :er if inflected.end_with?("er") && il == bl + 1 + 2
    return :est if inflected.end_with?("est") && il == bl + 1 + 3

    nil
  end

  # For -ing, if the base word ends in a silent-e pattern (e.g., "dance" -> "dancing"),
  # the final schwa from the -e may need to be removed.
  # For consonant doubling cases (e.g., "stop" -> "stopping"), no trim needed.
  def self.trim_for_ing(phonemes, base_word)
    return phonemes unless base_word.end_with?("e") && !base_word.end_with?("ee")

    if phonemes.length >= 2
      second_last = phonemes[-2].tr("0-2", "")
      last = phonemes[-1].tr("0-2", "")
      # If word ends in consonant (like "dance" = D AE1 N S), keep as-is
      # If word ends in vowel+consonant pattern from silent-e, keep as-is
      # The silent-e doesn't add a phoneme in most cases, so no trim needed
    end
    phonemes
  end
end
