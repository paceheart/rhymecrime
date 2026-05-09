# frozen_string_literal: true


#
# stop words — split by purpose into two disjoint-in-spirit curated lists.
#
#   semantically_promiscuous.txt — content-empty words that "relate to
#       everything" ("could", "perhaps", "henceforth", "thereby"). Kept in
#       word_dict at sentinel-high frequency; relatedness predicates short-
#       circuit them in scoring / display. Predicate: semantically_promiscuous?.
#   unrhymable_stop_words.txt    — function words and contractions ("the",
#       "a", "you'll", "they're", "huh", "uh") that are valid English but
#       make poor rhyme targets. Deleted from word_dict entirely at dict-
#       build time (see delete_unrhymable_stop_words_from_hash in
#       phonology.rb), alongside the forbidden/forbidden_ish rows in
#       curated/rarity.csv (see rarity_csv_forbidden_words). Predicate:
#       unrhymable_stop_word?.
#
# Every runtime call site uses semantically_promiscuous? — unrhymable
# entries are deleted from the dictionary, so they can never appear as a
# headword the relatedness / UI / pruning code might consult. There is no
# stop_word? shim: any leftover call site is a bug we want to find at
# load time, not silently route through a union.
#
# A small overlap (seven entries: "eh", "mhm", "mm", "thees", "thou'd",
# "thou'll", "ye") between the two files is intentional — deletion wins
# (the unrhymable scrub runs before any semantically_promiscuous? check
# the runtime can reach), so they leave the dict and the runtime never
# sees them.
#
# # comment lines and blank lines are skipped; trailing whitespace on each
# entry is stripped (so "hey " in the file matches "hey").

UNRHYMABLE_STOP_WORDS_FILENAME = "unrhymable_stop_words.txt"
SEMANTICALLY_PROMISCUOUS_FILENAME = "semantically_promiscuous.txt"

$unrhymable_stop_words = nil
$semantically_promiscuous_words = nil

# Shared loader for newline-delimited curated word lists. # comment lines
# and blank lines are skipped; trailing whitespace is stripped.
def load_curated_word_set(filename)
  set = Set.new
  path = File.join(CURATED_DIR, filename)
  IoUtils.foreach(path, chomp: true, encoding: "UTF-8", hint: "load_curated_word_set #{filename}") do |line|
    w = line.strip
    next if w.empty? || w.start_with?("#")
    set << w
  end
  set
end

def unrhymable_stop_words
  $unrhymable_stop_words ||= load_curated_word_set(UNRHYMABLE_STOP_WORDS_FILENAME)
end

def unrhymable_stop_word?(word)
  unrhymable_stop_words.include?(word)
end

def semantically_promiscuous_words
  $semantically_promiscuous_words ||= load_curated_word_set(SEMANTICALLY_PROMISCUOUS_FILENAME)
end

# Direct membership in semantically_promiscuous.txt, OR the word's lemma
# is in the list. The lemma fallback lets derived/inflected forms ("abouts",
# "having", "puts") inherit promiscuity from their base ("about", "have",
# "put") without us enumerating every inflection in the curated file.
#
# Safe to call before the lemma map exists on disk (dict-build seed loops in
# frequency.rb / phonology.rb): lemma falls back to lexicon_word_entry
# and ultimately to the word itself, so a missing map just collapses the
# fallback into the direct check we already did.
#
# Build-time interaction: the dict-build seed loop in add_frequency_info
# uses this predicate to stamp 999999 (sentinel-high) frequencies, which
# means the lemma fallback also sweeps in Wiktionary/Kaikki paradigm-noise
# surfaces (gots, alles, nots, theyed, abouts, ...). The
# stopword_inflection_scrub pass right after unrhymable_scrub deletes
# those noise surfaces back out, gated by WordNet / wordfreq-Zipf /
# rarity.csv attestation so legitimate inflections (outing, mostly,
# willing, owned, others) are preserved.
def semantically_promiscuous?(word)
  return true if semantically_promiscuous_words.include?(word)
  base = lemma(word)
  base != word && semantically_promiscuous_words.include?(base)
end

#
# rarity-list-driven word sets — common / rare / forbidden — read from
# curated/rarity.csv (a single CSV is the source of truth, replacing the
# retired common_words.txt, rare_words.txt, and forbid_list.txt).
#
# Per-kind dispatch (matches the spec sweep in spec/rarity_spec.rb and the
# eval scoring buckets):
#   common / common_ish        -> rarity_csv_common_words
#   rare   / rare_ish          -> rarity_csv_rare_words
#   forbidden / forbidden_ish  -> rarity_csv_forbidden_words
# Other kinds (uncommon, common_no_rhymes, rare_no_rhymes,
# have_rhymes) are eval-only labels and contribute nothing to these sets.
#
# Loaded lazily on first access (Set/Array memoized in process-globals) and
# the file is only opened once per process. CSV is parsed with the stdlib
# CSV module — encoding is UTF-8 (matches curated/rarity.csv on disk).
#

RARITY_CSV_PATH = File.join(CURATED_DIR, "rarity.csv")

RARITY_CSV_COMMON_KINDS = %w[common common_ish].freeze
RARITY_CSV_RARE_KINDS = %w[rare rare_ish].freeze
RARITY_CSV_FORBIDDEN_KINDS = %w[forbidden forbidden_ish].freeze

$rarity_csv_common_words = nil
$rarity_csv_rare_words = nil
$rarity_csv_forbidden_words_array = nil
$rarity_csv_forbidden_words_set = nil

def rarity_csv_common_words
  load_rarity_csv_word_sets! if $rarity_csv_common_words.nil?
  $rarity_csv_common_words
end

def rarity_csv_rare_words
  load_rarity_csv_word_sets! if $rarity_csv_rare_words.nil?
  $rarity_csv_rare_words
end

# Forbidden as an Array (insertion order = file order). Old forbid_list
# call sites used Array#include? semantics; preserved here so anything that
# expected an Array surface (e.g. iterations, length) keeps working.
def rarity_csv_forbidden_words
  load_rarity_csv_word_sets! if $rarity_csv_forbidden_words_array.nil?
  $rarity_csv_forbidden_words_array
end

def load_rarity_csv_word_sets!
  require "csv"
  common = Set.new
  rare = Set.new
  forbidden = []
  forbidden_seen = Set.new
  IoUtils.csv_foreach(RARITY_CSV_PATH, headers: true, encoding: "UTF-8", hint: "load_rarity_csv_word_sets!") do |row|
    word = row["word"].to_s.strip
    next if word.empty?
    kind = row["kind"].to_s.strip
    if RARITY_CSV_COMMON_KINDS.include?(kind)
      common << word
    elsif RARITY_CSV_RARE_KINDS.include?(kind)
      rare << word
    elsif RARITY_CSV_FORBIDDEN_KINDS.include?(kind)
      unless forbidden_seen.include?(word)
        forbidden << word
        forbidden_seen << word
      end
    end
  end
  $rarity_csv_common_words = common.freeze
  $rarity_csv_rare_words = rare.freeze
  $rarity_csv_forbidden_words_array = forbidden.freeze
  $rarity_csv_forbidden_words_set = forbidden_seen.freeze
end

#
# forbid_list — facade over rarity_csv_forbidden_words. Kept under the same
# name so legacy call sites (explicitly_forbidden?, audit_word,
# delete_explicitly_forbidden_keys_from_hash, …) don't have to learn about
# the rarity.csv plumbing.
#

def forbid_list
  rarity_csv_forbidden_words
end

# Word consists entirely of non-ASCII bytes (e.g. emoji like '🍇', '🌮', '🧢').
# UTF-8 ASCII chars occupy bytes < 0x80, so a word with no byte < 0x80 has zero
# ASCII characters. Mixed-script borrowings like café / résumé are NOT
# matched (they contain ASCII letters too) — only fully non-ASCII surfaces.
# Empty strings are not considered non-ASCII-only (no characters at all).
def non_ascii_only?(word)
  return false if word.nil? || word.empty?
  word.bytes.all? { |b| b >= 0x80 }
end

# explicitly_forbidden? unifies three policy sources for **dict-build and
# offline tools only** (frequency.rb scrubs, audit_word, specs). It consults
# rarity.csv, non_ascii_only?, and paradigm_noise_inflection? (WordNet-backed
# in local dev). The published Lambda bundle omits corpora/ — do not call
# this from the live rhyme / relatedness pipeline; use forbidden?
# instead.
#
# Policy sources:
#   1. forbidden/forbidden_ish rows in curated/rarity.csv
#   2. non_ascii_only? — zero ASCII bytes (emoji-only surfaces, etc.)
#   3. paradigm_noise_inflection? — paradigm-table noise vs stop/promiscuous lemmas
#
# The build-time forbidden_scrub pass in frequency.rb iterates word_dict keys
# against this predicate so scrubbed surfaces never ship in word_dict.msgpack.
#
# wiktionary_overgenerated_abstract_nesses_plural? is NOT wired here: it
# tombstones in frequency.rb. Same for -ings demote (wiktionary_gerund_overplural_scrub).
def explicitly_forbidden?(word)
  return true if non_ascii_only?(word)
  load_rarity_csv_word_sets! if $rarity_csv_forbidden_words_set.nil?
  return true if $rarity_csv_forbidden_words_set.include?(word)
  paradigm_noise_inflection?(word)
end

# Runtime lexicon gate: true when the surface is absent from the published
# word_dict (never built, tombstoned, or scrubbed at dict-build via
# explicitly_forbidden? and friends). Cheap Hash lookup only — no rarity.csv,
# no WordNet, no paradigm_noise_inflection?.
def forbidden?(word)
  w = word.to_s
  return true if w.empty?

  # Ensure the msgpack-backed lexicon is loaded before answering: without this,
  # word_dict_includes_headword? returns false while $word_dict is still nil and
  # every headword looks forbidden — find_rhyming_tuples then returns [] on the
  # first call in a fresh process (e.g. an isolated rspec example).
  word_dict

  !word_dict_includes_headword?(w)
end

# True when word looks like a Wiktionary/Kaikki paradigm-table inflection
# of a curated stop-word / semantically_promiscuous lemma (theyed <-
# they, gots <- got, nots <- not, abouts <- about, heyed
# <- hey) with no independent corpus attestation — those surfaces are
# theoretical inflections that real English never uses.
#
# Mirrors stopword_inflection_scrub in frequency.rb — same gates, so the
# build-time scrub and the runtime predicate agree on which surfaces are
# forbidden. Critically, this excludes self-listed promiscuous words
# (is, does, its, than, else) — those are legitimate stop-word
# surfaces that the build-time pipeline keeps in word_dict so they remain
# valid as cue inputs to find_rhyming_words, just promiscuous enough to
# not be returned as rhymes for arbitrary cues. Forbidding them outright
# would break the RHYMES tricky / RHYMES apostrophes /
# RHYMES bad pronunciations specs in spec/rhyme_spec.rb.
#
# Returning true forwards through explicitly_forbidden? during dict-build,
# dropping the surface from the generated lexicon without a separate scrub.
def paradigm_noise_inflection?(word)
  return false if word.nil? || word.empty?
  return false if semantically_promiscuous_words.include?(word)
  return false if unrhymable_stop_word?(word)
  return false if wn_has_entry?(word)
  rarity_csv_common_words # load
  rarity_csv_rare_words # load
  return false if $rarity_csv_common_words&.include?(word)
  return false if $rarity_csv_rare_words&.include?(word)
  base = lemma(word)
  return false if base == word
  semantically_promiscuous_words.include?(base) || unrhymable_stop_word?(base)
end

# WordNet noun lexicographer files we treat as "concrete" for the purposes of
# the Wiktionary-overpluralization gates below. Bases whose noun senses span
# at least one of these survive both the -ings demote-to-rare and -nesses
# forbid rules — a concrete sense is what licenses the plural in English
# (you can have multiple mornings/evenings/meetings, multiple
# baronesses/hostesses). Bases whose senses are exclusively in the
# complement (noun.act, noun.attribute, noun.cognition, noun.communication,
# noun.feeling, noun.motive, noun.phenomenon, noun.process, noun.relation,
# noun.state, noun.Tops) read as abstract / mass and the surface is treated
# as paradigm noise.
WN_NOUN_LEXNAME_CONCRETE = Set.new(%w[
  noun.animal
  noun.artifact
  noun.body
  noun.event
  noun.food
  noun.group
  noun.location
  noun.object
  noun.person
  noun.plant
  noun.possession
  noun.quantity
  noun.shape
  noun.substance
  noun.time
]).freeze

# True when base has at least one WordNet noun sense in a concrete-leaning
# lexicographer file (see WN_NOUN_LEXNAME_CONCRETE). Returns false for
# bases not in WordNet or with only abstract senses. Cheap because
# wn_lemma_find_all_cached memoizes per-process.
def wn_base_has_concrete_noun_sense?(base)
  return false if base.nil? || base.empty?
  return false unless wn_has_entry?(base)
  wn_noun_synsets_unified(base).any? do |s|
    WN_NOUN_LEXNAME_CONCRETE.include?(wn_synset_noun_lexname(s))
  end
end

# True when word is a <gerund>s surface (addressings, upswings,
# publishings) that English never actually pluralizes — Wiktionary/Kaikki
# enumerate -s paradigm rows for every gerund-as-noun lemma, so the dict
# inherits bannings, dockings, marketings, pricings, typings etc.
# none of which are real corpus surfaces.
#
# Gates (in order — early-exit cheap):
#   * shape: ends in -ings, base (chomp s) ends in -ing, length >= 6
#   * rarity.csv common/rare rows win (curator's call beats the rule —
#     see the upswings row in curated/rarity.csv)
#   * surface in WordNet (savings, findings, dealings, feelings,
#     proceedings) → preserve
#   * base must be a real gerund (in word_dict) — guards against typos
#     like xxxings where xxxing isn't an attested verb form
#   * base has at least one concrete WN noun sense (morning noun.time,
#     meeting noun.group/event, saving noun.act-or-not — preserved when
#     surface is in WN, otherwise dropped through this gate too) → preserve
#   * otherwise the surface is Wiktionary paradigm noise: word_dict's
#     wiktionary_gerund_overplural_scrub in frequency.rb clamps freq to
#     RARE_FREQ_MAX at build time, so the runtime rare? short-circuit
#     fires naturally without needing a runtime predicate.
#
# Build-time scrub only — not wired into rare? at runtime: the demote
# bakes into the generated word_dict via append_freq_tag!, so the live
# rarity gates read it through plain frequency(word) <= RARE_FREQ_MAX.
def wiktionary_overgenerated_gerund_plural?(word)
  return false if word.nil? || word.empty?
  return false unless word.end_with?("ings")
  return false if word.length < 6
  base = word.chomp("s")
  return false unless base.end_with?("ing")
  rarity_csv_common_words # load
  rarity_csv_rare_words # load
  return false if $rarity_csv_common_words&.include?(word)
  return false if $rarity_csv_rare_words&.include?(word)
  return false if wn_has_entry?(word)
  return false unless word_dict_includes_headword?(base)
  return false if wn_base_has_concrete_noun_sense?(base)
  true
end

# True when word is a <X>nesses surface (abruptnesses, stiffnesses,
# goodnesses) that pluralizes an abstract -ness nominalization — a
# Wiktionary paradigm artifact, since English doesn't pluralize abstract
# qualities. Concrete -ness surfaces survive: baronesses via the WN
# concreteness gate (base baroness is noun.person).
#
# Gates mirror wiktionary_overgenerated_gerund_plural? — same shape /
# rarity.csv / WN structure, just sliced for the -nesses pluralization
# pattern. These are stronger junk than the -ings class — the build-time
# wiktionary_nesses_overplural_scrub in frequency.rb tombstones them
# entirely (vs. the -ings demote-to-rare). Build-time only; omission from
# word_dict is what forbidden? reflects at runtime.
def wiktionary_overgenerated_abstract_nesses_plural?(word)
  return false if word.nil? || word.empty?
  return false unless word.end_with?("nesses")
  return false if word.length < 8
  base = word.sub(/es\z/, "")
  return false unless base.end_with?("ness")
  rarity_csv_common_words # load
  rarity_csv_rare_words # load
  return false if $rarity_csv_common_words&.include?(word)
  return false if $rarity_csv_rare_words&.include?(word)
  return false if wn_has_entry?(word)
  return false unless word_dict_includes_headword?(base)
  return false if wn_base_has_concrete_noun_sense?(base)
  true
end

