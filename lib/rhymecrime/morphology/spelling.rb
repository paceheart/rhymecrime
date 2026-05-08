# frozen_string_literal: true

#
# spelling variants
#

# CMU-style compounds use hyphens; Numberbatch, ConceptNet /c/en/, etc. use underscores.
def hyphens_to_underscores(word)
  word.to_s.tr("-", "_")
end

$variants = nil

# Cleared when spelling-variant file is reloaded or word_dict is re-read.
def clear_spelling_variant_hyphen_caches!
  @hyphen_multi_fold = nil
end

def variants()
  # hash: word -> [preferred_form alternate_form1 alternate_form2 ...]
  if $variants.nil?
    clear_spelling_variant_hyphen_caches!
    $variants = load_variants
  end
  return $variants
end

# US/UK -ize ↔ -ise (and -yze ↔ -yse) morphology: generate UK (s) from US (z) only.
# UK spellings map back to US as preferred only when that US headword exists in $word_dict
# (e.g. compromise has no valid *compromize*, so it is left alone—no blocklist needed).
US_UK_YZE_SUFFIXES = [
  ["yzing", "ysing"],
  ["yzes", "yses"],
  ["yzed", "ysed"],
  ["yze", "yse"],
].freeze

US_UK_IZE_SUFFIXES = [
  ["ization", "isation"],
  ["izations", "isations"],
  ["izable", "isable"],
  ["izer", "iser"],
  ["izers", "isers"],
  ["izing", "ising"],
  ["izes", "ises"],
  ["ized", "ised"],
  ["ize", "ise"],
].freeze

# Real -ize words that are not US verb morphology (avoid analyze→analyse style false path for "size", etc.).
US_UK_IZE_ZONLY_EXCEPTIONS = %w[size seize capsize prize maize].freeze

def word_dict_includes_headword?(w)
  return false unless defined?($word_dict) && $word_dict.is_a?(Hash) && !$word_dict.empty?
  entry = $word_dict[w]
  return false if entry.nil?
  # During build_word_dict (the defer-rarity-losses window between scrubs
  # and finalize_build_entries!), entries marked for tombstoned are
  # still physically in $word_dict but are logically absent. Preferred-form
  # / spelling-variant / US-UK mapping callers must treat them as
  # non-existent so they don't anoint a half-scrubbed row as the preferred
  # surface of a live sibling (e.g. "flors" from flour→flor where flors
  # only exists because SUBTLEX happened to list it and a later scrub had
  # already marked it for deletion).
  return false if defined?(BuildEntry) && entry.is_a?(BuildEntry) && entry.tombstoned?
  true
end

# Like word_dict_includes_headword? but also requires that the entry carries at least one
# pronunciation. Used by US/UK variant-pair detection to avoid anointing frequency-only ghost
# entries (expertize, favorize, criticize/criticise mispairings, etc.) as the
# preferred form of a well-pronounced counterpart: a prefix-less entry with empty prons
# can't rhyme, so making it the canonical surface strands the real word in no cohort.
def word_dict_includes_pronounced_headword?(w)
  return false unless defined?($word_dict) && $word_dict.is_a?(Hash) && !$word_dict.empty?
  entry = $word_dict[w]
  return false unless entry
  # Same rationale as word_dict_includes_headword?: tombstoned
  # entries are logically absent during the build-time window.
  return false if defined?(BuildEntry) && entry.is_a?(BuildEntry) && entry.tombstoned?
  prons = entry[1]
  prons.is_a?(Array) && !prons.empty?
end

# Lexicon headwords (+ optional WORDS_NEEDED_FOR_TESTING). When include_rhymeless is false,
# keep only words for which has_rhyming_word? is true. When common_only is true, drop rare?
# headwords (frequency at or below RARE_FREQ_MAX). Both predicates need query.rb loaded.
#
# Memoized per (include_rhymeless, common_only) flag combination (4 possible
# keys total) because the hot path in bin/compute-relatedness calls
# words_we_care_about(false, true) once per cue (~4000x per worker), and
# rebuilding the ~20k-element filtered list — which includes a
# has_rhyming_word? pronunciations / rime_dict probe per candidate — dominated
# the per-cue overhead. word_dict is loaded once and treated as immutable
# at runtime, so the memo is safe; dict-build scripts that mutate
# word_dict do not call this function.
#
# The parent in bin/compute-relatedness primes this memo before fork
# so all worker processes inherit the filled entry via copy-on-write instead
# of each rebuilding it from scratch.
$words_we_care_about_memo = {}
def words_we_care_about(include_rhymeless = true, common_only = false)
  cache_key = [include_rhymeless, common_only]
  cached = $words_we_care_about_memo[cache_key]
  return cached if cached

  keys = word_dict.keys
  keys |= WORDS_NEEDED_FOR_TESTING if defined?(WORDS_NEEDED_FOR_TESTING)
  keys = keys.uniq
  keys = keys.select { |w| has_rhyming_word?(w) } unless include_rhymeless
  keys = keys.reject { |w| rare?(w) } if common_only
  $words_we_care_about_memo[cache_key] = keys.freeze
end

# Returns UK spelling for a US (z) headword, or nil if not applicable.
def us_to_uk_ize_spelling(us_word)
  w = us_word.to_s
  return nil if w.empty?
  US_UK_YZE_SUFFIXES.each do |us_s, uk_s|
    next unless w.end_with?(us_s)
    return w[0...-us_s.length] + uk_s
  end
  return nil if US_UK_IZE_ZONLY_EXCEPTIONS.include?(w)
  US_UK_IZE_SUFFIXES.each do |us_s, uk_s|
    next unless w.end_with?(us_s)
    stem = w[0...-us_s.length]
    # Not *-isable (UK is "sizeable" with e, not "sisable").
    return "sizeable" if us_s == "izable" && stem == "siz"
    return stem + uk_s
  end
  nil
end

# Inverse of us_to_uk_ize_spelling (for matching a UK surface form); does not validate English.
def uk_to_us_ize_spelling(uk_word)
  w = uk_word.to_s
  return nil if w.empty?
  US_UK_YZE_SUFFIXES.each do |us_s, uk_s|
    next unless w.end_with?(uk_s)
    return w[0...-uk_s.length] + us_s
  end
  US_UK_IZE_SUFFIXES.each do |us_s, uk_s|
    next unless w.end_with?(uk_s)
    return w[0...-us_s.length] + us_s
  end
  nil
end

# [us_form, uk_form] with US first; nil if not an -ize/-ise pair we handle.
def us_uk_ize_pair(word)
  w = word.to_s
  return nil if w.empty?
  uk = us_to_uk_ize_spelling(w)
  if uk && uk != w
    return [w, uk]
  end
  us = uk_to_us_ize_spelling(w)
  # Require a pronounced US counterpart: rejects frequency-only ghosts like expertize that
  # would otherwise be crowned the canonical form of a real word (expertise) and strand it
  # from every rime cohort.
  if us && us != w && word_dict_includes_pronounced_headword?(us) && us_to_uk_ize_spelling(us) == w
    return [us, w]
  end
  nil
end

# US/UK -or ↔ -our (behavior/behaviour, color/colour, …). Longest suffix first; both spellings
# must exist in $word_dict (avoids tor/tour, for/four, contour, …).
US_UK_OR_SUFFIXES = [
  ["iors", "iours"],
  ["ior", "iour"],
  ["orites", "ourites"],
  ["oring", "ouring"],
  ["ored", "oured"],
  ["ors", "ours"],
  ["orite", "ourite"],
  ["orous", "ourous"],
  ["or", "our"],
].freeze

US_UK_OR_MIN_WORD_LENGTH = 5

def us_to_uk_or_spelling(us_word)
  w = us_word.to_s
  return nil if w.length < US_UK_OR_MIN_WORD_LENGTH
  US_UK_OR_SUFFIXES.sort_by { |us_s, _uk| [-us_s.length, us_s] }.each do |us_s, uk_s|
    next unless w.end_with?(us_s)
    return w[0...-us_s.length] + uk_s
  end
  nil
end

def uk_to_us_or_spelling(uk_word)
  w = uk_word.to_s
  return nil if w.length < US_UK_OR_MIN_WORD_LENGTH
  US_UK_OR_SUFFIXES.sort_by { |_us, uk_s| [-uk_s.length, uk_s] }.each do |us_s, uk_s|
    next unless w.end_with?(uk_s)
    return w[0...-uk_s.length] + us_s
  end
  nil
end

def us_uk_or_pair(word)
  w = word.to_s
  return nil if w.length < US_UK_OR_MIN_WORD_LENGTH
  uk = us_to_uk_or_spelling(w)
  if uk && uk != w && uk.length >= US_UK_OR_MIN_WORD_LENGTH && word_dict_includes_pronounced_headword?(w) && word_dict_includes_pronounced_headword?(uk) && uk_to_us_or_spelling(uk) == w
    return [w, uk]
  end
  us = uk_to_us_or_spelling(w)
  if us && us != w && us.length >= US_UK_OR_MIN_WORD_LENGTH && word_dict_includes_pronounced_headword?(w) && word_dict_includes_pronounced_headword?(us) && us_to_uk_or_spelling(us) == w
    return [us, w]
  end
  nil
end

# US/UK -er ↔ -re (center/centre, fiber/fibre, …). Longest suffix first; both spellings in $word_dict;
# stem before the matched suffix must end in a consonant and have length ≥ 3 (avoids acre/acer, etc.).
US_UK_ER_RE_SUFFIXES = [
  ["ering", "ring"],
  ["ered", "red"],
  ["ers", "res"],
  ["er", "re"],
].freeze

US_UK_ER_RE_MIN_WORD_LENGTH = 5

def us_to_uk_er_re_spelling(us_word)
  w = us_word.to_s
  return nil if w.length < US_UK_ER_RE_MIN_WORD_LENGTH
  US_UK_ER_RE_SUFFIXES.sort_by { |us_s, _uk| [-us_s.length, us_s] }.each do |us_s, uk_s|
    next unless w.end_with?(us_s)
    stem = w[0...-us_s.length]
    next unless stem.match?(/[bcdfghjklmnpqrstvwxyz]\z/i)
    next if stem.length < 3
    return stem + uk_s
  end
  nil
end

def uk_to_us_er_re_spelling(uk_word)
  w = uk_word.to_s
  return nil if w.length < US_UK_ER_RE_MIN_WORD_LENGTH
  US_UK_ER_RE_SUFFIXES.sort_by { |_us, uk_s| [-uk_s.length, uk_s] }.each do |us_s, uk_s|
    next unless w.end_with?(uk_s)
    stem = w[0...-uk_s.length]
    next unless stem.match?(/[bcdfghjklmnpqrstvwxyz]\z/i)
    next if stem.length < 3
    return stem + us_s
  end
  nil
end

def us_uk_er_re_pair(word)
  w = word.to_s
  return nil if w.length < US_UK_ER_RE_MIN_WORD_LENGTH
  uk = us_to_uk_er_re_spelling(w)
  if uk && uk != w && uk.length >= US_UK_ER_RE_MIN_WORD_LENGTH && word_dict_includes_pronounced_headword?(w) && word_dict_includes_pronounced_headword?(uk) && uk_to_us_er_re_spelling(uk) == w
    return [w, uk]
  end
  us = uk_to_us_er_re_spelling(w)
  if us && us != w && us.length >= US_UK_ER_RE_MIN_WORD_LENGTH && word_dict_includes_pronounced_headword?(w) && word_dict_includes_pronounced_headword?(us) && us_to_uk_er_re_spelling(us) == w
    return [us, w]
  end
  nil
end

# US/UK consonant-doubling before a vowel-initial suffix on verbs ending in -l
# (barreled/barrelled, traveling/travelling, modeler/modeller, marvelous/marvellous, counselor/
# counsellor, …). US keeps a single l; UK doubles it. The pseudo-base (word minus the vowel
# suffix, ending in a single l) must itself be a headword in $word_dict, which guards against
# silent-e collisions (filed/filled, tiled/tilled, smiled/smilled, …) and unrelated ll-words
# (called/caled, pulled/puled, boiled/boilled, …). As an extra safety belt the silent-e form
# (pseudo-base with the trailing l replaced by "e") must NOT be a headword; this rejects the
# rare cases where the naked pseudo-base happens to be in the dictionary but the "real" base
# is the silent-e verb (e.g. "til" exists but the derivation is from "tile").
US_UK_LL_VOWEL_SUFFIXES = %w[ing ers est ors ous ed er or].freeze

US_UK_LL_MIN_WORD_LENGTH = 6
US_UK_LL_MIN_PSEUDO_BASE_LENGTH = 3

# Parse word as either the US or UK shape of an -l-/-ll- doubling pair. Returns
# [us_suffix_sliced_base_ending_in_single_l, matched_vowel_suffix] on match, nil otherwise.
# The returned base always ends in a single "l" (never "ll") and is at least
# US_UK_LL_MIN_PSEUDO_BASE_LENGTH characters long.
def us_uk_ll_parse(word)
  w = word.to_s
  return nil if w.length < US_UK_LL_MIN_WORD_LENGTH
  US_UK_LL_VOWEL_SUFFIXES.sort_by { |s| [-s.length, s] }.each do |suf|
    next unless w.end_with?(suf)
    trunc = w[0...-suf.length]
    if trunc.end_with?("ll") && !trunc.end_with?("lll")
      pseudo_base = trunc[0...-1]
    elsif trunc.end_with?("l") && !trunc.end_with?("ll")
      pseudo_base = trunc
    else
      next
    end
    next if pseudo_base.length < US_UK_LL_MIN_PSEUDO_BASE_LENGTH
    return [pseudo_base, suf]
  end
  nil
end

# Reject (filed, filled)-style collisions where the "real" base is a silent-e verb rather than
# the naked pseudo-base ending in -l. See US_UK_LL_VOWEL_SUFFIXES comment for the full rationale.
def us_uk_ll_pseudo_base_acceptable?(pseudo_base)
  return false if pseudo_base.length < US_UK_LL_MIN_PSEUDO_BASE_LENGTH
  return false unless word_dict_includes_headword?(pseudo_base)
  return false if word_dict_includes_headword?(pseudo_base[0...-1] + "e")
  true
end

def us_uk_ll_pair(word)
  w = word.to_s
  return nil if w.length < US_UK_LL_MIN_WORD_LENGTH
  parsed = us_uk_ll_parse(w)
  return nil unless parsed
  pseudo_base, suf = parsed
  return nil unless us_uk_ll_pseudo_base_acceptable?(pseudo_base)

  us = pseudo_base + suf
  uk = pseudo_base + "l" + suf
  return nil if us == uk
  return nil unless word_dict_includes_pronounced_headword?(us) && word_dict_includes_pronounced_headword?(uk)

  [us, uk]
end

def us_uk_morphology_pair(word)
  us_uk_ize_pair(word) || us_uk_or_pair(word) || us_uk_er_re_pair(word) || us_uk_ll_pair(word)
end

def us_uk_morphology_variant_forms(word)
  pair = us_uk_morphology_pair(word)
  return nil unless pair
  u, k = pair
  k == u ? [u] : [u, k]
end

# Shape-only match of word as the -oes or -os surface of an -o noun's plural. Returns
# [oes_form, os_form] when the pattern matches, nil otherwise. Used by the build-time
# corpus variant emitter (build/corpus_variants.rb); runtime consumption of the resolved
# pairs goes through variants() via the generated spelling_variants_auto.txt so no
# corpus I/O leaks into the runtime path.
O_PLURAL_MIN_WORD_LENGTH = 4

def o_plural_candidate_pair(word)
  w = word.to_s
  return nil if w.length < O_PLURAL_MIN_WORD_LENGTH
  if w.end_with?("oes")
    os = w[0...-2] + "s" # "tomatoes" → "tomatos"
    return nil if os == w
    return [w, os]
  end
  if w.end_with?("os") && !w.end_with?("oos")
    oes = w[0...-1] + "es" # "tomatos" → "tomatoes"
    return nil if oes == w
    return [oes, w]
  end
  nil
end

# Fold for grouping hyphen-insensitive spellings (in-laws ↔ inlaws).
def spelling_variant_hyphen_fold(w)
  w.to_s.downcase.delete("-")
end

# Only folds with 2+ distinct surface forms (tiny hash vs. one entry per word).
VALID_HYPHEN_LEXEME_RE = /\A[[:alpha:]][[:alnum:]_'-]*\z/.freeze
NON_HYPHEN_PREF_RE = /\Anon-[[:alnum:]]/i.freeze

# First segment of phrasal-style hyphen compounds (in-laws, on-site, hand-out). Longest token first in the regex.
HYPHEN_COMPOUND_LEADING_PARTICLES = %w[down in off on out up].freeze
PARTICLE_HYPHEN_PREF_RE = Regexp.new(
  "\\A(?:#{HYPHEN_COMPOUND_LEADING_PARTICLES.sort_by { |t| [-t.length, t] }.join('|')})-[[:alpha:]]",
  Regexp::IGNORECASE
).freeze

# Hyphenated forms whose two halves exhibit a phonological echo characteristic of a
# reduplication (boo-boo, zig-zag, flip-flop, hodge-podge, super-duper) are preferred
# in their hyphenated spelling over the solid alternative. We require a *positive*
# reduplication signal — identical halves, ablaut (vowels-only differences), or a
# rhyming pair (shared trailing rime + consonant onsets) — rather than the earlier
# rule of "anything two-real-words-glued-with-a-hyphen", which over-fired on the
# very common N+N closed-compound case (back-hand → backhand, foot-fall → footfall,
# pine-cone → pinecone, air-port → airport, bath-room → bathroom, ...). Curated
# exceptions where the hyphenated form should win despite no echo (low-key, wi-fi,
# fine-tune, ...) belong in curated/spelling.csv, which is consulted before this.
REDUP_STYLE_SINGLE_HYPHEN_RE = /\A[[:alpha:]]{2,}-[[:alpha:]]{2,}\z/.freeze
# Second-segment matches here → prefer solid spelling (handout not hand-out). Omits on (no common *-on tail).
HYPHEN_COMPOUND_TRAILING_PARTICLES_SOLID_PREF =
  (HYPHEN_COMPOUND_LEADING_PARTICLES - %w[on]).freeze

REDUP_VOWEL_RE = /[aeiouy]/.freeze
REDUP_CONSONANT_ONSET_RE = /\A[bcdfghjklmnpqrstvwxyz]*\z/.freeze

def hyphen_redup_prefers_hyphenated_form?(f)
  return false unless REDUP_STYLE_SINGLE_HYPHEN_RE.match?(f)
  left, right = f.split("-", 2)
  left = left.downcase
  right = right.downcase
  return false if COMMON_PREFIXES.include?(left)
  return false if HYPHEN_COMPOUND_TRAILING_PARTICLES_SOLID_PREF.include?(right)
  hyphen_redup_halves_echo?(left, right)
end

# True when left and right exhibit one of the three phonological echoes of a
# reduplication: identical halves (boo-boo, ha-ha), ablaut (same length, identical
# consonant skeleton, only vowels differ — zig-zag, flip-flop, criss-cross,
# wishy-washy), or a rhyming pair (same length, shared rightmost segment ≥ 2 chars
# containing a vowel, and any leading non-shared chars on either half are all
# consonants — hodge-podge, hub-bub, pee-wee, super-duper, mumbo-jumbo, walkie-talkie).
# Returns false on plain N+N compounds whose halves happen to share a final consonant
# or differ in length (back-hand, foot-fall, back-track, pine-cone, low-key, wi-fi).
def hyphen_redup_halves_echo?(left, right)
  return true if left == right
  return false unless left.length == right.length
  hyphen_redup_ablaut?(left, right) || hyphen_redup_rhyme?(left, right)
end

def hyphen_redup_ablaut?(left, right)
  diffs = 0
  i = 0
  n = left.length
  while i < n
    lc = left[i]
    rc = right[i]
    if lc != rc
      return false unless REDUP_VOWEL_RE.match?(lc) && REDUP_VOWEL_RE.match?(rc)
      diffs += 1
    end
    i += 1
  end
  diffs >= 1
end

def hyphen_redup_rhyme?(left, right)
  shared = 0
  i = left.length - 1
  while i >= 0 && left[i] == right[i]
    shared += 1
    i -= 1
  end
  return false if shared < 2
  return false if shared == left.length # identical halves; handled by caller
  return false unless REDUP_VOWEL_RE.match?(left[-shared..])
  left_onset = left[0...(left.length - shared)]
  right_onset = right[0...(right.length - shared)]
  REDUP_CONSONANT_ONSET_RE.match?(left_onset) && REDUP_CONSONANT_ONSET_RE.match?(right_onset)
end

def ingest_word_into_hyphen_fold_buckets!(buckets, w)
  return if w.nil? || w.empty?
  return unless w.match?(VALID_HYPHEN_LEXEME_RE)
  fold = w.downcase.delete("-")
  (buckets[fold] ||= Set.new) << w
end

# Build { fold => [form, ...] } only where multiple spellings share a fold.
# explicit_word_keys: enumerable of headwords (e.g. word_dict.keys) when building during dict.rb;
# otherwise uses $word_dict or scans word_dict.txt (fallback when JSON cache is missing).

SPELLING_CSV_PATH = File.join(CURATED_DIR, "spelling.csv")

# A spelling.csv column counts as a word-form (rather than a free-text notes value)
# when it consists entirely of letters, hyphens, and apostrophes (e.g. color,
# 'til, rock'n'roll, acknowledgement). Anything containing whitespace, digits,
# #, or other punctuation is treated as the start of the optional notes column.
SPELLING_CSV_FORM_RE = /\A['[:alpha:]][[:alpha:]'\-]*\z/

# Split a comma-separated spelling.csv row into [forms, notes_or_nil].
# Forms are stripped and consumed left-to-right until the first column that does
# not look like a word-form (per SPELLING_CSV_FORM_RE); from there to end-of-line
# is the notes payload, rejoined with commas so embedded commas inside notes survive.
def split_spelling_row(line)
  raw = line.split(",")
  forms = []
  notes_start = nil
  raw.each_with_index do |col, i|
    stripped = col.strip
    if stripped.empty?
      forms << stripped # let downstream strip empties; an early empty stays a column boundary
      next
    end
    if stripped =~ SPELLING_CSV_FORM_RE
      forms << stripped
    else
      notes_start = i
      break
    end
  end
  forms = forms.reject(&:empty?)
  notes = notes_start ? raw[notes_start..].join(",").strip : nil
  [forms, notes]
end

# Returns an array of form-arrays: each inner array is [preferred, alt1[, alt2, ...]].
# Sources, in load order (later sources OVERRIDE earlier ones because load_variants
# does last-write-wins per surface form):
#   * generated/spelling_variants_auto.txt — emitted by dict-build, whitespace-separated
#                                   preferred alt pairs. Optional (skipped when missing,
#                                   e.g. on a fresh checkout before the first build).
#   * curated/spelling.csv     — hand-edited list, CSV (comma-separated) with # comment
#                                   header lines and an optional trailing free-text notes
#                                   column (silently dropped at load time; see
#                                   split_spelling_row).
# Curated MUST come last: detectors in emit_spelling_variants_auto! sometimes pick the
# opposite preference direction from the human-curated list (corpus Zipf can favor adapter
# over adaptor, ax over axe, disc over disk, mamma over mama) and we want the
# hand-edited choice to win for any pair that appears in both files.
#
# Comment lines (starting with #) and lines that don't begin with an alphabetic character
# are skipped at parse time, matching the legacy /A[[:alpha:]]/ filter.
def load_variants_raw
  result = []
  auto_path =
    if bootstrap_mode?
      nil
    elsif rhymecrime_build_dir
      generated_bootstrap_path(SPELLING_VARIANTS_AUTO_FILENAME)
    else
      generated_dict_path(SPELLING_VARIANTS_AUTO_FILENAME)
    end
  if auto_path && File.exist?(auto_path)
    IoUtils.foreach(auto_path, chomp: true, encoding: "UTF-8", hint: "load_variants_raw spelling_variants_auto") do |line|
      next unless line =~ /\A[[:alpha:]]/
      forms = line.split.map(&:strip).reject(&:empty?)
      result << forms unless forms.empty?
    end
  end
  IoUtils.foreach(SPELLING_CSV_PATH, chomp: true, encoding: "UTF-8", hint: "load_variants_raw spelling.csv") do |line|
    next unless line =~ /\A[[:alpha:]]/
    forms, _notes = split_spelling_row(line)
    result << forms unless forms.empty?
  end
  result
end

def load_variants
  hash = {}
  load_variants_raw.each do |forms|
    forms.each { |word| hash[word] = forms }
  end
  hash
end
