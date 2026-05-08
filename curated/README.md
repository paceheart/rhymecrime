# curated/

Hand-edited inputs to RhymeCrime. Everything in this directory is authored
manually, lives nowhere else, and is consumed directly at build time and/or
runtime — distinct from `corpora/` (third-party reference data) and
`generated/` (compiler outputs from `bin/dict-build`).

If you're updating any of these files: keep them lowercased and ASCII unless
otherwise noted, sort word-list lines alphabetically, and prefer one entry per
line so diffs stay small.

## Word lists

The common / rare / forbidden curated word lists used to be three separate
plain-text files (`common_words.txt`, `rare_words.txt`, `forbid_list.txt`).
They were merged into `rarity.csv` (see below) — every previously-listed word
now lives there as a row whose `kind` is one of `common` / `common_ish` /
`rare` / `rare_ish` / `forbidden` / `forbidden_ish`. Both `bin/dict-build`
and the runtime read from `rarity.csv` directly:

  * `common` / `common_ish` rows → the build-time "common floor" (was
    `common_words.txt`); accessor `rarity_csv_common_words`.
  * `rare` / `rare_ish` rows → forced-rare headwords (was `rare_words.txt`);
    accessor `rarity_csv_rare_words`.
  * `forbidden` / `forbidden_ish` rows → headwords deleted from the
    dictionary (was `forbid_list.txt`); accessors
    `rarity_csv_forbidden_words` / `forbid_list()` /
    `explicitly_forbidden?`.

All three accessors live in `lib/rhymecrime/morphology/curated_rarity.rb`. See the
`rarity.csv` section below for column layout, all valid `kind` values, and
how the spec/eval harness consumes the same file.

### Runtime policy

How the three rarity categories interact with the rhyme and relatedness
pipelines:

  * **`common` / `common_ish` — valid both ways.** Get `freq = 99` floored
    in `add_frequency_info` (`lib/rhymecrime/build/frequency.rb`), keep
    their pronunciations and rime cohort, and are eligible to appear in
    every output (rhymes, related lists, rhyming tuples, rhyming pairs).
    Also act as relatedness cues — *unless* the headword is in
    `semantically_promiscuous.txt`, in which case `compute_column_for_goal`
    in `lib/rhymecrime/frontend/frontend.rb` short-circuits the `related` /
    `set_related` / `related_rhymes` / `pair_related` columns with the
    "X is semantically promiscuous; can't compute related words" message.
    The plain rhymes column has no relatedness cue and is unaffected:
    *perhaps* still rhymes with *lapse*.

  * **`rare` / `rare_ish` — valid inputs, suppressed in outputs.** Survive
    the `forbidden_scrub` pass with `freq = 0` and intact prons, so
    `find_rhyming_words` happily processes them as input. The compute cue
    universe in `bin/compute-relatedness` is `cue_word?`
    (`lib/rhymecrime/build/rime.rb`), which requires `freq > RARE_FREQ_MAX`,
    so rare words have no precomputed `related#<lemma>` row: in DDB-
    authoritative mode they yield the "Oops, I don't know what words are
    related to ..." bad-input branch in `rhymecrime` (and a feedback-store
    note via `record_uncomputed_cue!`); local dev lazy-loads the live
    compute pipeline as a fallback. As outputs, rare candidates are
    filtered out of related lists / rhyming tuples / rhyming pairs (every
    pipeline that produces those goes through `common_only: true` either
    at compute time or at the runtime store filter). The lone exception is
    the rhymes column, where `filter_out_rare_words` peels rare rhymes
    into the *"For the desperate:"* dregs block instead of dropping them
    outright.

  * **`forbidden` / `forbidden_ish` — invalid both ways.** Deleted from
    `word_dict` (and therefore every rime cohort) by `forbidden_scrub` in
    `lib/rhymecrime/build/frequency.rb`. `find_rhyming_words`, `has_rhyming_
    word?`, `really_find_rhyming_tuples`, `find_rhyming_pairs`,
    `find_related_words`, and `related?` all guard on `forbidden?` (absent
    from `word_dict`) and return `[]` for those inputs; the `set_related`
    goal renders the curt "I don't like that word." message. Because the
    headword is gone after build, no downstream pipeline can produce a
    forbidden word as an output either.

### `unrhymable_stop_words.txt`

Function words and apostrophe-heavy contractions that are valid English but
would make awful rhyme targets — articles / possessives (`the`, `a`, `my`),
contractions (`he'd've`, `couldn't've`, `they're`), interjections (`huh`,
`mm`, `oh`). **Deleted from `word_dict` entirely** at dict-build time by
`delete_unrhymable_stop_words_from_hash` in `lib/rhymecrime/build/phonology.rb`,
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
`lib/rhymecrime/morphology/curated_rarity.rb`.

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
in the neol-promotion pass of `lib/rhymecrime/build/frequency.rb` to floor the frequency of
recent additions to English so they survive the rare-word threshold and seed
morphological expansion. Plain newline-delimited list. Add words that are
(a) absent from SUBTLEX-US / wordfreq at meaningful frequency, and
(b) common enough in lyrics / modern usage to want a rhyme cohort for.

## Pronunciation overrides

### `authoritative_pronunciations.txt`

Hand-curated CMUdict-format pronunciations that always win over CMU,
Wiktionary/Kaikki, and inflectional fallbacks. Same format as CMUdict
(`WORD  PH PH PH`, `;;;` comments). Loaded as `AUTHORITATIVE_PRONUNCIATIONS_PATH`
in `lib/rhymecrime/build/phonology.rb`; the contract (downstream loaders skip
words listed here) is documented in detail at the load site.

### `spelling.csv`

Manually declared spelling-variant clusters — pairs (or n-tuples) where two
forms mean the same thing AND have the same pronunciation, with the first
column being the preferred surface form. Free-form trailing notes column is
silently dropped at load time (see `split_spelling_row` in
`lib/rhymecrime/morphology/spelling.rb`). Loaded at runtime as
`SPELLING_CSV_PATH`; complemented by automatically-detected morphology pairs
in `corpus_variants.rb` (US/UK -ize/-ise, -oes/-os plurals, …).

## Test / training labels

### `rarity.csv`

Labeled rarity outcomes: `(word, kind, notes)` where `kind ∈ {common,
common_ish, rare, rare_ish, uncommon, forbidden, forbidden_ish,
common_no_rhymes, rare_no_rhymes, have_rhymes}`. The `notes` cell is a
**single line** (no newlines). It begins with the section path used for
nested RSpec grouping (the old `context` column, including ` / `
segments). If there is extra free-form text, it follows ` | ` (space,
pipe, space) — that exact substring must not appear in the section path.
The eval
harness in `spec/rarity_spec.rb` consumes this file directly (sweeps every
row against live `rarity_category`, prints a `FAIL …` line per mismatch, and
gates on a single weighted-pass-rate aggregate spec). It also drives the
rarity classifier training in `bin/train-rarity-classifier`.

The file doubles as the input for the build-time + runtime word lists that
used to live in `common_words.txt` / `rare_words.txt` / `forbid_list.txt`:
`rarity_csv_common_words`, `rarity_csv_rare_words`, and
`rarity_csv_forbidden_words` (in `lib/rhymecrime/morphology/curated_rarity.rb`)
project the matching `kind` rows into Sets. So a row like
`stop words,a,common` with notes beginning `stop words` is consulted by
both the spec sweep AND `add_frequency_info` in
`lib/rhymecrime/build/frequency.rb`. Rows imported from the retired `*.txt`
files use the source filename as the section path and append
`imported from <file>` after ` | `; future edits should pick a more specific
section path if you have one.

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

### `semantic_base.csv`

Semantic-base column expectations from `generated/word_dict`:
`(surface, semantic_base, skip, notes)`. Consumed by
`spec/semantic_base_spec.rb` to assert that `semantic_base(surface) ==
semantic_base` for every row.

## Layout note

This is a flat directory on purpose — these files don't have enough internal
structure to justify subfolders, and a single `curated/` prefix makes
"find every hand-edited input" trivial. New curated inputs should land here
too rather than getting scattered next to the code that loads them.
