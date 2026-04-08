# RhymeCrime
Find semantically related rhymes

## Installation

* dnf install git
* git clone http://github.com/paceheart/rhymecrime/
* dnf install ruby
* gem install rwordnet
* gem install rspec
* Run rspec from the rhymecrime directory to verify installation. All tests should pass.

## Repository layout

Data and build artifacts are split so **sources** stay under `corpora/` and **regenerable caches** under `generated/` at the repo root. Ruby code resolves paths via `REPO_ROOT` / `GENERATED_DIR` in `lib/rhymecrime/dict/utils_rhyme.rb`, so loading works even when the process cwd is not the repository root (e.g. CGI).

| Location | Role |
|----------|------|
| **`lib/`** | On the load path. `lib/rhymecrime.rb` defines `Rhymecrime::ROOT`; application code lives under **`lib/rhymecrime/`** (`crime.rb`, `semantic-similarity.rb`, `frontend.rb`, helpers, and the **`dict/`** subtree). Use `require "rhymecrime/..."` from `bin/` and specs (after unshifting `lib/`). |
| **`bin/`** | **Executables**: `rhyme.rb`, `similar.rb`, `debug.rb`, `anneal.rb`, `dict-build` (dictionary rebuild). Each prepends `lib/` to `$LOAD_PATH` as needed. |
| **`assets/`** | Static fragments and CSS for the CGI UI (`header.html`, `footer.html`, `*.css`). Loaded via `File.join(REPO_ROOT, "assets", ...)`. |
| **`corpora/`** | Upstream or hand-maintained **inputs** (versioned when license/size allow). |
| **`corpora/cmudict/`** | CMU Pronouncing Dictionary (tweaked 0.7c text + license/readme). |
| **`corpora/wordnet/3.1/`** | WordNet 3.1 lexicon (same internal layout as the standard distribution: inner `dict/`, `LICENSE`, …). |
| **`corpora/usf/`** | USF free-association norms (raw `Cue_Target_Pairs.*` shards). Runtime graph: `generated/usf_associations.json` (you build from the raw shards; not produced by `dict-build` today). |
| **`corpora/wiktionary/`** | Kaikki / Wiktextract English JSONL (often large; **gitignored** — fetch with `setup.sh` or equivalent). |
| **`corpora/subtlex/`** | SUBTLEX-US frequency TSV (often **gitignored**). |
| **`corpora/conceptnet/`** | Optional **ConceptNet** assertions gzip (`conceptnet-assertions-5.7.0.csv.gz`) for semantic edge weights in `generated/conceptnet_edges.json` (large; **gitignored**). |
| **`corpora/numberbatch/`** | Optional **Numberbatch** English vectors (`numberbatch-en-19.08.txt`) for `generated/numberbatch_vectors.msgpack` (large; **gitignored**). |
| **`generated/`** | **Outputs** of `./bin/dict-build` (see `lib/rhymecrime/dict/dict.rb`): `word_dict.txt`, `rime_dict.txt`, `part_of_speech.json`, `hyphen_variant_map.json`, `wordfreq.tsv`, and when source corpora are present `conceptnet_edges.json`, `numberbatch_vectors.msgpack`. Semantic relatedness also reads `usf_associations.json` here if present. Entire directory is **gitignored**; clone → run `setup.sh` (wordfreq, Kaikki, …) then `./bin/dict-build`. |
| **`lib/rhymecrime/dict/`** | Dictionary compiler (`dict.rb`), pronunciation / inflection / Wiktionary loaders, curated lists (`common_words.txt`, `rare_words.txt`, `forbid_list.txt`, …), and `dict/wordfreq/export_wordfreq_tsv.py`. |
| **`spec/`** | RSpec examples and `related.csv` (semantic relatedness expectations). |

## Command Line Usage

echo "word1=food" | bin/rhyme.rb

You can change OUTPUT_TYPE from 'cgi' to 'text' if you want to use it at the command line.

## Webserver Installation

* put everything into your cgi-bin directory
* configure your webserver to allow Ruby scripts
* cd /WHATEVER/cgi-bin/
* chmod +x bin/*.rb bin/dict-build
* ./bin/dict-build

That rebuilds caches under `generated/` (loads `lib/rhymecrime/dict/dict.rb` and runs the rebuild). Configure your app server to run `bin/rhyme.rb` (and `bin/similar.rb` if needed) for the web UI. Symlink `assets/*.css` into your static docroot if needed (see `setup.sh`).

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
floors, and manual `common_words.txt` / `rare_words.txt`.

Also we filter out slurs.

### Semantic Relatedness

Currently, RhymeCrime outsources its semantic relatedness to the Datamuse API.

### Putting it all together

When you enter a single word, RhymeCrime displays rhymes for that word (separating out the rare words, where rarity is computed as described above) and in a separate column, displays sets of rhyming words. The sets of rhyming words are computed as follows:

Compute the set of all words semantically related to INPUT_REL1, call it RELATEDS1.  
For each word REL1 in RELATEDS1,  
  Get all rhymes RHYME1 of REL1.  
  If R is in RELATEDS1, compute R's rime and put RHYME1 in the bucket labeled by that rime.  
Return all buckets with two or more words in them.  

When you enter two words, RhymeCrime first displays rhymes for WORD1 that are semantically related to WORD2,  
and in a separate column, displays pairs of rhyming words (RHYME1 / RHYME2) in which RHYME1 is related to WORD1 and RHYME2 is related to WORD2. 

Algorithm:  
Compute the set of all words semantically related to INPUT_REL1, call it RELATEDS1.  
Compute the set of all words semantically related to INPUT_REL2, call it RELATEDS2.  
For each word REL1 in RELATEDS1,  
  Get all rhymes RHYME of REL1.  
  If RHYME rhymes with REL1 and is related to INPUT_REL2, we win! "REL1 / RHYME" is a pair.  

## Credits

RhymeCrime was created by <a href="http://paceheart.com">Pace Heart</a> and extended/maintained by all the contributors to this repository.

See assets/footer.html for the list of libraries and data sources used by RhymeCrime.
