# curated/

Hand-edited inputs to RhymeCrime. Everything in this directory is authored
manually, lives nowhere else, and is consumed directly at build time and/or
runtime — distinct from `corpora/` (third-party reference data) and
`generated/` (compiler outputs from `bin/dict-build`).

If you're updating any of these files: keep them lowercased and ASCII unless
otherwise noted, sort word-list lines alphabetically, and prefer one entry per
line so diffs stay small.

## Word lists

### `common_words.txt`

Headwords that the rare-word filter would otherwise drop but should stay in the
rhyming dictionary anyway (`audiophile`, `cul-de-sac`, `glock`, …). Loaded by
`bin/dict-build` via `COMMON_WORDS_FILENAME` in
`lib/rhymecrime/dict/constants.rb`. Plain newline-delimited list, one word per
line, comments not supported.

### `rare_words.txt`

The inverse: headwords whose corpus frequency is above the rarity floor but
that we want treated as rare anyway — typically place names, surname
fragments, and orthographic ghosts that the rhyme cohorts shouldn't surface.
Loaded as `RARE_WORDS_FILENAME`. Same format as `common_words.txt`.

### `forbid_list.txt`

Headwords that should never appear in the dictionary at all (typos, acronyms
masquerading as words, single-letter junk, etc.). Loaded at runtime by
`forbid_list()` in `lib/rhymecrime/dict/utils_rhyme.rb` and consulted by
`explicitly_forbidden?`. Plain newline-delimited list.

### `unrhymable_stop_words.txt`

Function words and apostrophe-heavy contractions that are valid English but
would make awful rhyme targets — articles / possessives (`the`, `a`, `my`),
contractions (`he'd've`, `couldn't've`, `they're`), interjections (`huh`,
`mm`, `oh`). **Deleted from `word_dict` entirely** at dict-build time by
`delete_unrhymable_stop_words_from_hash` in `lib/rhymecrime/dict/phonology.rb`,
alongside `forbid_list.txt` — the runtime never sees these words as
headwords. Predicate: `unrhymable_stop_word?`. Conceptually parallel to
`forbid_list.txt`: both lists name words to delete, but `forbid_list.txt`
is for "shouldn't be a word at all" (typos, junk acronyms) while
`unrhymable_stop_words.txt` is for "valid word, but useless as a rhyme
target."

### `semantically_promiscuous.txt`

Content-light words ("could", "perhaps", "henceforth", "thereby", "however")
that are valid headwords but are "related to everything" by relatedness
policy. **Kept in `word_dict`** at sentinel-high frequency; the relatedness
predicates short-circuit them in scoring / display (see the
`semantically_promiscuous?` short-circuit in `relatedness/score.rb` and the
"is semantically promiscuous; can't compute related words" abort in
`frontend.rb`). Predicate: `semantically_promiscuous?`. Based loosely on
<https://gist.github.com/sebleier/554280>, with non-promiscuous entries
moved to `unrhymable_stop_words.txt` and local additions.

Both files use `#` for comment / blank lines. Loaded lazily via
`unrhymable_stop_words` / `semantically_promiscuous_words` in
`lib/rhymecrime/dict/utils_rhyme.rb`.

A small overlap (currently seven entries: `eh`, `mhm`, `mm`, `thees`,
`thou'd`, `thou'll`, `ye`) between the two files is intentional and
harmless: deletion wins, so they leave the dict and the runtime never sees
them. There is intentionally **no `stop_word?` union predicate** — every
runtime call site goes through `semantically_promiscuous?` directly, so
missed call sites fail loudly instead of silently picking up unrhymable
entries that were supposed to be deleted.

### `neol_supplement.txt`

Local additions to the 12dicts `neol2016.txt` neologism list (acai,
blockchain, doomscroll, yeet, …) — words that either post-date the 2016
snapshot or were absent from it. Loaded alongside `corpora/neol/neol2016.txt`
in the neol-promotion pass of `lib/rhymecrime/dict/frequency.rb` to floor the frequency of
recent additions to English so they survive the rare-word threshold and seed
morphological expansion. Plain newline-delimited list. Add words that are
(a) absent from SUBTLEX-US / wordfreq at meaningful frequency, and
(b) common enough in lyrics / modern usage to want a rhyme cohort for.

## Pronunciation overrides

### `authoritative_pronunciations.txt`

Hand-curated CMUdict-format pronunciations that always win over CMU,
Wiktionary/Kaikki, and inflectional fallbacks. Same format as CMUdict
(`WORD  PH PH PH`, `;;;` comments). Loaded as `AUTHORITATIVE_PRONUNCIATIONS_PATH`
in `lib/rhymecrime/dict/phonology.rb`; the contract (downstream loaders skip
words listed here) is documented in detail at the load site.

### `spelling.csv`

Manually declared spelling-variant clusters — pairs (or n-tuples) where two
forms mean the same thing AND have the same pronunciation, with the first
column being the preferred surface form. Free-form trailing notes column is
silently dropped at load time (see `split_spelling_row` in
`lib/rhymecrime/dict/utils_rhyme.rb`). Loaded at runtime as
`SPELLING_CSV_PATH`; complemented by automatically-detected morphology pairs
in `corpus_variants.rb` (US/UK -ize/-ise, -oes/-os plurals, …).

## Test / training labels

### `rarity.csv`

Labeled rarity outcomes: `(context, word, kind, important, skip, notes)`
where `kind ∈ {common, common_ish, rare, rare_ish, uncommon, forbidden,
forbidden_ish, common_no_rhymes, rare_no_rhymes, have_rhymes}`. The eval
harness in `spec/rarity_spec.rb` consumes this file directly (sweeps every
row against live `rarity_category`, prints a `FAIL …` line per mismatch, and
gates on a single weighted-pass-rate aggregate spec). It also drives the
rarity classifier training in `bin/train-rarity-classifier`.

### `related.csv`

Labeled cue/target relatedness pairs: `(cue, related, oughta be related?,
notes)` where `oughta be related? ∈ {related, related_ish, unrelated,
unrelated_ish, whatever}`. The relationship is **directional** — "is `related`
a thematic associate of `cue`?" — and `thematically_related?` evaluates that
direction. Consumed by `spec/related_spec.rb` (sweeps every row against the
live directional predicate, prints a `FAIL …` line per mismatch, gates on a
single weighted-pass-rate aggregate spec) and the
`bin/train-relatedness-classifier` training pipeline. The `whatever` label
opts a row out of accuracy scoring when either answer is acceptable.

### `lemma.csv`

Lemma-column expectations from `generated/word_dict`:
`(surface, lemma, skip, notes)`. Consumed by `spec/lemma_spec.rb` to assert
that `lemma(surface) == lemma` for every row.

## Layout note

This is a flat directory on purpose — these files don't have enough internal
structure to justify subfolders, and a single `curated/` prefix makes
"find every hand-edited input" trivial. New curated inputs should land here
too rather than getting scattered next to the code that loads them.
