# encoding: utf-8

require_relative "utils_rhyme"
require "rwordnet"

# Trace headword(s) through dict-build (frequency, CMU ingest, rime, disconnect, …).
# Comma/space/semicolon-separated lists in +DICT_TRACE_WORDS+ and/or +TRACE_WORDS+ (merged and uniq’d).
#
# Examples:
#   TRACE_WORDS=kitchening ./bin/dict-build
#   TRACE_WORDS="kitchening,puffin" ./bin/dict-build
#   DICT_TRACE_WORDS="foo bar;baz" ./bin/dict-build
_parse_trace_words = ->(str) { str.to_s.split(/[\s,;]+/).map(&:strip).reject(&:empty?) }

TRACE_WORDS = (_parse_trace_words[ENV["DICT_TRACE_WORDS"]] + _parse_trace_words[ENV["TRACE_WORDS"]]).uniq.freeze

def dict_trace_word?(word)
  !TRACE_WORDS.empty? && TRACE_WORDS.include?(word)
end

# Phase 8 / 10 / 11: +base+ → +infl+ inflection row touches any word in +TRACE_WORDS+.
def dict_trace_morph?(base, infl)
  return false if TRACE_WORDS.empty?

  TRACE_WORDS.include?(base) || TRACE_WORDS.include?(infl)
end

# Phase 9: hash key +word+, common_words candidate +listed+, morph +base+ → +infl+.
def dict_trace_phase9?(word, listed, base, infl)
  return false if TRACE_WORDS.empty?

  TRACE_WORDS.include?(word) || TRACE_WORDS.include?(listed) || TRACE_WORDS.include?(base) || TRACE_WORDS.include?(infl)
end

# CMU line preprocessing: line changed and mentions a traced substring (token is first field).
def dict_trace_preprocess_line?(original_line, line)
  return false if TRACE_WORDS.empty? || line == original_line

  TRACE_WORDS.any? { |w| line.include?(w) }
end

# +body+ must not include a leading "TRACE". Pass +word+ to print +TRACE(word)+ before the message;
# pass nil or "" for an unscoped +TRACE+ line only.
def dict_trace_format(word, body)
  b = body.to_s
  w = word.is_a?(String) && !word.empty? ? word : nil
  w ? "TRACE(#{w}) #{b}" : "TRACE #{b}"
end

def dict_trace_puts(word, body)
  puts dict_trace_format(word, body)
end

# Exported +word_dict+ / +rdict+ include rare headwords (frequency ≤ +RARE_FREQ_MAX+) only when set truthy.
# Default false: after dict-build, rare rows are dropped and the rime index is re-pruned (smaller artifacts).
# Rebuild with INCLUDE_RARE_WORDS=1 before running rarity specs that expect rare rows in +word_dict+.
def include_rare_words_in_exported_lexicon?
  v = ENV["INCLUDE_RARE_WORDS"]
  return false if v.nil? || v.empty?
  %w[1 true yes on].include?(v.downcase)
end

DICT_BUILD_VERBOSE = false

CORPORA_ROOT = File.join(REPO_ROOT, "corpora")

CMUDICT_FILENAME = File.join(CORPORA_ROOT, "cmudict", "cmudict-0.7c.txt")
RARE_WORDS_FILENAME = "rare_words.txt"
COMMON_WORDS_FILENAME = "common_words.txt"

WordNet::DB.path = File.join(CORPORA_ROOT, "wordnet", "3.1")
SUBTLEX_FILENAME = File.join(CORPORA_ROOT, "subtlex", "SUBTLEXus.tsv")
SUBTLEX_PRESENCE_BONUS = 4

WORDFREQ_FILENAME = File.join(REPO_ROOT, "generated", "wordfreq.tsv")
WORDFREQ_COMMON_ZIPF = 3.0
# OOV headwords with weak SUBTLEX (below +SUBTLEX_OVERRIDE_PROPER_MIN+): allow wordfreq boost when Zipf is
# clearly conversational web, not just encyclopedic (*poly* ~3.6, *trans* ~4.4 vs surname-fragment band).
WORDFREQ_OOV_STRONG_MODERN_ZIPF = 3.5
WORDFREQ_RARE_ZIPF = 2.0
# Kaikki inflections of a Wiktionary lemma: rescue at freq==0 disconnect when base Zipf is below
# +WORDFREQ_RARE_ZIPF+ but still shows measurable corpus use (e.g. *throuple* ~1.3 → *throuples*).
WORDFREQ_KAIKKI_FORM_BASE_MIN = 1.0
# SUBTLEX FREQlow this high means sustained lowercase dialogue use — used with weak_lemma_anchor
# and with two-letter all-proper handling below.
SUBTLEX_OVERRIDE_PROPER_MIN = 12
# Two-letter all-proper, single synset: only clear "all proper" when SUBTLEX FREQlow falls in
# this band — high enough for real dialogue (bi ~32) but below nickel-style fragment spam (ni)
# and above iron Fe appearing as dialogue junk (~17).
SUBTLEX_SINGLE_PROPER_OVERRIDE_MIN = 28
SUBTLEX_SINGLE_PROPER_OVERRIDE_MAX = 40
# Phase 11: minimum raw SUBTLEX FREQlow on a base before it may promote non-list inflections.
MORPH_CORPUS_SUBTLEX_MIN = 40
# Plural :s only: allow WN noun-only bases below the corpus floor when still attested in subtitles
# (e.g. gramophone SUBTLEX 15 → gramophones).
MORPH_LEXICAL_NOUN_PLURAL_SUBTLEX_MIN = 10
# Phase 6: skip Wiktionary floor for 4-letter OOV tokens below this Zipf (*mobo* ~2.5); *yeet* ~2.51 stays eligible.
WIKT_FLOOR_4L_WEAK_ZIPF_BELOW = 2.51
# Phase 6: OOV lemmas length ≥5 need Zipf ≥ this for the existence floor (below COMMON; admits *twerk* / *polyamory*).
WIKT_FLOOR_LONG_OOV_MIN_ZIPF = 2.2

RIME_DICT_HEADER = "# RhymeCrime's rime dictionary
# https://github.com/paceheart/rhymecrime
#
# Built by the dictionary compiler (see dict.rb, phonology.rb, rime.rb).
#
# Each line is of the form:
#
# RIME  WORD1 WORD2 WORD3 ...
#
# where RIME is an underscore-concatenated ARPABET encoding of phonemes
# from the head vowel of the prosodic head through word end (see Pronunciation#rime_array).
#
# This data is automatically distilled from a forked version of the
# CMU Pronouncing Dictionary, with some manual tweaks and some
# programmatic preprocessing as described in the dict/ Ruby sources.
#
# Singleton rimes are excluded. Buckets with at most one common headword (frequency > RARE_FREQ_MAX) are excluded
# (all-rare buckets, one common among rares, or a lone common) so rhyme cohorts always offer ≥2 common partners.
#"

WORD_DICT_HEADER = "# RhymeCrime's word info dictionary
# https://github.com/paceheart/rhymecrime
#
# Built by the dictionary compiler (see dict.rb, frequency.rb).
#
# Each line is of the form:
#
# WORD,FREQUENCY,PRONUNCIATION1|PRONUNCIATION2...[,LEMMA]
#
# LEMMA is the base/uninflected form (omitted when same as WORD).
#
#"
