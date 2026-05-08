# encoding: utf-8

require_relative "../paths"
require_relative "dict_trace"
require_relative "../wordfreq_zipf_constants"
require "rwordnet"

DICT_BUILD_VERBOSE = false

CORPORA_ROOT = File.join(REPO_ROOT, "corpora")

CMUDICT_FILENAME = File.join(CORPORA_ROOT, "cmudict", "cmudict-0.7c.txt")
# Hand-curated inputs live under curated/; CURATED_DIR is defined in paths.rb
# (parallel to REPO_ROOT / GENERATED_DIR) and shared by every loader. The
# common / rare / forbidden word sets are not surfaced as *_FILENAME
# constants any more — they're consumed by kind out of curated/rarity.csv
# via rarity_csv_common_words / rarity_csv_rare_words /
# rarity_csv_forbidden_words in morphology/curated_rarity.rb.
NEOL2016_FILENAME = File.join(CORPORA_ROOT, "neol", "neol2016.txt")
NEOL_SUPPLEMENT_FILENAME = File.join(CURATED_DIR, "neol_supplement.txt")

WordNet::DB.path = WORDNET_3_1_PATH
SUBTLEX_FILENAME = File.join(CORPORA_ROOT, "subtlex", "SUBTLEXus.tsv")
SUBTLEX_PRESENCE_BONUS = 4

WORDFREQ_FILENAME = File.join(REPO_ROOT, "generated", "wordfreq.tsv")
# OOV headwords with weak SUBTLEX (below SUBTLEX_OVERRIDE_PROPER_MIN): allow wordfreq boost when Zipf is
# clearly conversational web, not just encyclopedic (*poly* ~3.6, *trans* ~4.4 vs surname-fragment band).
WORDFREQ_OOV_STRONG_MODERN_ZIPF = 3.5
# Kaikki inflections of a Wiktionary lemma: rescue at freq==0 disconnect when base Zipf is below
# WORDFREQ_RARE_ZIPF but still shows measurable corpus use (e.g. *throuple* ~1.3 → *throuples*).
WORDFREQ_KAIKKI_FORM_BASE_MIN = 1.0
# SUBTLEX FREQlow this high means sustained lowercase dialogue use — used with weak_lemma_anchor
# and with two-letter all-proper handling below.
SUBTLEX_OVERRIDE_PROPER_MIN = 12
# Two-letter all-proper, single synset: only clear "all proper" when SUBTLEX FREQlow falls in
# this band — high enough for real dialogue (bi ~32) but below nickel-style fragment spam (ni)
# and above iron Fe appearing as dialogue junk (~17).
SUBTLEX_SINGLE_PROPER_OVERRIDE_MIN = 28
SUBTLEX_SINGLE_PROPER_OVERRIDE_MAX = 40
# SUBTLEX-anchored Inflect expansion: minimum raw SUBTLEX FREQlow on a base before it may promote non-list inflections.
MORPH_CORPUS_SUBTLEX_MIN = 40
# Plural :s only: allow WN noun-only bases below the corpus floor when still attested in subtitles
# (e.g. gramophone SUBTLEX 15 → gramophones).
MORPH_LEXICAL_NOUN_PLURAL_SUBTLEX_MIN = 10
# Case-based proper-noun detection (see likely_proper_noun_by_case?).
# SUBTLEX+Kaikki preserve headword case; wordfreq/ConceptNet/Numberbatch do not.
# SUBTLEX FREQcount must reach this many tokens before the capitalized ratio is trusted.
# 10 catches *Brant* 32, *Mong* 17, *Shi* 50, *Strom* 19 while ignoring *convex* (tot 9, legit
# technical term) and single-digit surname fragments with insufficient signal.
SUBTLEX_PROPER_NOUN_MIN_TOTAL = 10
# Fraction of SUBTLEX occurrences that are capitalized, at or above which the word is treated as
# a proper noun: *Cabot* 0.99, *Carlin* 1.0, *Brant* 0.88, *Shi* 0.76, *Strom* 0.74. Real words stay
# below: *hisself* 0.00, *cohosh* 0.00, *hee* 0.43, *aright* 0.53.
SUBTLEX_PROPER_NOUN_RATIO_MIN = 0.7
# Sentence-start capitalization inflates the capitalized ratio for real common words. Additionally,
# common names used in dialogue (*Michael* FREQlow 5, *Italian* 24, *Cajun* 3) need to stay common
# for rhyme coverage. Obscure proper nouns have FREQlow ≤ 2 (*Cabot* 1, *Leicester* 0, *Kant* 0,
# *Lawton* 0, *Mott* 0). Threshold chosen to protect rhyme-worthy names while catching name trickle.
SUBTLEX_PROPER_NOUN_MAX_FREQLOW = 2

# Wiktionary existence floor: skip for 4-letter OOV tokens below this Zipf (*mobo* ~2.5); *yeet* ~2.51 stays eligible.
WIKT_FLOOR_4L_WEAK_ZIPF_BELOW = 2.51
# Wiktionary existence floor: OOV lemmas length ≥5 need Zipf ≥ this (below COMMON; admits *twerk* / *polyamory*).
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
# Singleton rimes are excluded. Buckets where every word is rare (frequency <= RARE_FREQ_MAX) are excluded.
# Buckets with exactly one common *preferred* headword (see preferred_form / spelling_variants) and other partners are excluded.
# Unless INCLUDE_RICH_RHYMES is set, buckets where every pair of common headwords rhymes only as rich rhymes are excluded.
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
