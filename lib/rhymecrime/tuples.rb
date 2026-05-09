# coding: utf-8

def inflection_suffix_kind_from_base(base, inflected)
  return nil if base.nil? || inflected.nil?

  k = Inflect.send(:match_suffix_kind, base, inflected)
  return k unless k.nil?

  if inflected.end_with?("ings")
    ing_form = inflected[0...-1]
    return :ings if Inflect.send(:match_suffix_kind, base, ing_form) == :ing
  end

  # Colloquial g-drop: fooin'/gluin'/stoppin'/tryin' share the same base
  # as the corresponding -ing form (see Inflect.gdropped_in_apostrophe_spelling).
  # Reconstitute the -ing surface and lean on the existing :ing probe so every
  # branch (silent-e, y-stem, doubling) stays authoritative in one place. A distinct
  # kind lets rhyming_tuple_kind_preferred? strictly prefer the non-apostrophe
  # spelling via RHYMING_TUPLE_SIBLING_KIND_RANK.
  if inflected.end_with?("in'") && inflected.bytesize >= 4
    ing_form = inflected[0...-3] + "ing"
    return :ing_gdrop if Inflect.send(:match_suffix_kind, base, ing_form) == :ing
  end

  # Agent-noun -or as an orthographic sibling of -er: sail→sailor,
  # act→actor, invent→inventor. Rhymes identically (unstressed schwa
  # +/ɚ/), and surfaces as sailor/whaler alongside sail/whale in real
  # rhyming-tuple output. Reported as :er rather than a distinct :or so
  # the same-length kind-lock in rhyming_tuple_suffix_redundant_with?
  # treats sail→sailor and whale→whaler as the SAME inflection and the
  # tuple gets pruned. Kept narrow on purpose: only fires when Inflect
  # has rejected every other reading first, and only for the simplest base
  # + "or" surface (no doubling, no silent-e) to avoid trampling the
  # Inflect derivation tables, which the dict-build / frequency
  # inheritance paths still own.
  if inflected.end_with?("or") &&
      inflected.bytesize == base.bytesize + 2 &&
      inflected.start_with?(base)
    return :er
  end

  # Denominal -y adjective: health→healthy, stealth→stealthy,
  # dust→dusty, snow→snowy. Surfaces in rhyming output as the
  # healthy/stealthy adjective tuple shadowing the health/stealth
  # noun tuple. A distinct :y_adj (not folded into any Inflect kind)
  # so the only path that ever sees it is the rhyming-tuple pruner —
  # Inflect derivation, dict-build, and frequency inheritance keep their
  # current behavior, which never synthesizes a +base+y+ surface from a
  # noun. Doubling-stem forms (mud→muddy, sun→sunny) are not
  # covered yet; add them when a failing tuple shows up.
  if inflected.end_with?("y") &&
      inflected.bytesize == base.bytesize + 1 &&
      inflected.start_with?(base)
    return :y_adj
  end

  # Two-step :y_adj + :er/:est chain: feather→feathery→featherier,
  # leather→leathery→leatheriest. Mirrors the :ings chain above
  # (-ing + -s) — same construction, just bridging through the synthetic
  # base"y"+ adjective intermediate that :y_adj already recognizes. Distinct
  # kinds (:y_adj_er / :y_adj_est) so the same-length kind-lock in
  # rhyming_tuple_suffix_redundant_with? holds — both featherier and
  # leatherier report :y_adj_er from their respective bases, the lock
  # accepts both, and the featherier/leatherier tuple gets pruned when the
  # feather/leather/... base tuple is present. Without this, the pruner
  # missed two-step adjective-comparative shadows of noun tuples — see
  # featherier/leatherier vs feather/leather/tether/whether in
  # spec/prune_redundant_tuples_spec.rb.
  #
  # Inflect.match_suffix_kind is the second-stage probe rather than a
  # recursive inflection_suffix_kind_from_base call so we can't accidentally
  # cascade further (:y_adj_er_…) — the chain is bounded at exactly two steps.
  if inflected.end_with?("ier") &&
      inflected.bytesize == base.bytesize + 3 &&
      inflected.start_with?(base) &&
      Inflect.send(:match_suffix_kind, base + "y", inflected) == :er
    return :y_adj_er
  end
  if inflected.end_with?("iest") &&
      inflected.bytesize == base.bytesize + 4 &&
      inflected.start_with?(base) &&
      Inflect.send(:match_suffix_kind, base + "y", inflected) == :est
    return :y_adj_est
  end

  nil
end

# True if later is an uninterestingly redundant inflection of earlier (same tuple length and
# each later[i] is the same Inflect suffix kind from earlier[i], or later is shorter and
# every word matches a distinct earlier word with one shared suffix kind). later must not be longer.
def rhyming_tuple_suffix_redundant_with?(earlier, later)
  return false if earlier.empty? || later.empty?
  return false if earlier.size < later.size

  if earlier.size == later.size
    kinds = earlier.each_index.map { |i| inflection_suffix_kind_from_base(earlier[i], later[i]) }
    return false if kinds.any?(&:nil?)

    kinds.uniq.size == 1
  else
    kind_lock = nil
    used_idx = {}
    later.each do |w|
      matched_i = nil
      matched_k = nil
      earlier.each_with_index do |base, i|
        next if used_idx[i]

        k = inflection_suffix_kind_from_base(base, w)
        next if k.nil?

        matched_i = i
        matched_k = k
        break
      end
      return false if matched_i.nil?

      if kind_lock.nil?
        kind_lock = matched_k
      elsif kind_lock != matched_k
        return false
      end
      used_idx[matched_i] = true
    end
    true
  end
end

# Preference order for sibling pruning: when two same-length tuples are both inflections of the
# same absent base, the tuple with the lower-ranked kind wins (more basic inflections are kept).
# Example: breezier / sleazier (kind :er, rank 4) beats breeziest / sleaziest (:est, rank
# 5) when neither breezy / sleazy is present in the input.
# Sibling-kind preference ladder. Lower rank wins when rhyming_tuples_share_hidden_base
# finds two tuples parallel-inflected off the same hidden base via two different kinds.
# :ing_gdrop sits strictly *below* :ing so making / faking / taking beats
# makin' / fakin' / takin' (and every analogous g-drop pair) — the apostrophe form
# is a colloquial surface of the same inflection, and we never want to render it when
# the canonical spelling is available.
RHYMING_TUPLE_SIBLING_KIND_RANK = { s: 1, ed: 2, ing: 3, er: 4, est: 5, ly: 6, ful: 7, ing_gdrop: 8 }.freeze

def rhyming_tuple_kind_preferred?(preferred, other)
  return false if preferred.nil? || other.nil? || preferred == other
  rp = RHYMING_TUPLE_SIBLING_KIND_RANK.fetch(preferred, Float::INFINITY)
  ro = RHYMING_TUPLE_SIBLING_KIND_RANK.fetch(other, Float::INFINITY)
  rp < ro
end

# If same-length tuples a and b are slot-parallel inflections of a common hidden base (not
# necessarily a headword in the dictionary) via two *different* consistent Inflect suffix kinds,
# return [kind_a, kind_b]. Otherwise nil. Used to prune sibling inflections of an
# absent-from-input base, e.g. pruning breeziest / sleaziest in favor of breezier / sleazier.
def rhyming_tuples_share_hidden_base(a, b)
  return nil if a.empty? || a.size != b.size
  return nil if a == b

  candidates_per_slot = a.each_index.map do |i|
    ca = Inflect.raw_candidate_bases_for_inflected(a[i])
    cb = Inflect.raw_candidate_bases_for_inflected(b[i])
    (ca & cb).to_a
  end
  return nil if candidates_per_slot.any?(&:empty?)

  candidates_per_slot.first.each do |b0|
    # Uses inflection_suffix_kind_from_base (not Inflect.match_suffix_kind) so
    # superset kinds like :ings and :ing_gdrop (see that wrapper) participate in
    # hidden-base parallelism — otherwise making / taking vs makin' / takin'
    # would go undetected and the g-drop tuple would slip past the pruner.
    ka = inflection_suffix_kind_from_base(b0, a.first)
    kb = inflection_suffix_kind_from_base(b0, b.first)
    next if ka.nil? || kb.nil? || ka == kb

    matches_all = true
    (1...a.size).each do |i|
      found = candidates_per_slot[i].any? do |bi|
        inflection_suffix_kind_from_base(bi, a[i]) == ka &&
          inflection_suffix_kind_from_base(bi, b[i]) == kb
      end
      unless found
        matches_all = false
        break
      end
    end
    return [ka, kb] if matches_all
  end

  nil
end

# Greek/Latin derivational suffix pairs used by
# rhyming_tuples_share_letter_stem_via_derivational_suffix?. Each entry is a
# pair of suffixes that attach to a shared letter stem to produce sibling
# noun/adjective forms (anorex + ia = anorexia, anorex + ic =
# anorexic). Order matters within a pair: the FIRST element is preferred —
# the cross-tuple sweep keeps tuples whose suffix matches .first and prunes
# the sibling whose suffix matches .last. (For the cases here that means we
# keep the noun and prune the adjective: anorexia / dyslexia wins over
# anorexic / dyslexic.) These derivations aren't productive in modern
# English — they're fossilized Greek/Latin loans — so Inflect doesn't list
# them and the rhyming-tuple pruner's stock probes
# (rhyming_tuples_share_hidden_base, rhyming_tuple_suffix_redundant_with?)
# all decline. Listed conservatively; add new pairs only when a failing tuple
# in spec/prune_redundant_tuples_spec.rb shows up.
DERIVATIONAL_SUFFIX_PAIRS = [
  %w[ia ic], # anorexia / anorexic, dyslexia / dyslexia → noun preferred
].freeze

# Recognize same-length sibling tuples that share a fixed letter-stem prefix
# at every slot and differ only by a known derivational suffix pair from
# DERIVATIONAL_SUFFIX_PAIRS. Returns true when the slot-aligned suffix
# pair (ear[i]'s suffix, tup[i]'s suffix) matches a registered pair (any
# orientation) and stays consistent across all slots; the per-slot stem
# overlap must be at least DERIVATIONAL_STEM_MIN_LENGTH characters so we
# don't latch onto trivial 1-2-letter coincidences. Used by
# really_rhyming_tuple_redundant_with? to mark tup as redundant with
# ear when the suffix pair fires in the ear-preferred direction
# (ear's suffix is .first in the registered pair). False otherwise — the
# reverse direction is handled implicitly by the cross-tuple sweep iterating
# in sort order: the noun tuple sorts before the adjective tuple
# alphabetically (anorexia < anorexic), so it lands in kept first and
# the adjective tuple gets compared against it (ear=noun, tup=adj) →
# pruned.
DERIVATIONAL_STEM_MIN_LENGTH = 4
def rhyming_tuples_share_letter_stem_via_derivational_suffix?(ear, tup)
  return false if ear.size != tup.size || ear.empty?
  return false if ear == tup

  pair_key = nil
  ear.each_with_index do |ew, i|
    tw = tup[i]
    return false if ew == tw

    # Try every registered suffix pair before splitting the stem. A naive
    # longest-common-prefix split would mis-segment anorexia/anorexic at
    # anorexi (the trailing i is shared) and miss the ia/ic pair —
    # the suffix has to bound the stem instead of the other way around.
    matched = DERIVATIONAL_SUFFIX_PAIRS.find do |es_suf, ts_suf|
      ew.end_with?(es_suf) && tw.end_with?(ts_suf) &&
        ew[0...-es_suf.bytesize] == tw[0...-ts_suf.bytesize] &&
        (ew.bytesize - es_suf.bytesize) >= DERIVATIONAL_STEM_MIN_LENGTH
    end
    return false unless matched

    if pair_key.nil?
      pair_key = matched
    else
      return false unless matched == pair_key
    end
  end
  !pair_key.nil?
end

# True if every word in bases (the shorter tuple) inflects into a distinct word in inflecteds
# (the longer tuple) using one shared Inflect suffix kind. Used to detect the case where a
# base-form tuple is a strict inflectional subset of a richer inflected tuple (e.g. the 3-member
# singular [archaeologist/paleontologist/scientologist] vs. the 4-member plural
# [archaeologists/paleontologists/scientologistes/scientologists]).
def rhyming_tuple_bases_all_inflect_into?(bases, inflecteds)
  return false if bases.empty? || inflecteds.empty?
  return false if bases.size > inflecteds.size

  kind_lock = nil
  used_idx = {}
  bases.each do |b|
    matched_i = nil
    matched_k = nil
    inflecteds.each_with_index do |infl, i|
      next if used_idx[i]

      k = inflection_suffix_kind_from_base(b, infl)
      next if k.nil?

      matched_i = i
      matched_k = k
      break
    end
    return false if matched_i.nil?

    if kind_lock.nil?
      kind_lock = matched_k
    elsif kind_lock != matched_k
      return false
    end
    used_idx[matched_i] = true
  end
  true
end

# Per-request memo for rhyming_tuple_word_bases. The function is pure over
# word_dict / Inflect (both load-time-stable) so the memo is safe to hold
# across a whole page render. prune_suffix_redundant_rhyming_tuples calls
# rhyming_tuple_word_bases repeatedly for the same word across multiple
# pruning passes (subset check, canonical base, all-spelling-variants), so
# caching drops cold-render time by ~25s for large rhyme sets. Cleared in
# RelatedWords.reset_caches! alongside the other per-render caches.
$rhyming_tuple_word_bases_cache = {}

# Set of valid-looking base headwords for word — word itself (when it is a headword), its
# stored lemma, and any Inflect.raw_candidate_bases_for_inflected candidate that is a headword.
# Recurses one level (e.g. foistings → foisting → foist) so chained inflections stay
# connected. Used by the hidden-base pruning path in prune_suffix_redundant_rhyming_tuples.
def rhyming_tuple_word_bases(word)
  cached = $rhyming_tuple_word_bases_cache[word]
  return cached unless cached.nil?

  result = Set.new
  if word.nil? || word.empty?
    $rhyming_tuple_word_bases_cache[word] = result
    return result
  end
  result.add(word) if word_dict_includes_headword?(word)
  lem = lemma(word)
  result.add(lem) if lem && word_dict_includes_headword?(lem)
  Inflect.raw_candidate_bases_for_inflected(word).each do |b|
    next unless word_dict_includes_headword?(b)
    result.add(b)
    # One level of recursion so chained inflections (foistings → foisting → foist) and
    # e-drop chains (suiting listed with both suite and suit) all reach the deepest
    # attested headword.
    lem2 = lemma(b)
    result.add(lem2) if lem2 && word_dict_includes_headword?(lem2)
    Inflect.raw_candidate_bases_for_inflected(b).each do |c|
      result.add(c) if word_dict_includes_headword?(c)
    end
  end
  $rhyming_tuple_word_bases_cache[word] = result
end

# Pre-filter fingerprint for the cross-tuple redundancy index in
# prune_suffix_redundant_rhyming_tuples. Returns a Set of identifiers such
# that two tuples can only be redundant with each other (under any branch of
# rhyming_tuple_redundant_with?) if their fingerprints intersect.
#
# Includes:
#
#   * word itself — for the "ear is the base of tup" direction. The
#     predicate calls inflection_suffix_kind_from_base(ear[i], tup[i]),
#     which is true when ear[i] is a base of tup[i]; the candidate
#     lookup needs ear[i] to live in tup[i]'s key set, and the easy
#     side is just adding ear[i] to ear's own keys here.
#   * lemma(word) — irregular-form bridge (ran → run, mice → mouse)
#     not reachable via surface-suffix morphology.
#   * Inflect.raw_candidate_bases_for_inflected(word) — every surface-
#     morphology base (-s, -ed, -ing, -er, -est, -ly, -ful, -ily, y/ies,
#     consonant-doubling undo, silent-e). This is the *unfiltered* Inflect
#     output, NOT the headword-vetted rhyming_tuple_word_bases: the
#     predicate's inflection_suffix_kind_from_base doesn't require either
#     side to be a headword (it's pure surface morphology), so the
#     fingerprint can't either, or any tuple with a non-headword member
#     (synthetic test data; partially-loaded DDB cache) would silently fall
#     out of the candidate pool. Found this trying to optimize the prune in
#     a fixture-only test where the dict was empty — see commit history.
#   * Surface reversals of the custom branches in
#     inflection_suffix_kind_from_base that route around Inflect: :y_adj
#     (healthy → health), :er via -or (sailor → sail), :ing_gdrop
#     (fakin' → faking / fakin), :ings (foistings → foisting / foist),
#     :y_adj_er / :y_adj_est (featherier → feather, leatheriest → leather).
#
# All entries are unvalidated by design — the fingerprint only narrows the
# candidate pool the real rhyming_tuple_redundant_with? predicate is then
# run against, so false positives cost a few extra (cheap) predicate calls;
# false negatives would silently change pruning output. Mirroring every
# reverse-strip branch in inflection_suffix_kind_from_base + every Inflect
# pattern is the contract that keeps spec/prune_redundant_tuples_spec.rb
# green and matches the un-optimized pruner output bit-for-bit.
def tuple_redundancy_keys_for_word(word)
  keys = Set.new
  return keys if word.nil? || word.empty?

  keys.add(word)

  lem = lemma(word)
  keys.add(lem) if lem && !lem.empty?

  Inflect.raw_candidate_bases_for_inflected(word).each { |b| keys.add(b) }

  if word.end_with?("y") && word.bytesize >= 2
    keys.add(word[0...-1])
  end
  if word.end_with?("or") && word.bytesize >= 4
    keys.add(word[0...-2])
  end
  if word.end_with?("in'") && word.bytesize >= 4
    keys.add(word[0...-3] + "ing")
    keys.add(word[0...-3])
  end
  if word.end_with?("ings") && word.bytesize >= 5
    keys.add(word[0...-1])
    keys.add(word[0...-4])
  end
  # Surface reversal of the :y_adj_er / :y_adj_est chains added in
  # inflection_suffix_kind_from_base above: featherier → feather,
  # leatheriest → leather. The fingerprint adds the chain-base
  # unconditionally — the predicate's +Inflect.match_suffix_kind(base + "y", …)
  # probe is what actually validates that the chain is real (e.g. crazier
  # gets craz added here, but the predicate rejects it because
  # Inflect.match_suffix_kind("crazy", "crazier") == :er requires crazy to
  # exist in Inflect's adjective table, not just the surface stripping).
  if word.end_with?("ier") && word.bytesize >= 4
    keys.add(word[0...-3])
  end
  if word.end_with?("iest") && word.bytesize >= 5
    keys.add(word[0...-4])
  end

  # Letter-stem reversals of DERIVATIONAL_SUFFIX_PAIRS entries used by
  # rhyming_tuples_share_letter_stem_via_derivational_suffix?: the index
  # bucket for both sides of a pair (anorexia, anorexic) needs to share a
  # stem key (anorex) so the cross-tuple sweep ever brings the two tuples
  # into really_rhyming_tuple_redundant_with? for the dedicated probe to
  # fire. Like the :y_adj_er / :ier stems above, these are added
  # unvalidated — false-positive index entries are cheap; the predicate
  # validates the per-slot suffix pair against DERIVATIONAL_SUFFIX_PAIRS.
  DERIVATIONAL_SUFFIX_PAIRS.flatten.uniq.each do |suf|
    if word.bytesize >= suf.bytesize + DERIVATIONAL_STEM_MIN_LENGTH && word.end_with?(suf)
      keys.add(word[0...-suf.bytesize])
    end
  end

  keys
end

# Shortest headword in rhyming_tuple_word_bases, tie-broken lex. Returns word itself when no
# bases are known (pure OOV). Used by rhyming_tuple_inflection_distance to count how many words
# in a tuple have shifted off their root form.
def rhyming_tuple_word_canonical_base(word)
  bases = rhyming_tuple_word_bases(word).to_a
  return word if bases.empty?
  bases.min_by { |b| [b.length, b] }
end

# Greedy bipartite assignment: can every word in shorter be paired with a distinct word in
# longer whose rhyming_tuple_word_bases set overlaps? When true, shorter is redundant with
# longer via a shared-hidden-base mapping (even when direct Inflect.match_suffix_kind probes
# don't fire because both sides are inflected, e.g. booting / fluting vs booted / fluted /
# fruited).
def rhyming_tuples_lemma_subset?(shorter, longer)
  return false if shorter.empty? || shorter.size > longer.size
  s_bases = shorter.map { |w| rhyming_tuple_word_bases(w) }
  return false if s_bases.any?(&:empty?)
  l_bases = longer.map { |w| rhyming_tuple_word_bases(w) }
  return false if l_bases.any?(&:empty?)
  used = Array.new(longer.size, false)
  s_bases.each do |sb|
    idx = (0...longer.size).find { |i| !used[i] && !(sb & l_bases[i]).empty? }
    return false if idx.nil?
    used[idx] = true
  end
  true
end

# Count of slots where the word is NOT its own canonical base (has been inflected off a root).
# Lower = closer to base forms. Primary tiebreaker for same-length hidden-base-parallel tuples:
# [prompt, romped, swamped] (distance 2) beats [prompts, romps, swamps] (distance 3) because
# the former retains one uninflected base.
def rhyming_tuple_inflection_distance(tuple)
  tuple.count { |w| rhyming_tuple_word_canonical_base(w) != w }
end

# True when every word in tuple shares a common non-self base — the tuple is N different
# spellings of one root (desperados / desperadoes both → desperado). Such tuples add no
# information beyond the canonical surface and prune_suffix_redundant_rhyming_tuples drops them
# entirely.
def rhyming_tuple_all_spelling_variants?(tuple)
  return false if tuple.size < 2
  shared = nil
  tuple.each do |w|
    non_self = rhyming_tuple_word_bases(w) - [w]
    return false if non_self.empty?
    shared = shared.nil? ? non_self.dup : shared & non_self
    return false if shared.empty?
  end
  true
end

# True when tup is redundant with the already-kept ear. Consolidates the four existing signal
# paths (same-length suffix-redundant, same-length sibling hidden base, richer base via
# bases_all_inflect_into, richer inflected via suffix_redundant_with) and adds the
# rhyming_tuples_lemma_subset? fallback for cases where both tuples are inflected off a shared
# absent base that Inflect.match_suffix_kind can't directly bridge
# (booting / fluting vs booted / fluted / fruited, prompt / romped / swamped vs
# prompts / romps / swamps).
# Optional cross-cue memoization layer for rhyming_tuple_redundant_with?.
# Populated only by bin/compute-set-related (which sets it to a fresh
# Hash before kicking off the en-masse prune loop). Runtime never sets it,
# so the predicate stays a pure function call on the hot path. The keys are
# [ear, tup] array pairs; Ruby Hashes hash arrays-of-strings naturally,
# and tuples in this codebase are already sorted before they reach
# prune_suffix_redundant_rhyming_tuples, so the same pair always normalizes
# to the same key without explicit canonicalization.
#
# Per the doc comment on prune_cross_tuple_redundancy_sweep:
# "rhyming_tuple_redundant_with?, whose entire transitive call graph is
# pure over (ear, tup) (no focal_word dependency anywhere). Safe to
# share a rhyming_tuple_redundant_with? memoization layer across cues."
# That's exactly what this memo exploits: in the en-masse compute, the
# same tuple-pair recurs across many cues' tuple sets (animal / transport /
# emotion clusters share heavily) — collapsing the redundant calls drops
# the prune phase from ~8h to ~10min across the full ~28K cueniverse.
$rhyming_tuple_redundant_memo = nil

def rhyming_tuple_redundant_with?(ear, tup)
  if $rhyming_tuple_redundant_memo
    key = [ear, tup]
    return $rhyming_tuple_redundant_memo[key] if $rhyming_tuple_redundant_memo.key?(key)
    result = really_rhyming_tuple_redundant_with?(ear, tup)
    $rhyming_tuple_redundant_memo[key] = result
    return result
  end
  really_rhyming_tuple_redundant_with?(ear, tup)
end

def really_rhyming_tuple_redundant_with?(ear, tup)
  if ear.size == tup.size
    return true if rhyming_tuple_suffix_redundant_with?(ear, tup)
    kinds = rhyming_tuples_share_hidden_base(ear, tup)
    return true if kinds && rhyming_tuple_kind_preferred?(kinds[0], kinds[1])
    # Fallback: hidden-base-parallel siblings whose kinds aren't uniform per tuple (so the
    # existing share_hidden_base probe can't seat them) but whose lemma multisets match and ear
    # carries more base-form words.
    return true if rhyming_tuples_lemma_subset?(tup, ear) &&
      rhyming_tuples_lemma_subset?(ear, tup) &&
      rhyming_tuple_inflection_distance(ear) < rhyming_tuple_inflection_distance(tup)
    # Fallback: Greek/Latin derivational siblings (anorexia/anorexic,
    # dyslexia/dyslexic). Inflect doesn't list these unproductive
    # alternations, so the probes above all decline; the dedicated
    # letter-stem probe consults DERIVATIONAL_SUFFIX_PAIRS to pair the
    # noun-side tuple (kept) with the adjective-side tuple (pruned).
    return true if rhyming_tuples_share_letter_stem_via_derivational_suffix?(ear, tup)
    false
  elsif ear.size > tup.size
    return true if rhyming_tuple_suffix_redundant_with?(ear, tup)
    return true if rhyming_tuple_bases_all_inflect_into?(tup, ear)
    # Fallback: tup's hidden-base multiset is a subset of ear's (richer wins), even when both
    # sides are already-inflected surfaces (ear = booted / fluted / fruited, tup =
    # booting / fluting). The direct suffix-kind probes above can't bridge two inflected
    # forms; the lemma-subset probe can.
    return true if rhyming_tuples_lemma_subset?(tup, ear)
    false
  else
    false
  end
end

# Drop tuples that differ from another tuple only by parallel Inflect suffixes (e.g. plural or
# past tense of the same set). Handles four regimes:
#
#   0. whole-tuple spelling-variant drop: all members are alternate spellings of one root
#      (desperados / desperadoes → drop)
#   1. same-length base/inflected pair: keep the base, prune the inflected
#   2. richer-vs-smaller inflectional subset: keep the richer tuple
#   3. base-vs-inflected-superset (richer inflected has extra members not in the base): keep the
#      richer inflected
#
# Checks are bidirectional against the kept list because tuples.sort does not reliably
# front-load base forms (e.g. "artilleries" < "artillery" because "i" < "y").
#
# Set DEBUG=1 in the environment (or hit the page with ?debug=1, which flips
# $debug_mode on per-request) to print each pruned tuple alongside the kept
# tuple it matched.
#
# When $debug_pruning is true (set per-request from the debug=1 URL param), tuples that
# would normally be dropped are instead retained in the returned array AND recorded in
# debug_pruned_tuples, so the renderer can display them inline, greyed out, alongside
# the kept tuples.
# Within a single rhyming tuple, drop members that are morphological COMMON_PREFIXES
# derivations of another member already present in the tuple, when the two share an
# matching rich rime (the criterion all_nontrivially_rich_rhymes? already
# uses to identify phonologically-redundant members). Example:
# [healthy, stealthy, unhealthy] -> [healthy, stealthy] because unhealthy = un
# + healthy and both share the HH EH L TH IY rich rime. Does not touch independent
# same-pron homophones (coral/choral, flour/flower) since neither is a prefix
# derivation of the other.
#
# Gated on gloss_cites_base? for prefixes in GLOSS_GATED_PREFIXES only.
# Productive prefixes (un, re, non, dis, mis, ...) almost always
# produce true derivations and we always collapse for those — WordNet glosses
# for productive negations/repetitions describe the meaning with synonyms
# rather than citing the base, so the gloss-citation signal is too noisy to
# use as a gate (40-60% false-negative rate per a un- sweep). The gate
# applies to prefixes that frequently produce *lexicalized* compounds, where
# the prefix+base surface masks an idiomatic meaning that should NOT be
# rhyme-collapsed — sub- being the headline case (submarine vs marine,
# subway vs way, subdue vs due, submerge vs merge, subscribe
# vs scribe, subtract vs tract). Productive sub- derivations
# (subset, submenu, subgroup) cite their base in the gloss and still
# collapse correctly.
GLOSS_GATED_PREFIXES = Set["sub"].freeze

def condense_tuple_derived_forms(tup, focal_word = nil)
  return tup if tup.size < 2
  rich_rime_set_of = {}
  tup.each do |w|
    rich_rime_set_of[w] = pronunciations(w).map { |p| p.rich_rime }.to_set
  end
  dropped = Set.new
  tup.each do |derived|
    next if dropped.include?(derived)
    tup.each do |base|
      next if base == derived
      next if dropped.include?(base)
      next if dropped.include?(derived)
      # Phonological proximity: rich-rime overlap (fast path) or pron_suffix_aligned?
      # fallback. The fallback catches cases where the rich rime differs by an extra
      # syllable-onset consonant due to syllabifier choices (disorienting's
      # "S AO ..." rich rime vs orienting's "AO ..." rich rime — the S migrated onset
      # because the dis- prefix's AH0 stays open before the new third
      # syllable). The pron-tail check is what prefix_words already uses
      # as the safety gate, so accepting it here aligns the within-tuple
      # condenser with the rhyme filter.
      next if (rich_rime_set_of[derived] & rich_rime_set_of[base]).empty? &&
        !pron_suffix_aligned?(derived, base)
      COMMON_PREFIXES.each do |prefix|
        next unless derived.start_with?(prefix) && derived[prefix.length..] == base
        if GLOSS_GATED_PREFIXES.include?(prefix)
          next unless gloss_cites_base?(derived, base)
        end
        loser = derived_form_loser(derived, base, focal_word)
        dropped << loser if loser
        break
      end
    end
  end

  return tup if dropped.empty?
  tup - dropped.to_a
end

# Pick which of an explicit (derived, base) prefix-derivation pair
# condense_tuple_derived_forms should drop. Returns nil to keep both.
#
# Cue-blind path (focal_word nil): always drop derived — preserves
# the historic behavior used by rhyming_pair_trivial? and any future
# focal-independent en-masse caller.
#
# Cue-aware path: when both members are materially related to the cue
# (score >= RELATEDNESS_SCORE_THRESHOLD), keep both — the rhyme isn't
# trivial-by-construction once both surfaces independently earn their
# place in the cue's tuple set (music's tuple keeps composition
# alongside position; prayers keeps request alongside quest).
# When only the derived form clears the threshold, drop the base
# instead (pirate's illegal/legal: keep the cue-relevant illegal
# even though legal is the bare base). Otherwise fall back to the
# cue-blind drop-derived default.
#
# Score is parallel_sibling_score's (cached-then-live-relatedness)
# blend so non-cached cues — the typical shape at runtime live-compute —
# still get a meaningful signal rather than the constant-zero
# RelatedWords.lookup_score stub.
def derived_form_loser(derived, base, focal_word)
  return derived if focal_word.nil? || focal_word.to_s.empty?
  sd = parallel_sibling_score(focal_word, derived)
  sb = parallel_sibling_score(focal_word, base)
  if sd >= RELATEDNESS_SCORE_THRESHOLD && sb >= RELATEDNESS_SCORE_THRESHOLD
    return nil
  end
  if sd >= RELATEDNESS_SCORE_THRESHOLD && sb < RELATEDNESS_SCORE_THRESHOLD
    return base
  end
  derived
end

# Within a single rhyming tuple, when two members are parallel
# COMMON_PREFIXES derivations of an absent shared base, drop one — the
# pair carries no rhyme information beyond the implicit base. Catches
# [disorient, reorient], [extralegal, illegal], [disoriented,
# reoriented], and the plural/gerund variants where the bare base
# (orient, legal) isn't in the tuple, while leaving [coral, choral]
# alone (no shared prefix-strip ancestor) and [eyeball, highball] alone
# (the AA2/AO1 stress mismatch makes pron_suffix_aligned? decline
# against the bare ball).
#
# Cue-aware tie-break: same ranking as condense_tuple_homophones —
#
#   1. similarity(focal_word, w) — stored relatedness to the cue, highest wins.
#   2. frequency(w) — unigram frequency, highest wins.
#   3. alphabetical w — final deterministic tiebreak.
#
# When focal_word is nil (en-masse compute callers that haven't
# plumbed the cue through, plus rhyming_pair_trivial? where the
# collapse-or-not answer is independent of which member wins) the rank
# degenerates to lex-max, preserving the historic deterministic behavior.
def condense_tuple_parallel_derivations(tup, focal_word = nil)
  return tup if tup.size < 2
  ancestors_of = {}
  tup.each do |w|
    ancestors_of[w] = recursive_prefix_ancestors(w) - [w]
  end
  dropped = Set.new
  tup.each do |a|
    next if dropped.include?(a)
    tup.each do |b|
      next if a == b || dropped.include?(b)
      shared = ancestors_of[a] & ancestors_of[b]
      next if shared.empty?
      matched = shared.any? do |anc|
        pron_suffix_aligned?(a, anc) && pron_suffix_aligned?(b, anc)
      end
      next unless matched
      loser = parallel_sibling_loser(a, b, focal_word)
      dropped << loser
      break if loser == a
    end
  end
  return tup if dropped.empty?
  tup - dropped.to_a
end

# Pick which of two parallel-derivation siblings to drop. Cue-aware: rank
# both by (score, frequency, length, alphabetical) against focal_word
# and return the lower-ranked surface; focal_word nil degenerates to
# (length, lex-max) so en-masse compute / pair-trivial callers get
# deterministic focal-independent behavior that still favors the
# shorter/canonical form.
#
# Length is a tertiary signal so on a true score+frequency tie the
# shorter (more canonical) member wins — e.g. music ->
# record / prerecord, both scoring 100 with identical frequency
# buckets, where record is the canonical form a rhyme partner like
# chord expects. Without the length tie-break the lex order picks
# prerecord, silently stripping record from the AO_R_D bucket.
#
# score falls back from the cached similarity to a live
# relatedness_score when the cached read is uninformative (zero for
# both siblings — the typical shape when focal_word is a non-cached
# cue, e.g. pirate, where the RelatedWords.lookup_score path returns
# 0 for every related). Without the live fallback the tiebreak collapses
# to frequency / length / lex-max for *every* parallel-derivation pair
# under a non-cached cue, defeating the purpose of being cue-aware. The
# live call is cheap here (two PairSignals evaluations per pair) and
# only fires when the prune is already in the live-compute branch —
# cached cues hit Store.fetch_set_related_tuples before reaching the
# prune.
def parallel_sibling_loser(a, b, focal_word)
  if focal_word.nil? || focal_word.to_s.empty?
    return [a, b].sort_by { |w| [w.length, w] }.last
  end
  sim_a = parallel_sibling_score(focal_word, a)
  sim_b = parallel_sibling_score(focal_word, b)
  ranked = [a, b].sort_by.with_index do |w, i|
    sim = i.zero? ? sim_a : sim_b
    [-sim, -frequency(w).to_i, w.length, w]
  end
  ranked.last
end

# Cached similarity first; fall back to a live
# relatedness_score(PairSignals.new(cue, related)) when the cached
# value is 0 (typical for non-cached cues where RelatedWords.lookup_score
# has no row to consult). Lazy-loads the relatedness compute pipeline on
# first call from a process that hadn't already loaded it via
# find_related_words — at Lambda runtime this only fires when the
# set_related goal has already gone live-compute (the cached-tuples
# path skips the prune entirely), so the load is paid for either way.
def parallel_sibling_score(focal_word, w)
  cached = similarity(focal_word, w).to_i
  return cached if cached > 0
  relatedness_lazy_load_compute!
  relatedness_score(PairSignals.new(lemma(focal_word), lemma(w))).to_i
rescue StandardError
  0
end

# Per-word cache of tokenized lowercase WordNet gloss text. Built lazily on
# first miss; persists for the lifetime of the process. WN access is wrapped
# so a missing or unconfigured WN install yields an empty token list rather
# than crashing the rhyme pipeline (the caller gloss_cites_base? treats
# empty-as-collapse, so the prefix rule still fires unchanged in that case).
# Per-word cache of WN derivationally-related lemmas (lowercase). Built lazily
# from wn_derivation_target_lemmas_for_word; empty when WN is unconfigured
# or the helper isn't loaded, in which case the citation check just falls
# back to surface-form / inflectional matching.
$gloss_deriv_targets_cache = {}
def gloss_deriv_targets_for_word(word)
  return Set.new if word.nil? || word.to_s.empty?

  key = word.to_s.downcase
  cached = $gloss_deriv_targets_cache[key]
  return cached unless cached.nil?

  Inflect.configure_wordnet_db_path! if defined?(Inflect)
  targets =
    begin
      if defined?(WordNet::Lemma) &&
          defined?(WordNet::DB) && !WordNet::DB.path.to_s.empty? &&
          respond_to?(:wn_derivation_target_lemmas_for_word, true)
        Set.new(wn_derivation_target_lemmas_for_word(key).map(&:to_s).map(&:downcase))
      else
        Set.new
      end
    rescue StandardError
      Set.new
    end
  $gloss_deriv_targets_cache[key] = targets.freeze
end

$gloss_tokens_cache = {}
def gloss_tokens_for_word(word)
  cached = $gloss_tokens_cache[word]
  return cached unless cached.nil?

  Inflect.configure_wordnet_db_path! if defined?(Inflect)
  tokens =
    begin
      # Plurals/inflected forms (submarines, rewrites) don't have their
      # own gloss entries on either side — the lemma owns the gloss. Try the
      # surface form first, then fall back to lemma(word) so e.g.
      # submarines's citation check consults submarine's "submersible
      # warship" gloss instead of returning empty (which would default-
      # collapse). Same lookup order is used for both WordNet and Wiktionary.
      surface = word.to_s.downcase
      lem = lemma(surface) rescue nil
      forms = [surface]
      forms << lem if lem && !forms.include?(lem)
      glosses = []
      wn_available = gloss_source_use_wordnet? &&
        defined?(WordNet::Lemma) &&
        wordnet_corpora_present?
      forms.each do |f|
        if wn_available
          wn_g = WordNet::Lemma.find_all(f).flat_map { |l| l.synsets.map(&:gloss) }
          glosses.concat(wn_g) unless wn_g.empty?
        end
        wk_g = wiktionary_glosses_for(f)
        glosses.concat(wk_g) unless wk_g.empty?
        break unless glosses.empty?
      end
      if glosses.empty?
        [].freeze
      else
        glosses.join(" ").downcase.scan(/[a-z]+/).freeze
      end
    rescue StandardError
      [].freeze
    end
  $gloss_tokens_cache[word] = tokens
end

# True iff derived's WordNet gloss(es) cite base (the base spelling, any
# Inflect.each_derivable_form surface, or — when base.length >= 5 — any
# gloss token that shares the base's first 4 characters; the stem-prefix
# branch lets unhealthy's gloss "not in good health" cite healthy via
# the token "health"). The derived word's self-mention (unhealthy in
# unhealthy's own gloss) is filtered out so unhappy's gloss "experiencing
# ... unhappy ..." can't trivially "cite" happy via its own surface.
#
# Conservative on the no-signal side: when WordNet has no gloss for
# derived (proper nouns, bedecked, into), we return true so the
# existing condense_tuple_derived_forms behavior is preserved.
def gloss_cites_base?(derived, base)
  tokens = gloss_tokens_for_word(derived)
  return true if tokens.empty?

  derived_lc = derived.to_s.downcase
  base_lc = base.to_s.downcase

  # Accept set construction:
  #  1. base spelling and its lemma
  #  2. their Inflect.each_derivable_form surfaces (handles restarts vs
  #     starts: lemma-fallback gloss "start an engine again" cites start)
  #  3. WN derivationally-related lemmas of base, *but only the
  #     spelling-adjacent ones* (sharing a 4-char prefix with the base
  #     lemma). marine's WN derivations include sea, which is the
  #     conceptual root but not a morphological cousin — accepting sea
  #     would let submarine's 3rd-sense gloss ("attack ... beneath the
  #     surface of the sea") falsely cite marine. The
  #     spelling-adjacency filter keeps kindness/kindly (citing kind)
  #     while rejecting sea/navigation (peripheral to marine).
  accept = Set[base_lc]
  base_lemma = (lemma(base_lc) rescue nil)
  accept << base_lemma if base_lemma
  if defined?(Inflect)
    [base_lc, base_lemma].compact.uniq.each do |seed|
      Inflect.each_derivable_form(seed) { |f| accept << f.downcase }
    end
  end
  stem_seed = base_lemma || base_lc
  spelling_adjacent_stem = stem_seed.length >= 4 ? stem_seed[0, 4] : nil
  if spelling_adjacent_stem
    [base_lc, base_lemma].compact.uniq.each do |seed|
      gloss_deriv_targets_for_word(seed).each do |t|
        accept << t if t.length >= 4 && t.start_with?(spelling_adjacent_stem)
      end
    end
  end

  # Stem prefix check (orthographic fallback): any gloss token sharing the
  # base lemma's first 4 chars counts as a citation. Lowered from len>=5 so
  # kind's gloss-citation in unkind matches the token "kindness" (which
  # is also a WN deriv-target, but the stem check covers it without
  # depending on WN being loaded).
  stem = stem_seed.length >= 4 ? stem_seed[0, 4] : nil

  tokens.any? do |t|
    next false if t == derived_lc
    next true if accept.include?(t)
    !stem.nil? && t.length >= stem.length && t.start_with?(stem)
  end
end

# Within a single rhyming tuple, break homophone clusters down to one winner.
# "Homophone cluster" = members sharing a full phoneme sequence (homophone_rhyme?):
# coral/choral, flour/flower, write/right, rite/right, symbol/cymbal,
# and same-pron near-twins where the dictionary records the surfaces with an
# epenthetic /t/ (chance/chants, both CH AE1 N T S).
#
# Unlike condense_tuple_derived_forms (which handles COMMON_PREFIXES derivations
# sharing only a rhyme-syllable fingerprint), neither member here is morphologically
# derived from the other, so there's no a-priori favorite; we need the cue to pick.
#
# Ranking key per member w:
#   1. parallel_sibling_score(focal_word, w) — cached similarity first, falling
#      back to a live relatedness_score when the cached read is uninformative
#      (zero for both cluster members — the typical shape under a non-cached
#      cue, e.g. magic, where RelatedWords.lookup_score has no row to
#      consult). Without the live fallback the tiebreak collapses to
#      frequency / lex for *every* homophone cluster under a non-cached cue,
#      and the alphabetically-earlier surface wins by accident even when the
#      other is the cue-relevant homophone (chants vs chance under magic;
#      rite vs right under prayers).
#   2. frequency(w) — unigram frequency, highest wins.
#   3. alphabetical w — final deterministic tiebreak.
# A nil focal_word (callers that haven't plumbed the cue through) disables this
# pass; the tuple is returned untouched.
# Spelling tails that encode an underlying /N S/ or /M S/ rime (no /T/ or /P/
# in the morphology), which CMUdict nonetheless stores with an epenthetic
# stop. Paired against EPENTHETIC_TS_TAILS to detect chance/chants-style
# pseudo-homophones.
EPENTHETIC_CE_TAILS = ["nce", "nse", "mse"].freeze
# Spelling tails that encode a real /N T S/ or /M P S/ rime — chants is the
# plural of chant, prints is the plural of print. When two surfaces share a
# CMUdict pron but one ends in a EPENTHETIC_CE_TAILS form and the other in
# a EPENTHETIC_TS_TAILS form, they are not genuine homophones — the dict
# just bakes in the same epenthetic stop for both spellings.
EPENTHETIC_TS_TAILS = ["nts", "mps"].freeze

# True when a and b share a CMUdict pron only because the dictionary
# inserts an epenthetic /T/ (after /N/ before /S/) or /P/ (after /M/ before
# /S/), and the two surfaces' orthographies disagree about whether that
# stop is morphologically present. chance (CH AE1 N T S, /T/ epenthetic —
# underlying form is /N S/) vs chants (CH AE1 N T S, real /T/ from
# chant + s); sense/cents; mince/mints; prince/prints;
# dense/dents. Genuine homophones (flour/flower, write/right,
# knows/nose) are unaffected because either their shared pron does not
# end in /N T S/ or /M P S/, or both surfaces use the same tail family
# (ants/aunts both spell out the /T S/).
def epenthetic_t_pseudo_homophone?(a, b)
  return false if a == b
  pa = pronunciations(a).first&.to_s
  pb = pronunciations(b).first&.to_s
  return false if pa.nil? || pb.nil? || pa != pb
  a_low = a.downcase
  b_low = b.downcase
  a_ts = EPENTHETIC_TS_TAILS.any? { |e| a_low.end_with?(e) }
  a_ce = EPENTHETIC_CE_TAILS.any? { |e| a_low.end_with?(e) }
  b_ts = EPENTHETIC_TS_TAILS.any? { |e| b_low.end_with?(e) }
  b_ce = EPENTHETIC_CE_TAILS.any? { |e| b_low.end_with?(e) }
  (a_ts && b_ce) || (a_ce && b_ts)
end

def condense_tuple_homophones(tup, focal_word)
  return tup if tup.size < 2 || focal_word.nil?
  ungrouped = tup.dup
  clusters = []
  while (seed = ungrouped.shift)
    seed_prons = pronunciations(seed)
    mates = ungrouped.select do |other|
      next false if epenthetic_t_pseudo_homophone?(seed, other)
      seed_prons.any? { |sp| homophone_rhyme?(other, sp) }
    end
    next if mates.empty?
    ungrouped -= mates
    clusters << [seed, *mates]
  end
  return tup if clusters.empty?
  dropped = Set.new
  clusters.each do |cluster|
    ranked = cluster.sort_by do |w|
      [-parallel_sibling_score(focal_word, w), -frequency(w).to_i, w]
    end
    ranked[1..].each { |w| dropped << w }
  end
  tup - dropped.to_a
end

# True when the pair [a, b] would collapse to a single member under within-tuple
# derivation/homophone condensation — i.e. it is a morphological COMMON_PREFIXES
# derivation over matching rich_rime (condense_tuple_derived_forms),
# or a true same-phoneme homophone pair (condense_tuple_homophones). Examples:
# [healthy, unhealthy] (prefix); [flour, flower], [coral, choral],
# [symbol, cymbal] (homophones). The homophone condenser needs a focal_word
# to pick a winner, but for the drop-or-keep decision here we only care whether
# the cluster collapses, so any non-nil focal (we pass a) produces the same
# size result.
def rhyming_pair_trivial?(a, b)
  return false if a == b
  condense_tuple_derived_forms([a, b]).size < 2 ||
    condense_tuple_parallel_derivations([a, b]).size < 2 ||
    condense_tuple_homophones([a, b], a).size < 2
end

# Pair-mode analog of within-tuple derivation/homophone condensation in
# prune_suffix_redundant_rhyming_tuples. Drops pairs whose two members
# rhyming_pair_trivial? flags as prefix derivations or same-pronunciation
# homophones — the "rhyme" carries no
# information beyond the trivial collapse. A pair is binary, so unlike the
# tuple condensers (which pick a winner and keep the tuple alive) we drop the
# whole pair. Called from really_find_rhyming_pairs after the rhyme-cross.
def prune_trivial_rhyming_pairs(pairs)
  return pairs if pairs.empty?
  verbose_prunes = $debug_mode || debug_pruning?
  pairs.reject do |(a, b)|
    trivial = rhyming_pair_trivial?(a, b)
    puts "pruned rhyming pair (trivial rhyme: prefix or homophone): #{a} / #{b}" if trivial && verbose_prunes
    trivial
  end
end

# When $disable_cross_tuple_redundancy_pruning is true, the cross-tuple
# rhyming_tuple_redundant_with? pass below is skipped: distinct rhyme-bucket
# tuples that differ only by parallel Inflect suffixes ([deck, wreck] vs
# [decked, wrecked], [crew, tattoo] vs [crews, tattoos]) all survive.
# Within-tuple derivation condensation (condense_tuple_derived_forms, which
# collapses [legal, illegal]-style rich-rhyme prefix derivations) still
# runs — only the *across-tuple* derivational dedup is bypassed. Used by
# spec/similar_rhymes_spec.rb so per-pair assertions like
# set_related_oughta_contain 'pirate', 'deck', 'wreck' aren't masked by an
# already-kept past-tense sibling tuple. Production runtime keeps it false.
$disable_cross_tuple_redundancy_pruning = false

# Per-tuple prune: applies the stop-word wholesale drop, the
# spelling-variant wholesale drop, and within-tuple derivation
# condensation. Returns either:
#
#   * nil — tuple was dropped wholesale by the stop-word drop (all stop
#     words — above / of) or the spelling-variant drop (all members are
#     spelling variants of one root — desperados / desperadoes).
#   * a (possibly shorter) tuple — survived the wholesale-drop steps;
#     within-tuple derivation condensation may have removed prefix-derivation
#     members whose rich_rime matched a base already present
#     in the tuple ([healthy, stealthy, unhealthy] → [healthy, stealthy],
#     [recorded, prerecorded, unrecorded] → [recorded]).
#
# Cue awareness: the wholesale-drop steps are pure functions of the
# tuple. condense_tuple_derived_forms consults focal_word when one
# is supplied, so a derived/base pair where the derived form is
# the cue-relevant surface (music's composition over position,
# prayers's request over quest) survives the collapse rather than
# always losing to its bare base. With focal_word nil the helper
# stays focal-independent and a cache-aware caller can memoize the
# result across cues.
def prune_tuple_cue_independent_steps(tup, focal_word = nil)
  return nil if tup.all? { |w| semantically_promiscuous?(w) }
  return nil if rhyming_tuple_all_spelling_variants?(tup)
  condense_tuple_derived_forms(tup, focal_word)
end

# Cross-tuple redundancy sweep: drops tuples that differ from another
# already-kept tuple only by parallel Inflect suffixes, hidden-base
# parallelism, or lemma-multiset inclusion. Operates on a pre-sorted list
# of tuples that have already been through the cue-independent steps
# (stop-word/spelling-variant drops, derivation condensation),
# within-tuple homophone condensation, and the below-two-member drop.
#
# Focal-independent: every redundancy decision routes through
# rhyming_tuple_redundant_with?, whose entire transitive call graph is
# pure over (ear, tup) (no focal_word dependency anywhere). Safe to
# share a rhyming_tuple_redundant_with? memoization layer across cues;
# the only cue-specific input is the per-cue tuple list itself.
#
# Indexing: tuples are bucketed by an "inflection-key" fingerprint
# (tuple_redundancy_keys_for_word) so each new tup only compares
# against kept entries that share at least one key. Every branch in
# rhyming_tuple_redundant_with? ultimately routes through
# inflection_suffix_kind_from_base,
# Inflect.raw_candidate_bases_for_inflected, or
# rhyming_tuple_word_bases — all three require the two tuples' words to
# share a lemma / inflection base, so disjoint-fingerprint tuples can be
# pruned from consideration without ever invoking the predicate. This
# collapses the original O(N^2) scan to roughly O(N * avg_bucket_size)
# and is the difference between cat (654 tuples → 11 s) and pirate (~900
# tuples) in the 29-second API Gateway budget — see [timing]
# set_related[<word>] prune in CloudWatch (Rhymecrime::Timing.measure
# always emits these phase logs).
#
# Insertion-order semantics are preserved: kept is a Hash (which
# iterates in insertion order on MRI), so kept.values at the bottom
# returns the same sequence as the previous kept Array would have.
# Set is used for the inverted index so candidate-lookup is O(1) per
# key.
#
# The fingerprint must be a *superset* of every reachable redundancy
# match or we silently drop comparisons. rhyming_tuple_word_bases alone
# is too narrow because inflection_suffix_kind_from_base has several
# extensions beyond Inflect.match_suffix_kind that don't show up in the
# Inflect base table: :y_adj (health → healthy), :er via -or
# (sail → sailor), :ing_gdrop (fakin' → faking), :ings (foist →
# foistings, mostly already covered by Inflect's -s stripping but
# mirrored here for safety), and the two-step :y_adj_er / :y_adj_est
# chain (feather → featherier, leather → leatheriest).
# tuple_redundancy_keys_for_word inlines those reversals against the
# surface, *unvalidated* — false positives in the pre-filter just mean we
# run the real predicate on a few extra pairs, which is cheap. False
# negatives would silently change pruning output (regression in
# spec/prune_redundant_tuples_spec.rb).
def prune_cross_tuple_redundancy_sweep(sorted_tuples)
  verbose_prunes = $debug_mode || debug_pruning?
    debug_pruning = debug_pruning?

  base_index = Hash.new { |h, k| h[k] = Set.new }
  kept = {}
  kept_bases = {}
  next_idx = 0

  bases_for_tuple = lambda do |tup|
    set = Set.new
    tup.each { |w| set.merge(tuple_redundancy_keys_for_word(w)) }
    set
  end

  sorted_tuples.each do |tup|
    bases = bases_for_tuple.call(tup)
    candidate_idx = Set.new
    bases.each { |b| candidate_idx.merge(base_index[b]) }

    keeper_idx = candidate_idx.find { |ki| rhyming_tuple_redundant_with?(kept[ki], tup) }
    if keeper_idx
      if verbose_prunes
        puts "pruned rhyming tuple (suffix-redundant): #{tup.join(' / ')}  [kept: #{kept[keeper_idx].join(' / ')}]"
      end
      if debug_pruning
        debug_pruned_tuples << tup
        # Under debug, the pruned tuple still flows through to the output (the
        # renderer paints it grey via output_tuple_pruned). Index it like any
        # other survivor so later candidates can find it as a keeper too —
        # mirrors the original kept << tup behavior.
        kept[next_idx] = tup
        kept_bases[next_idx] = bases
        bases.each { |b| base_index[b] << next_idx }
        next_idx += 1
      end
      next
    end

    # tup stands; check whether it obsoletes any earlier ear. Only candidate
    # indices need checking (other entries in kept have disjoint base sets and
    # so can't be redundant with tup under any branch of the predicate).
    to_remove = []
    candidate_idx.each do |ki|
      ear = kept[ki]
      next unless ear
      redundant = rhyming_tuple_redundant_with?(tup, ear)
      next unless redundant

      if verbose_prunes
        puts "pruned rhyming tuple (suffix-redundant): #{ear.join(' / ')}  [kept: #{tup.join(' / ')}]"
      end
      if debug_pruning
        debug_pruned_tuples << ear
        # Retain ear (marked pruned) instead of rejecting it — matches the
        # original next false branch in kept.reject!.
      else
        to_remove << ki
      end
    end

    to_remove.each do |ki|
      kept_bases[ki].each { |b| base_index[b].delete(ki) }
      kept.delete(ki)
      kept_bases.delete(ki)
    end

    kept[next_idx] = tup
    kept_bases[next_idx] = bases
    bases.each { |b| base_index[b] << next_idx }
    next_idx += 1
  end

  kept.values
end

# Drop rhyming tuples that differ from another tuple only by parallel Inflect suffixes
# (e.g. plural or past tense of the same set). Handles four regimes:
#
#   0. whole-tuple spelling-variant drop: all members are alternate spellings of one root
#      (desperados / desperadoes → drop)
#   1. same-length base/inflected pair: keep the base, prune the inflected
#   2. richer-vs-smaller inflectional subset: keep the richer tuple
#   3. base-vs-inflected-superset (richer inflected has extra members not in the base): keep the
#      richer inflected
#
# Pipeline:
#
#   * Cue-independent per-tuple steps — factored into
#     prune_tuple_cue_independent_steps so an en-masse caller can
#     memoize the result. Runs (in order): the *stop-word wholesale drop*
#     (drop tuples that are all stop words — above / of), the
#     *spelling-variant wholesale drop* (drop tuples whose members are
#     all spelling variants of one root — desperados / desperadoes),
#     and *within-tuple derivation condensation* (drop COMMON_PREFIXES
#     derivation members whose rich_rime matches a base
#     already in the tuple — [healthy, stealthy, unhealthy] → [healthy,
#     stealthy]).
#   * Within-tuple homophone condensation — condense_tuple_homophones.
#     The *only* prune step that consults focal_word: breaks residual
#     full-pronunciation homophone clusters (coral/choral,
#     flour/flower, write/right) by picking the member most
#     closely related to the cue (tie-break: unigram frequency, then
#     alphabetical). Requires a non-nil focal_word; otherwise this
#     sub-pass is a no-op.
#   * Below-two-member drop — drop tuples whose condensation collapsed
#     them below 2 members. A "rhyming tuple" with one (or zero) word is
#     no longer a rhyme — the input was a pure prefix-derivation pair
#     like [legitimate, illegitimate] or a homophone cluster like
#     [coral, choral], and condense_tuple_* picked the one keeper.
#     Without this drop the singleton would survive the pruner and render
#     as a single-word "tuple". Callers (find_rhyming_tuples) already
#     filter size < 2 on the way out, but the unit pruner itself owes
#     the same contract so spec assertions on
#     prune_suffix_redundant_rhyming_tuples output match what the UI
#     ultimately renders.
#   * Cross-tuple redundancy sweep — focal-independent O(N * avg_bucket_size)
#     pass factored into prune_cross_tuple_redundancy_sweep. Drops
#     tuples redundant with another already-kept tuple under any of the
#     rhyming_tuple_redundant_with? branches.
#
# Checks are bidirectional against the kept list because tuples.sort does not reliably
# front-load base forms (e.g. "artilleries" < "artillery" because "i" < "y").
#
# Set DEBUG=1 in the environment (or hit the page with ?debug=1, which flips
# $debug_mode on per-request) to print each pruned tuple alongside the kept
# tuple it matched.
#
# When $debug_pruning is true (set per-request from the debug=1 URL param), tuples that
# would normally be dropped are instead retained in the returned array AND recorded in
# debug_pruned_tuples, so the renderer can display them inline, greyed out, alongside
# the kept tuples.
def prune_suffix_redundant_rhyming_tuples(tuples, focal_word = nil)
  verbose_prunes = $debug_mode || debug_pruning?
    debug_pruning = debug_pruning?

  # Cue-independent per-tuple steps via the pure helper (stop-word
  # wholesale drop, spelling-variant wholesale drop, within-tuple
  # derivation condensation). The orchestrator handles the verbose /
  # debug-pruning side effects so the helper itself stays a pure function
  # of its tuple.
  tuples = tuples.flat_map do |tup|
    survivor = prune_tuple_cue_independent_steps(tup, focal_word)
    if survivor.nil?
      # Wholesale drop (semantically-promiscuous or spelling-variant).
      reason = tup.all? { |w| semantically_promiscuous?(w) } ? "all semantically promiscuous" : "all spelling variants of one root"
      puts "pruned rhyming tuple (#{reason}): #{tup.join(' / ')}" if verbose_prunes
      debug_pruned_tuples << tup if debug_pruning
      next debug_pruning ? [tup] : []
    end
    # Within-tuple derivation condensation may have shortened the tuple.
    # Under debug we retain the original tup so the renderer keeps
    # showing it (with the dropped member recorded as a singleton in
    # debug_pruned_tuples); the downstream homophone condensation then
    # runs on the retained original, which is semantically equivalent
    # because prefix-derivation drops and full-pronunciation homophone
    # clusters are disjoint by construction (a prefix derivation has an
    # extra phoneme prefix that makes it phonologically distinct from
    # its base).
    if verbose_prunes && survivor.size < tup.size
      dropped = tup - survivor
      puts "condensed rhyming tuple (dropped #{dropped.inspect}, derived forms): #{tup.join(' / ')} -> #{survivor.join(' / ')}"
    end
    if debug_pruning
      (tup - survivor).each { |w| debug_pruned_tuples << [w] }
      [tup]
    else
      [survivor]
    end
  end

  # Within-tuple parallel-derivation condensation — focal-dependent.
  # Collapse [disorient, reorient] / [illegal, extralegal]-style
  # parallel sibling pairs (two members sharing a non-self prefix-strip
  # ancestor that pron-suffix-aligns with both). Cue-aware tie-break in
  # parallel_sibling_loser keeps the sibling more similar to
  # focal_word — pirate's tuple keeps illegal over extralegal,
  # constitution's tuple would keep extralegal over illegal.
  tuples = tuples.map do |tup|
    condensed = condense_tuple_parallel_derivations(tup, focal_word)
    if verbose_prunes && condensed.size < tup.size
      dropped = tup - condensed
      puts "condensed rhyming tuple (dropped #{dropped.inspect}, parallel derivations): #{tup.join(' / ')} -> #{condensed.join(' / ')}"
    end
    if debug_pruning
      (tup - condensed).each { |w| debug_pruned_tuples << [w] }
      tup
    else
      condensed
    end
  end

  # Within-tuple homophone condensation — focal-dependent. Within each
  # tuple, break full-pronunciation homophone clusters down to one
  # winner by stored relatedness to focal_word.
  tuples = tuples.map do |tup|
    condensed = condense_tuple_homophones(tup, focal_word)
    if verbose_prunes && condensed.size < tup.size
      dropped = tup - condensed
      puts "condensed rhyming tuple (dropped #{dropped.inspect}, homophones): #{tup.join(' / ')} -> #{condensed.join(' / ')}"
    end
    if debug_pruning
      (tup - condensed).each { |w| debug_pruned_tuples << [w] }
      tup
    else
      condensed
    end
  end

  # Below-two-member drop: drop tuples whose condensation collapsed them below 2 members.
  tuples = tuples.reject do |tup|
    next false if tup.size >= 2
    if verbose_prunes
      puts "pruned rhyming tuple (collapsed below 2 members during condensation): #{tup.join(' / ')}"
    end
    debug_pruned_tuples << tup if debug_pruning
    !debug_pruning
  end

  return tuples.sort if $disable_cross_tuple_redundancy_pruning

  prune_cross_tuple_redundancy_sweep(tuples.sort)
end

# Related headwords for tuple/pair construction: common (freq > RARE_FREQ_MAX) and preferred surface
# (preferred_form_in_build_lexicon when word_dict is populated, else preferred_form).
def word_common_preferred_for_tuple_or_pair?(w)
  entry = lexicon_word_entry(w)
  return false unless entry
  return false if entry[0].to_i <= RARE_FREQ_MAX

  wd = word_dict
  if wd.is_a?(Hash) && !wd.empty? && wd.key?(w)
    preferred_form_in_build_lexicon(w, wd) == w
  else
    preferred_form(w) == w
  end
end

def filter_related_words_to_common_preferred(words)
  words.select { |w| word_common_preferred_for_tuple_or_pair?(w) }
end

# Maximum number of entries held by each of the rhyming-result LRU caches
# ($rhyming_tuple_cache and $rhyming_pair_cache). Small by design: a single
# web request typically hits only a handful of distinct (word[, word2], common_only)
# keys, so 30 is plenty to absorb repeat calls without letting the caches grow
# unboundedly across a long-running process.
RHYMING_LRU_CACHE_SIZE = 30

# LRU cache backed by a Ruby Hash (which preserves insertion order). On a hit
# we delete + reinsert the key to bump it to the most-recently-used slot; on a
# miss we evict the oldest entry via shift once capacity is exceeded. The
# block passed to lru_cache_fetch is only invoked on a miss.
def lru_cache_fetch(cache, key, capacity)
  if cache.key?(key)
    value = cache.delete(key)
    cache[key] = value
    return value
  end
  value = yield
  cache[key] = value
  cache.shift while cache.size > capacity
  value
end

$rhyming_tuple_cache = {}
def find_rhyming_tuples(input_rel1, common_only = false)
  # Skip the computed-store and LRU paths when $debug_pruning is true:
  # the pruner side-effects debug_pruned_tuples (a per-request Set consulted
  # by print_tuple for the grey pruning color), and returning cached results
  # (whether from $rhyming_tuple_cache or the computed set_related# row)
  # would bypass that population, leaving retained-pruned tuples un-colored.
  # Debug requests are rare so recomputing is fine. We also avoid populating
  # $rhyming_tuple_cache from debug-mode results, since those include tuples
  # that non-debug callers expect to have been dropped.
  return really_find_rhyming_tuples(input_rel1, common_only) if debug_pruning?
  return really_find_rhyming_tuples(input_rel1, common_only) if $disable_cross_tuple_redundancy_pruning

  # Computed-store path: bin/compute-set-related stashes the fully
  # post-pruned tuple list for every cue lemma in the cueniverse. The Lambda
  # runtime (DataSource.dynamodb? → store_authoritative?) treats a missing
  # row as "this cue isn't in our common-word set" and returns nil here so
  # the goal-dispatch branch in rhymecrime can render the friendly
  # bad_input message ("I don't like that word." for forbid_list cues, "Oops,
  # I don't know what words are related to <cue>..." otherwise). Local-dev
  # (LocalStore, non-authoritative) falls through to the live-compute path
  # so spec runs and pre-compute checkouts still produce results.
  if Rhymecrime::Store.available?
    cached = Rhymecrime::Store.fetch_set_related_tuples(lemma(input_rel1))
    return cached if cached
    return nil if store_authoritative?
  end

  lru_cache_fetch($rhyming_tuple_cache, [input_rel1, common_only], RHYMING_LRU_CACHE_SIZE) do
    really_find_rhyming_tuples(input_rel1, common_only)
  end
end

def really_find_rhyming_tuples(input_rel1, common_only = false)
  # Rhyming word sets that are related to INPUT_REL1.
  # Each element of the returned array is an array of words that rhyme with each other and are all related to INPUT_REL1.
  # Algorithm:
  # Compute the set of all words thematically related to INPUT_REL1, call it RELATEDS1.
  # For each word REL1 in RELATEDS1,
  #   Get all rhymes RHYME1 of REL1.
  #   If R is in RELATEDS1, compute R's rime and put RHYME1 in the bucket labeled by that rime.
  # Return all buckets with two or more words in them, after prune_suffix_redundant_rhyming_tuples
  # drops tuples that only parallel an earlier tuple's Inflect suffixes (e.g. all plural or all past).
  #
  # Rhymecrime::Timing.measure wrappers below always emit one [timing]
  # line per phase to STDERR (and from there to CloudWatch on Lambda).
  # The phase labels mirror the algorithm steps above so a
  # CloudWatch grep for [timing] set_related[<word>] tells you whether the
  # 29-second budget is being eaten by find_related (single get_item on
  # related#<lemma> + N batched gets), prefetch (rhyme-cohort fan-out), the
  # main rhyme-bucket loop (in-memory after prefetch), or prune (O(N^2) cross-
  # tuple suffix-redundancy check).
  return [] if forbidden?(input_rel1)

  related_list = Rhymecrime::Timing.measure("set_related[#{input_rel1}] find+filter related") do
    filter_related_words_to_common_preferred(
      find_related_words(input_rel1, true, false, nil, common_only: true)
    )
  end
  relateds1 = related_list.to_set

  related_rhymes = Hash.new { |h, k| h[k] = [] }
  Rhymecrime::Timing.measure("set_related[#{input_rel1}] rhyme-bucket loop n=#{related_list.size}") do
    related_list.each do |rel1|
      pronunciations(rel1).each do |rel1pron|
        rime = rel1pron.rime
        debug "Rhymes for #{rel1} [#{rime}] #{debug_info(rel1)}:"
        find_rhyming_words_for_pronunciation(rel1pron, true).each do |rhyme1|
          if relateds1.include?(rhyme1) # we only care about relateds of input_rel1
            rhyme1 = preferred_form(rhyme1) # push 'honor' instead of 'honour'. This will ensure we don't push both.
            related_rhymes[rime].push(rhyme1)
            debug " #{rhyme1} #{debug_info(rhyme1)}"
          end
        end
      end
    end
  end

  tuples = []
  related_rhymes.each do |_rime, relrhymes|
    relrhymes.sort!.uniq!
    tuples.push(relrhymes.sort) if relrhymes.length > 1 && !all_nontrivially_rich_rhymes?(relrhymes)
  end
  # Alternate pronunciations can yield different rime keys (e.g. OW_L_IY_AH_N vs OW_L_Y_AH_N) with the
  # same sorted word set — dedupe before suffix pruning so output is not repeated line-for-line.
  tuples.uniq!
  Rhymecrime::Timing.measure("set_related[#{input_rel1}] prune tuples=#{tuples.size}") do
    prune_suffix_redundant_rhyming_tuples(tuples, input_rel1).reject { |tup| tup.nil? || tup.size < 2 }
  end
end

$rhyming_pair_cache = {}
def find_rhyming_pairs(input_rel1, input_rel2, common_only = false)
  # Mirrors find_rhyming_tuples's caching policy: bypass the cache whenever
  # $debug_pruning is true so pruning side-effects still populate.
  return really_find_rhyming_pairs(input_rel1, input_rel2, common_only) if debug_pruning?
  return really_find_rhyming_pairs(input_rel1, input_rel2, common_only) if $disable_cross_tuple_redundancy_pruning

  lru_cache_fetch($rhyming_pair_cache, [input_rel1, input_rel2, common_only], RHYMING_LRU_CACHE_SIZE) do
    really_find_rhyming_pairs(input_rel1, input_rel2, common_only)
  end
end

def really_find_rhyming_pairs(input_rel1, input_rel2, common_only = false)
  # Pairs of rhyming words where the first word is related to INPUT_REL1 and the second word is related to INPUT_REL2
  # Each element of the returned array is a pair of rhyming words [W1 W2] where W1 is related to INPUT_REL1 and W2 is related to INPUT_REL2
  #
  # Algorithm (same semantics as the naive nested loop, optimized):
  # - RELATEDS1 / RELATEDS2: filtered related lemmas for each cue (common preferred, not promiscuous).
  # - Expand the *smaller* side: for each outer word, gather (rime → [(outer_w, pron), ...]) using
  #   the same all_forms × pronunciations walk as find_rhyming_words (homophone_ok=false cohort pass).
  # - For each distinct rime, scan its cohort once; any cohort word in the *other* related set is a
  #   candidate match. homophone_rhyme?(candidate, pron) matches find_rhyming_words_for_pronunciation.
  # - Rhymecrime::Timing.measure phases mirror set_related so CloudWatch can separate related fetch,
  #   index build, cohort scan, and prune.
  return [] if forbidden?(input_rel1) || forbidden?(input_rel2)

  timing_base = "pair_related[#{input_rel1}+#{input_rel2}]"

  # Semantically promiscuous words are thematically related to everything by
  # policy, which would otherwise flood the pair output with pairs like
  # [perhaps, duh] / [could, then]. A 2-element pair has no room for a
  # go-word anchor when either side is promiscuous, so we drop those before
  # the rhyme cross.
  relateds1 = Rhymecrime::Timing.measure("#{timing_base} find+filter related[1]") do
    filter_related_words_to_common_preferred(
      find_related_words(input_rel1, true, false, nil, common_only: true)
    ).reject { |w| semantically_promiscuous?(w) }
  end
  relateds2 = Rhymecrime::Timing.measure("#{timing_base} find+filter related[2]") do
    filter_related_words_to_common_preferred(
      find_related_words(input_rel2, true, false, nil, common_only: true)
    ).reject { |w| semantically_promiscuous?(w) }
  end
  relateds2_set = relateds2.to_set
  relateds1_set = relateds1.to_set

  # Expand the smaller related set so we run fewer outer-word expansions; emit [w1, w2] with w1 ∈ RELATEDS1.
  outer_words, inner_set =
    if relateds1.size <= relateds2.size
      [relateds1, relateds2_set]
    else
      [relateds2, relateds1_set]
    end

  return [] if outer_words.empty? || inner_set.empty?

  rime_entries = Rhymecrime::Timing.measure("#{timing_base} build rime index outer=#{outer_words.size} inner=#{inner_set.size}") do
    h = Hash.new { |hh, k| hh[k] = [] }
    outer_words.each do |outer_w|
      all_forms(outer_w).each do |form|
        next if forbidden?(form)
        pronunciations(form).each do |pron|
          h[pron.rime] << [outer_w, pron]
        end
      end
    end
    h
  end

  related_rhymes = Hash.new { |h, k| h[k] = [] }
  pair_debug_header_printed = Set.new
  Rhymecrime::Timing.measure("#{timing_base} cohort scan rimes=#{rime_entries.size}") do
    rime_entries.each do |rime, entries|
      rime_dict_lookup(rime).each do |candidate|
        next if forbidden?(candidate)
        next unless inner_set.include?(candidate)

        entries.each do |outer_w, pron|
          next if outer_w == candidate
          next if homophone_rhyme?(candidate, pron)

          w1, w2 =
            if relateds1.size <= relateds2.size
              [outer_w, candidate]
            else
              [candidate, outer_w]
            end

          unless pair_debug_header_printed.include?(w1)
            debug "rhymes for #{w1} (#{debug_info(w1)}):<br>"
            pair_debug_header_printed << w1
          end
          related_rhymes[w1] << w2
          debug " #{w2} #{debug_info(w2)}"
        end
      end
    end
  end

  pairs = []
  related_rhymes.each do |relrhyme1, relrhyme2_list|
    relrhyme2_list.uniq.each { |relrhyme2| pairs.push([relrhyme1, relrhyme2]) }
  end

  Rhymecrime::Timing.measure("#{timing_base} prune pairs=#{pairs.size}") do
    prune_trivial_rhyming_pairs(pairs)
  end
end
