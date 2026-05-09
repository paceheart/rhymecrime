# coding: utf-8

def filter_out_prefix_words(words, focal_word)
  return words - prefix_words(words, focal_word)
end

# After stripping prefix (non, anti, …), hyphenated forms yield -rest (-alcoholic → alcoholic).
def lexical_root_after_prefix(word, prefix)
  return nil unless word.start_with?(prefix)
  word[prefix.length..-1].sub(/\A-+/, "")
end

# Words in WORDS that share a COMMON_PREFIXES derivation with FOCAL_WORD. A candidate is
# filtered when it shares a recursive-prefix-strip ancestor with focal AND both phonologically
# end with that ancestor's pronunciation (with consonants strict, unstressed vowels relaxed).
#
#   1. Ancestor sets (recursive_prefix_ancestors) walk COMMON_PREFIXES at each step so
#      compound shapes like +in+sub-+ in insubordinate collapse to ordinate without
#      enumerating insub- in the prefix list. Captures both the "candidate strips to
#      focal" case (insubordinate → ordinate) and the "shared root" case (unable and
#      disable both → able) — the latter is what the old focal_roots seeding
#      handled. Depth-bounded; restricted to lexicon entries so non-word artifacts of
#      over-stripping (a- off able → ble) don't poison the intersection.
#
#   2. Phonological-suffix alignment (pron_suffix_aligned?) requires each side's flat
#      ARPAbet to end with the common ancestor's, consonants and primary-stressed vowels
#      strict, unstressed vowels relaxed (disenchanted's AH0 N tail matches enchanted's
#      EH0 N — morphological vowel reduction at the prefix-stem boundary). The pron gate
#      is what makes the recursion safe: +un+de+served+ orthographically peels to served,
#      but undeserved's tail is Z AH1 R V D vs served's S AH1 R V D — the de- →
#      /d ɪ z/ shift before voiced-onset roots breaks the consonant frame, so the gate
#      (and therefore the filter) declines.
#
# Opaque/etymologically-prefixed words that modern speakers don't perceive as derivational
# (record = re+cord, ajar = a+jar, abasement = a+basement) still suffix-align
# phonologically and are accepted as splash damage. The S→Z onset shift in deserve /
# serve used to be splash damage too; the pron gate now lets that pair through. See
# rhyme_spec.rb for the working/skipped split.
#
# Tails that, when shared as a recursive-prefix-strip ancestor between two
# prefixed siblings (neither of which IS the bare tail), should NOT trigger
# the prefix-words filter. The motivating family is the Greek-instrument
# /-ˈɒm.ɪ.tər/ stress-shifted -meter compounds (thermometer, barometer,
# speedometer, odometer, micrometer-the-instrument, kilometer in its
# stress-shifted variant K AH0 L AA1 M AH0 D AH0 R). These all collapse
# to the AA_M_AH_D_AH_R rime cohort and rhyme as siblings even though they
# all peel to meter via COMMON_PREFIXES. The front-stress SI compounds
# (centimeter, millimeter, nanometer) live in different rime buckets so
# the carve-out is moot for them — they never reach prefix_words for any
# Greek-instrument relative. The carve-out is gated on neither side BEING
# the bare tail so that meter↔thermometer (and meter↔kilometer) still
# filter cleanly. The set is intentionally narrow; extend it only when a
# fresh sibling-rhyme family with comparable stress behavior shows up.
PREFIX_FILTER_SIBLING_ANCHOR_TAILS = %w[meter metre].to_set.freeze

def prefix_words(words, focal_word)
  focal_ancestors = recursive_prefix_ancestors(focal_word)
  result = words.select do |w|
    next false if w == focal_word
    candidate_ancestors = recursive_prefix_ancestors(w)
    common = focal_ancestors & candidate_ancestors
    next false if common.empty?
    common = common.reject do |anc|
      PREFIX_FILTER_SIBLING_ANCHOR_TAILS.include?(anc) &&
        focal_word != anc && w != anc
    end
    next false if common.empty?
    focal_bases = lexicon_word_prefix_allow_bases(focal_word)
    cand_bases  = lexicon_word_prefix_allow_bases(w)
    common.any? do |anc|
      # word_dict optional column: classifier-allowed (word, base) prefix pairs.
      # Bypass only when the *other* headword is the bare shared ancestor (anc),
      # not when both sides are prefixed siblings (e.g. bisect/intersect both peel
      # to sect but ought_not_rhyme; sect/intersect oughta_rhyme with inter,sect allow).
      if focal_bases || cand_bases
        bypass =
          (focal_bases&.include?(anc) && w == anc) ||
          (cand_bases&.include?(anc) && focal_word == anc)
        next false if bypass
      end
      pron_suffix_aligned_or_equal?(focal_word, anc) &&
        pron_suffix_aligned_or_equal?(w, anc)
    end
  end
  debug "Filtering out prefix words #{result} from #{words}" unless result.empty?
  result
end

# Set of forms reachable by recursively peeling COMMON_PREFIXES — and now also leading
# dict-headword compound modifiers (business + person) and hyphenated leading words
# (same-sex) — from word. Always includes word itself. Depth-bounded: the deepest
# legitimate English chain is ~3 (+dis+en+chanted+, +in+sub+ordinate+); ≤4 leaves headroom
# for as-yet-unseen compounds without risk of pathological recursion on words like
# nonconcomitant where many prefixes happen to match the start.
#
# Three peel families:
#
#   * Single-prefix (COMMON_PREFIXES): re-orient → orient. Recurses only when the
#     stripped tail is a dict headword OR a morphologically-valid surface of one
#     (re-orienting → orienting where orienting isn't its own dict entry but is the
#     -ing form of dict-attested orient). Non-dict morphologically-valid forms are
#     added to the set but not recursed from — keeps the over-stripping artifact (a- off
#     able → ble) out of the recursion while letting two prefixed siblings converge
#     on a shared inflected root.
#
#   * Compound-modifier (businessperson → person): word = HEAD + REST where both
#     HEAD and REST are dict headwords (each ≥ 3 chars). Peels HEAD off and recurses
#     on REST. The pron-suffix-alignment gate downstream is what makes this safe for
#     sibling compounds with secondary-stressed shared elements (eyeball/highball both
#     peel to ball but eyeball's AA2 tail doesn't align with ball's primary
#     AO1 — different bare bases AND, post-strengthening, different stress —
#     so the filter declines).
#
#   * Hyphenated leading word (same-sex → sex): when word contains a hyphen and each
#     leading hyphen-segment is a dict headword, peel the leading segments and recurse on
#     the remainder. Covers same-sex, self-organizing (when it's in dict), etc.
#
# Phonological-suffix alignment (pron_suffix_aligned?) is the safety net for all three
# branches: requires each side's flat ARPAbet to end with the common ancestor's, with
# consonants strict, vowel bare-bases strict, and primary stress preserved (the shorter
# side's primary-stressed vowel must still carry primary stress at the same position in
# the longer side). Without the primary-stress preservation, sibling compounds where the
# shared element loses primary stress (handout's AW2 tail vs out's primary AW1)
# would over-filter. With it, only true compound-rhymes-of-the-same-element pairs
# (businessperson/layperson where both keep primary on per) get caught.
RECURSIVE_PREFIX_STRIP_MAX_DEPTH = 4

# Min char length for the HEAD in a compound-modifier peel. 4 excludes 3-char heads
# whose dict-membership is mostly opaque/etymological coincidences (+app+lied,
# +ant+agonize, +pig+ment, +hum+ble, +app+end) where the orthographic split has no
# real morphological status. Real 3-char compound modifiers used by the failing
# spec set (bio, lay) are routed through COMMON_PREFIXES instead. Real
# productive modifiers (business, council, thermo, same) are 4+ chars.
COMPOUND_MODIFIER_HEAD_MIN_LENGTH = 4

# Min char length for the REST (the tail recursed on) in a compound-modifier peel. 3 keeps
# -men, -sex, -out working as compound elements while excluding 1-2-char remainders
# that don't have their own pronunciation cohort.
COMPOUND_MODIFIER_REST_MIN_LENGTH = 3

def recursive_prefix_ancestors(word, depth = 0, set = nil)
  set ||= Set.new
  return set if depth >= RECURSIVE_PREFIX_STRIP_MAX_DEPTH
  return set if set.include?(word)
  set.add(word)

  COMMON_PREFIXES.each do |prefix|
    tail = lexical_root_after_prefix(word, prefix)
    next unless tail && !tail.empty?
    next if set.include?(tail)
    next unless prefix_ancestor_morpheme_like?(tail)
    if word_dict_includes_headword?(tail)
      recursive_prefix_ancestors(tail, depth + 1, set)
    elsif morphologically_valid_non_dict_form?(tail)
      set.add(tail)
    end
  end

  compound_modifier_remainders(word).each do |rest|
    next if set.include?(rest)
    next unless prefix_ancestor_morpheme_like?(rest)
    recursive_prefix_ancestors(rest, depth + 1, set)
  end

  hyphen_compound_remainders(word).each do |rest|
    next if set.include?(rest)
    next unless prefix_ancestor_morpheme_like?(rest)
    if word_dict_includes_headword?(rest)
      recursive_prefix_ancestors(rest, depth + 1, set)
    elsif morphologically_valid_non_dict_form?(rest)
      set.add(rest)
    end
  end

  set
end

# Minimum length for a pronunciation-less form to count as a morpheme-like
# ancestor. Pron-less surfaces fall back to pron_suffix_aligned?'s
# orthographic-suffix fallback, which matches by string suffix and so will
# happily call any common letter ending a "shared ancestor" — rest and
# best both end with the dict's contentless st abbreviation row,
# expressed and pressed both end with the inferred ssed form. Real
# pron-less morphological roots that need to survive are longer
# (plosion at 7 chars: indexed dict headword, no stored pron, anchors
# the explosion/implosion parallel-derivation collapse). 5 keeps that
# anchor while excluding both noise cases above.
PRONLESS_ANCESTOR_MIN_LENGTH = 5

def prefix_ancestor_morpheme_like?(form)
  return true unless pronunciations(form).empty?
  form.to_s.length >= PRONLESS_ANCESTOR_MIN_LENGTH
end

# True when form is a non-dict surface that an Inflect.raw_candidate_bases_for_inflected
# strip relates to a dict headword (orienting → orient, tensions → tension). Lets
# recursive_prefix_ancestors accept the stripped tail when two prefixed siblings
# (re-orienting, dis-orienting) converge on a real-but-not-stored inflected form.
# Excludes opaque non-derivational tails (+pre+fer → fer: no Inflect base in dict) so
# real-rhyme pairs (prefer/defer) aren't false-paired.
def morphologically_valid_non_dict_form?(form)
  return false if form.nil? || form.length < 3
  return false if word_dict_includes_headword?(form)
  Inflect.raw_candidate_bases_for_inflected(form).any? { |b| word_dict_includes_headword?(b) }
end

# Compound-modifier peels: word = HEAD + REST where HEAD is a non-rare dict
# headword of length ≥ COMPOUND_MODIFIER_HEAD_MIN_LENGTH whose pronunciation aligns
# phonologically with word's prefix, and REST is a dict headword of length
# ≥ COMPOUND_MODIFIER_REST_MIN_LENGTH. Returns the REST candidates. Skips
# hyphenated input — those go through hyphen_compound_remainders.
#
# Skips apostrophe-bearing input. In standard English orthography an apostrophe
# inside a "word" marks a contraction of an inflectional or function-word morpheme
# (verbal -in' for -ing, 'em for them, 'tis for it is, 'bout for
# about, o'clock for of the clock). Contractions are not free-standing
# lexical elements that combine into compounds. Without this guard, the 3-char
# -in' contraction (exactly COMPOUND_MODIFIER_REST_MIN_LENGTH, slipping past
# the size threshold that excludes the bare 2-char preposition in) gets treated
# as a compound REST: failin' falsely peels to fail + in', huffin' to
# huff + in', poopin' to poop + in', etc. The shared phantom in'
# ancestor then causes prefix_words to filter sibling -in' rhymes
# (failin'/wailin', huffin'/puffin', poopin'/scoopin') out of each
# other's preferred-rhyme lists. The substring rule is sufficient because
# substrings of an apostrophe-free word are themselves apostrophe-free.
#
# The rare-headword exclusion drops opaque-Latin compounds whose split words happen to
# be in dict only because they're corner-case headwords (juris in jurisprudence:
# freq=2, rare). The pron-prefix-alignment gate (with the same primary-stress
# preservation as phoneme_tail_match?) drops splits whose orthographic match isn't
# matched at the phonological level (complied's first 4 chars comp would split
# orthographically but comp's pron K AA1 M P doesn't align with complied's
# K AH0 M P — different vowel base). Both gates together leave the rule firing only
# on transparent productive compounds (+business+person+, +council+men+,
# +thermo+plastic+).
def compound_modifier_remainders(word)
  return [] if word.nil? || word.empty? || word.include?("-") || word.include?("'")
  result = []
  head_min = COMPOUND_MODIFIER_HEAD_MIN_LENGTH
  rest_min = COMPOUND_MODIFIER_REST_MIN_LENGTH
  return result if word.length < (head_min + rest_min)
  (head_min..(word.length - rest_min)).each do |split|
    head = word[0...split]
    rest = word[split..-1]
    next unless word_dict_includes_headword?(head)
    next unless word_dict_includes_headword?(rest)
    next if rare?(head)
    next unless pron_prefix_aligned_or_equal?(word, head)
    result << rest
  end
  result
end

# pron_prefix_aligned? but trivially true when word equals head (so a word counts
# as its own prefix for the same-word degenerate case).
def pron_prefix_aligned_or_equal?(word, head)
  return true if word == head
  pron_prefix_aligned?(word, head)
end

# Mirror of pron_suffix_aligned? for the leading edge: any flat ARPAbet pronunciation
# of longer starts with any of shorter's, with the same phoneme_tail_match?
# semantics (consonants strict, vowels by bare base, primary-stress preservation
# from shorter to longer). Falls back to spelling-startswith when either word lacks
# pronunciations (covers headwords like thermo that are dict-only with no prons but
# still gate thermoplastic's compound peel orthographically).
def pron_prefix_aligned?(longer, shorter)
  longer_prons = pronunciations(longer)
  shorter_prons = pronunciations(shorter)
  if longer_prons.empty? || shorter_prons.empty?
    return longer.to_s.downcase.start_with?(shorter.to_s.downcase)
  end
  shorter_prons.any? do |sp|
    s_phones = sp.phonemes.reject(&:syllable_boundary?)
    next false if s_phones.empty?
    longer_prons.any? do |lp|
      l_phones = lp.phonemes.reject(&:syllable_boundary?)
      next false if l_phones.length <= s_phones.length
      l_head = l_phones[0...s_phones.length]
      longer_has_primary = pron_phones_have_primary_stress?(l_phones)
      l_head.zip(s_phones).all? { |a, b| phoneme_tail_match?(a, b, longer_has_primary: longer_has_primary) }
    end
  end
end

# Hyphenated-leading-word peels: same-sex → sex, okey-dokey → dokey (when each
# leading segment is a dict headword). Returns the trailing remainder candidates.
def hyphen_compound_remainders(word)
  return [] if word.nil? || !word.include?("-")
  parts = word.split("-")
  return [] if parts.size < 2
  result = []
  (1...parts.size).each do |i|
    head_parts = parts[0...i]
    next unless head_parts.all? { |hp| !hp.empty? && word_dict_includes_headword?(hp) }
    rest = parts[i..-1].join("-")
    next if rest.empty?
    result << rest
  end
  result
end

# pron_suffix_aligned? but trivially true when word equals ancestor (so a word counts
# as its own ancestor for the common-ancestor intersection).
def pron_suffix_aligned_or_equal?(word, ancestor)
  return true if word == ancestor
  pron_suffix_aligned?(word, ancestor)
end

# True when any flat ARPAbet pronunciation of longer ends with any of shorter's, with
# strict consonant/primary-stressed-vowel matching and unstressed-vowel relaxation. Falls
# back to spelling-endswith if either word has no pronunciations (rare; preserves coverage
# for hyphenated/missing-pron entries that lexical_root_after_prefix already handles
# orthographically).
def pron_suffix_aligned?(longer, shorter)
  longer_prons = pronunciations(longer)
  shorter_prons = pronunciations(shorter)
  if longer_prons.empty? || shorter_prons.empty?
    return longer.to_s.downcase.end_with?(shorter.to_s.downcase)
  end
  shorter_prons.any? do |sp|
    s_phones = sp.phonemes.reject(&:syllable_boundary?)
    next false if s_phones.empty?
    longer_prons.any? do |lp|
      l_phones = lp.phonemes.reject(&:syllable_boundary?)
      next false if l_phones.length <= s_phones.length
      l_tail = l_phones[-s_phones.length..]
      longer_has_primary = pron_phones_have_primary_stress?(l_phones)
      l_tail.zip(s_phones).all? { |a, b| phoneme_tail_match?(a, b, longer_has_primary: longer_has_primary) }
    end
  end
end

# True when any phoneme in phones carries primary stress (digit "1"). Used by
# pron_suffix_aligned? / pron_prefix_aligned? to detect prons that lack
# primary stress entirely (occasional dict-build artifacts on inferred forms
# like microamerica: M AY2 K R OW0 AH0 M EH2 R AH0 K AH0). phoneme_tail_match?
# relaxes its primary-preservation gate in that case so the highest-stressed
# vowel acts as the de-facto primary, matching the rime extractor's stress-1
# → 2 → 0 fallback.
def pron_phones_have_primary_stress?(phones)
  phones.any? { |p| p.to_s.include?("1") }
end

# Phoneme equivalence for pron_suffix_aligned?. a is the longer-side phone,
# b is the shorter-side (ancestor's) phone; pron_suffix_aligned? feeds them
# in that order via l_tail.zip(s_phones).
#
# Consonants: must match by bare base.
# Vowels: bare bases must match; if neither phoneme carries primary stress, any
# vowel-vowel pair counts as a match (handles morphological vowel reduction at
# the prefix-stem boundary, e.g. enchanted EH0 N ↔ disenchanted's AH0 N
# tail). Additionally, when the SHORTER side carries primary stress AND the
# longer pron has primary stress somewhere, the LONGER side must carry primary
# stress at the same position. This blocks secondary-stressed compound
# elements from aligning with the bare element's primary (handout's AW2
# tail vs out's AW1 — perceptually a different rhyme contour from a true
# compound-rhyme like businessperson/person where both keep primary on
# per). When the longer pron carries no primary stress at all
# (microamerica: only AY2 / EH2), the gate relaxes — the highest-stressed
# vowel is the de-facto primary under the same fallback the rime extractor
# uses (stress 1 → 2 → 0), so secondary at the aligned position counts as
# primary-equivalent. Pre-strengthening, the bare-base check alone passed
# AW2/AW1 and over-filtered sibling compounds whose shared element kept
# secondary stress (handout/standout).
def phoneme_tail_match?(a, b, longer_has_primary: true)
  return true if a == b
  return false if a.syllable_boundary? || b.syllable_boundary?
  if a.vowel? && b.vowel?
    return true if !a.include?("1") && !b.include?("1")
    return false unless Phoneme.bare_base(a) == Phoneme.bare_base(b)
    return false if b.include?("1") && !a.include?("1") && longer_has_primary
    true
  else
    return false if a.vowel? || b.vowel?
    Phoneme.bare_base(a) == Phoneme.bare_base(b)
  end
end
