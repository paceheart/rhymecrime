# RhymeCrime
Find thematically related rhymes

## Installation

Prereqs: Ruby (see `template.yaml` for the AWS Lambda runtime version), Bundler, Python 3 (for the wordfreq export), `curl`, and `gunzip`.

```bash
git clone https://github.com/paceheart/rhymecrime/
cd rhymecrime
./setup.sh             # bundle install + download corpora + bin/dict-build
bundle exec rspec      # all tests should pass
```

`setup.sh` is idempotent: corpus downloads are skipped if the destination file already exists, so re-running during iteration only redoes the dict build. See `setup.sh` for the full list of corpora and their licenses.

## Repository layout

Data and build artifacts are split so **sources** stay under `corpora/` and **regenerable caches** under `generated/` at the repo root. Ruby code resolves paths via `REPO_ROOT` / `GENERATED_DIR` in `lib/rhymecrime/dict/utils_rhyme.rb`, so loading works even when the process cwd is not the repository root (e.g. CGI).

| Location | Role |
|----------|------|
| **`lib/`** | On the load path. `lib/rhymecrime.rb` defines `Rhymecrime::ROOT`; application code lives under **`lib/rhymecrime/`** (`crime.rb`, `related.rb`, `frontend.rb`, helpers, and the **`dict/`** subtree). Use `require "rhymecrime/..."` from `bin/` and specs (after unshifting `lib/`). |
| **`bin/`** | **Executables**: `rhyme.rb`, `similar.rb`, `debug.rb`, `anneal.rb`, `dict-build` (dictionary rebuild). Each prepends `lib/` to `$LOAD_PATH` as needed. |
| **`assets/`** | Static fragments and CSS for the CGI UI (`header.html`, `footer.html`, `*.css`). Loaded via `File.join(REPO_ROOT, "assets", ...)`. |
| **`corpora/`** | Upstream or hand-maintained **inputs** (versioned when license/size allow). |
| **`corpora/cmudict/`** | CMU Pronouncing Dictionary (tweaked 0.7c text + license/readme). |
| **`corpora/wordnet/3.1/`** | WordNet 3.1 lexicon (same internal layout as the standard distribution: inner `dict/`, `LICENSE`, …). |
| **`corpora/usf/`** | USF free-association norms (raw `Cue_Target_Pairs.*` shards). Runtime graph `generated/usf_associations.json` is compiled by `bin/build-usf-associations` (run from `setup.sh`); not produced by `dict-build`. |
| **`corpora/neol/`** | The 12dicts `neol2016.txt` neologism list (2016 snapshot, public domain). Force-added past `corpora/*` in `.gitignore`. The locally-curated companion list lives at `curated/neol_supplement.txt`. See `corpora/neol/README.md`. |
| **`corpora/wiktionary/`** | Kaikki / Wiktextract English JSONL (often large; **gitignored** — fetched by `bin/setup-corpora`). |
| **`corpora/subtlex/`** | SUBTLEX-US frequency TSV (`SUBTLEXus.tsv` from Open Lexicon, CC-BY-SA). Vendored — force-added past `corpora/*` in `.gitignore`. See `corpora/subtlex/README.md` and the top-level `THIRD_PARTY_NOTICES.md`. |
| **`corpora/varcon/`** | VarCon `varcon.txt` (US/UK/CA/AU spelling-variant clusters by Atkinson & Titze, MIT-style). Vendored along with the upstream `README.txt` carrying the license. |
| **`corpora/conceptnet/`** | Optional **ConceptNet** assertions gzip (`conceptnet-assertions-5.7.0.csv.gz`) for thematic edge weights in `generated/conceptnet_edges.msgpack` (large; **gitignored**). |
| **`corpora/numberbatch/`** | Optional **Numberbatch** English vectors (`numberbatch-en-19.08.txt`) for `generated/numberbatch_vectors.msgpack` (large; **gitignored**). |
| **`curated/`** | All hand-edited inputs in one flat directory: stop-word lists (`semantically_promiscuous.txt`, `unrhymable_stop_words.txt`, `neol_supplement.txt`), the `authoritative_pronunciations.txt` overrides, the manually-declared `spelling.csv` variant clusters, and the labeled `semantic_base.csv` / `rarity.csv` / `related.csv` test/training sets. `rarity.csv` doubles as the source of truth for the common / rare / forbidden curated word lists (the retired `common_words.txt` / `rare_words.txt` / `forbid_list.txt`); rows are projected by `kind` into `rarity_csv_common_words` / `rarity_csv_rare_words` / `rarity_csv_forbidden_words`. See `curated/README.md`. |
| **`generated/`** | **Outputs** of `./bin/dict-build` (see `lib/rhymecrime/dict/dict.rb`): `word_dict.txt`, `rime_dict.txt`, `part_of_speech.json`, `hyphen_variant_map.json`, `wordfreq.tsv`, and when source corpora are present `conceptnet_edges.msgpack`, `numberbatch_vectors.msgpack`. Semantic relatedness also reads `usf_associations.json` here if present. Entire directory is **gitignored**; clone → run `setup.sh` (wordfreq, Kaikki, …) then `./bin/dict-build`. |
| **`lib/rhymecrime/dict/`** | Dictionary compiler (`dict.rb`), pronunciation / inflection / Wiktionary loaders, and `dict/wordfreq/export_wordfreq_tsv.py`. (Hand-edited word lists previously kept here now live under `curated/`.) |
| **`spec/`** | RSpec examples and supporting harnesses. Hand-labeled CSVs (`related.csv`, `rarity.csv`, `semantic_base.csv`, `spelling.csv`) live under `curated/`. |

## Command Line Usage

`bin/rhyme.rb` reads CGI-style form input from STDIN and prints HTML, e.g.

```bash
echo "word1=food" | bin/rhyme.rb
```

Set `OUTPUT_FORMAT` in `lib/rhymecrime/frontend.rb` to `"text"` for plain-text output.

## Running the web UI

**Locally** (Sinatra under Puma):

```bash
bin/run-local              # http://localhost:9292/
```

`config.ru` boots `app.rb`, a small Sinatra app exposing `/`, `/similar`, `/feedback`, and `/health`.

**On AWS** (Lambda + HTTP API + DynamoDB):

The deploy is described by `template.yaml` (AWS SAM). The Lambda bundle ships the lexicon (`word_dict.msgpack` / `rime_dict.msgpack`) and reads the larger relatedness cache from DynamoDB — see `bin/stage-lambda`, `bin/upload-to-dynamodb`, and `RHYMECRIME_DATA_SOURCE=dynamodb`. The full pipeline that produces those artifacts is described in [Data pipeline](#data-pipeline) below.

## Examples:

**RhymeCrime**  
Pairs of rhyming words where the first word is related to **crime** and the second word is related to **heaven**:  
assassination / salvation  
case / airspace  
criminality / immortality  
criminalization / salvation  
fraud / god  
sin / tin  
victimization / salvation  
violation / salvation  

**RhymeCrime**  
Rhyming word sets that are related to **animal**:  
bitten / kitten  
cetacean / coloration / communication / conservation / domestication / experimentation / inoculation / liberation / predation / respiration / vaccination / vegetation  
claws / jaws / paws  
fauna / iguana  
otter / slaughter  

## How it works

### Building the Rhyming Dictionary

First, run `./bin/dict-build` from the repository root to compile the rhyming dictionary into `generated/`. Corpus inputs (CMUdict, WordNet, Kaikki extract, SUBTLEX, etc.) live under `corpora/`.
It starts from cmudict, which has a bunch of lines like this:

  KITTEN  K IH1 T AH0 N  
  KITTENS  K IH1 T AH0 N Z  
  KITTERMAN  K IH1 T ER0 M AH0 N  

This will preprocess the cmudict data into a format that's efficient for looking up rhyming words.

We use a two-step lookup process to avoid storing lots of redundant data, e.g. all 500+ "-ation" rhymes as values for "elation", "consternation", etc.

#### Step 1: Given a word, use the CMU Pronouncing Data to get its pronunciation. 

#### Step 1.1: Tweak the given pronunciation to deal with quirks of cmudict. 
e.g. 
curry [K AH1 R IY0] / hurry [HH ER1 IY0]  
ear [IY R] / beer [B IH R]  
caught [K AA1 T] / fought [F AO1 T]  
bong [B AA1 NG] / song [S AO1 NG]  
but NOT bar [B AA1 R] / score [S K AO1 R], so we leave it alone if it's followed by R  
If we had reliable data to distinguish 'cot' from 'caught', this would be in imperfect rhymes. But since caught and fought need to rhyme, we're forced to conflate them globally.

illicit [IH2 L IH1 S AH0 T] solicit [S AH0 L IH1 S IH0 T]  
conflate all unstressed schwa-ish syllables, unless they are followed by R or NG.  
mumble a little mumblier, please  

#### Step 1.5: Get the word's rime

The **rime** (linguistics) is the material that matches for English end-rhyme. Here it is implemented as everything including and after the **head vowel of the prosodic head** (final primary-stressed vowel in CMUDICT, marked `"1"`; else secondary `"2"`; else the last vowel `"0"`). That spans any trailing unstressed syllables (e.g. feminine rhymes), not only one syllable's nucleus+coda.

input: [IH0 N S IH1 ZH AH0 N] # the pronunciation of 'incision'  
output:        [IH  ZH AH  N] # stress digits removed  

We remove the stress markers so that we can rhyme 'furs' [F ER1 Z] with 'yours(2)' [Y ER0 Z]
They will both have the rime [ER Z].

The underscore-joined ARPABET string is the hash key in `generated/rime_dict.txt`.

#### Step 2: Given the rime, look up all words that rhyme with it (including itself)

#### Step 2.5: Filter out bad rhymes, like the word itself and subwords (e.g. important rhyming with unimportant)

### Filtering out rare words

When you enter e.g. 'kitten', you'll get back some reasonable
things like 'bitten', 'britain', and 'smitten', but you'll also
get back crap like 'bitton', 'brittain', 'brittan', 'brittin',
'britton', 'ditton', 'fitton', etc.

Some of these are rare words, and some are just
mistakes. Regardless, we don't want them in our output. They
clutter up the place and make the good rhymes harder to see.

We don't want to get rid of them entirely, though; occasionally
that rare word is exactly the one you want, or a good word gets
misfiled as rare. So instead we put them in the 'dregs' bucket,
which shows up as "For the desperate:" on the website.

Rare vs common uses SUBTLEX, wordfreq Zipf, WordNet (surface string lookup), Wiktionary
floors, and the manual common / rare rows in `curated/rarity.csv`.

Also we filter out slurs.

### Semantic Relatedness

Thematic relatedness is computed offline in `related.rb` (Numberbatch, ConceptNet edges, WordNet, USF, etc.), not via a live lexical API.

### Putting it all together

When you enter a single word, RhymeCrime displays rhymes for that word (separating out the rare words, where rarity is computed as described above) and in a separate column, displays sets of rhyming words. The sets of rhyming words are computed as follows:

Compute the set of all words thematically related to INPUT_REL1, call it RELATEDS1.  
For each word REL1 in RELATEDS1,  
  Get all rhymes RHYME1 of REL1.  
  If R is in RELATEDS1, compute R's rime and put RHYME1 in the bucket labeled by that rime.  
Return all buckets with two or more words in them.  

When you enter two words, RhymeCrime first displays rhymes for WORD1 that are thematically related to WORD2,  
and in a separate column, displays pairs of rhyming words (RHYME1 / RHYME2) in which RHYME1 is related to WORD1 and RHYME2 is related to WORD2. 

Algorithm:  
Compute the set of all words thematically related to INPUT_REL1, call it RELATEDS1.  
Compute the set of all words thematically related to INPUT_REL2, call it RELATEDS2.  
For each word REL1 in RELATEDS1,  
  Get all rhymes RHYME of REL1.  
  If RHYME rhymes with REL1 and is related to INPUT_REL2, we win! "REL1 / RHYME" is a pair.  

## Data pipeline

End-to-end data flow runs in five phases. Each phase's outputs are inputs to the next; every step is idempotent and self-detects already-done state.

**Phase 1 — Fetch corpora** (`bin/setup-corpora`). Downloads Wiktionary, ConceptNet 5.7, and Numberbatch 19.08 to `corpora/`; pre-aggregates USF associations, ConceptNet vocab/cache artifacts, Numberbatch vectors, and the wordfreq Zipf table into `generated/`. CMUdict, VarCon, SUBTLEX-US, neol, and USF shards are vendored in the repo.

**Phase 2 — Dictionary + classifier build** (`bin/build`, four stages). The orchestrator runs `bin/dict-build` twice (full first, slim rescore last) around two classifier-training stages:
1. `dict-build` (full): merges every corpus into the canonical lexicon — `generated/word_dict.{txt,msgpack}`, `generated/rime_dict.{txt,msgpack}`, lemma / semantic-base / spelling-variant / hyphen-variant maps. It consumes the setup-produced corpus mirrors `generated/conceptnet_edges.msgpack` and `generated/numberbatch_vectors.msgpack`, and writes the rarity-training signal dump `generated/rarity_signals_dump.jsonl`.
2. `bin/train-rarity-classifier` → `generated/rarity_classifier.json`.
3. `bin/retrain-relatedness --rebuild-vectors`: dumps `generated/<timestamp>/sense_glosses.jsonl`, encodes them with MPNet (the only Python step) into `generated/<timestamp>/model_sense_vectors.msgpack`, and trains `generated/<timestamp>/relatedness_classifier.json`.
4. `dict-build` (slim): re-runs over `word_dict.txt` so the freshly-trained rarity classifier can rescore borderline words.

**Phase 3 — Relatedness compute** (`bin/compute-relatedness` then `bin/compute-set-related`). For every cue lemma, runs the full relatedness pipeline (Numberbatch + ConceptNet + USF + sense-vector cosine + WordNet glosses → classifier) to produce the `related#<lemma>` and `score#<lemma>` rows, then computes the post-prune rhyming-tuple list for each cue as `set_related#<lemma>`. Output is one SQLite file (`generated/rhymecrime_local.sqlite3`) with three tables. Cue order is descending by `curated/related.csv` row count, alpha tiebreak — so `Ctrl-C`-resumable runs and `--max-cues=N` smoke runs front-load the cues you've curated most (`cat`, `pirate`, `food`, `hell`, `crime`, …).

**Phase 4 — Deploy** (two independent halves):
- *Code path:* `bin/deploy-aws` runs `bin/stage-lambda` (copies `lambda_handler.rb`, `lib/`, `assets/`, `curated/`, and the runtime-needed `generated/*.msgpack` files into `lambda-build/`), then `sam build --use-container` (so native gems compile for arm64-linux), then `sam deploy`.
- *Data path:* `bin/upload-to-dynamodb` streams the SQLite store from Phase 3 into the `rhymecrime` DynamoDB table as `related#…` / `score#…` / `set_related#…` items. AWS preflight is centralized in `bin/_aws_preflight.rb`.

**Phase 5 — Runtime**. Lambda cold-starts by loading the bundled msgpack lexicon. `Rhymecrime::Store` dispatches reads to `DynamoRuntime` (because `RHYMECRIME_DATA_SOURCE=dynamodb` is set in `template.yaml`). Hot path for `set_related` is one DDB `GetItem` + render. Feedback thumbs `put_item` into the separate `rhymecrime-feedback` table; `bin/augment-related-from-feedback` (DynamoDB by default; pass `--from-file` for local `generated/feedback.csv`) scans prod feedback and folds verdicts into `curated/related.csv` for the next training cycle.

```text
External sources                  Build artifacts                   Runtime
================                  ===============                   =======

corpora/                          generated/
├─ wiktionary/      ──┐           ├─ word_dict.msgpack ──────────┐  Lambda bundle
├─ conceptnet/      ──┤           ├─ rime_dict.msgpack ──────────┤  (lambda-build/)
├─ numberbatch/     ──┤           ├─ word_lemma_map.msgpack ─────┤
├─ varcon/          ──┤── Phase 2 ├─ word_semantic_base_map.msg ─┤
├─ subtlex/         ──┤  bin/build├─ spelling_variants_auto.txt ─┤
├─ cmudict/         ──┤           ├─ hyphen_variant_map.json ────┘
└─ usf/             ──┘           │
                                  ├─ numberbatch_vectors.msgpack ┐
curated/                          ├─ conceptnet_edges.msgpack    │ Phase 3
├─ rarity.csv      ──── Stage 2/4 ├─ usf_associations.json       │ inputs only
├─ related.csv     ──── Stage 3/4 ├─ model_sense_vectors.msgpack │
├─ semantic_base   ─┐             ├─ part_of_speech.json         │
├─ spelling.csv    ─┤── Stage 1/4 ├─ rarity_classifier.json     ─┘
└─ stop word txts  ─┘  via dict.rb│
                                  ├─ relatedness_classifier.json ──┐
(rarity.csv also drives           │                                │
the common/rare/                  ├─ rhymecrime_local.sqlite3 ────┐│
forbidden word lists                                              ││
at build/runtime)                                                 ││
                                  │  ├─ related table             ││ Phase 3 outputs
                                  │  ├─ related_scores table      ││ (Phase 4 inputs)
                                  │  └─ set_related table         ││
                                  │                               ││
                                  └─ feedback_from_ddb.csv        ││
                                     (DDB feedback table)         ││
                                                                  ▼▼
                                                            ┌─────────────────┐
                                                            │ rhymecrime DDB  │
                                                            │ pk:             │
                                                            │  related#…      │
                                                            │  score#…        │
                                                            │  set_related#…  │
                                                            └────────┬────────┘
                                                                     │
                                                                     ▼
                                                            ┌─────────────────┐
                                                            │ Lambda          │
                                                            │ + HTTP API GW   │
                                                            │ + custom domain │
                                                            └─────────────────┘
```

**Runbook:**

- *Fresh clone → working app:* `./setup.sh` (Phases 1-2, ~60 min) → `./bin/compute-relatedness && ./bin/compute-set-related` (Phase 3, ~2-3 hr) → `./bin/deploy-aws && AWS_PROFILE=… ./bin/upload-to-dynamodb` (Phase 4).
- *Retrain relatedness after a `curated/related.csv` edit:* `./bin/retrain-relatedness` (~1 min) → smoke-test → `./bin/compute-relatedness && ./bin/compute-set-related && ./bin/upload-to-dynamodb` (data half of Phase 4).

## Credits

RhymeCrime was created by <a href="http://paceheart.com">Pace Heart</a> and extended/maintained by all the contributors to this repository.

See assets/footer.html for the list of libraries and data sources used by RhymeCrime.
