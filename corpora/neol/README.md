# corpora/neol/

The `neol2016` neologism list from Alan Beale's **12dicts** package (public
domain): a curated snapshot of English neologisms compiled in 2016. Used by
`lib/rhymecrime/dict/frequency.rb` (Phase 5b) to floor the frequency of recent
additions to English so they survive the rare-word threshold and seed
morphological expansion (e.g. `yeet` → `yeeted`, `yeeting`).

Plain newline-delimited ASCII, sorted, lowercased, one headword per line. The
file is a verbatim copy of `Lemmatized/neol2016.txt` from the 12dicts 6.x
release; pinning the 2016 vintage on purpose since this list is a *reference
set* for "what counted as a neologism then," not a moving target. Vendored
(force-added past `corpora/*` in `.gitignore`) because it's small, stable, and
the upstream tarball isn't trivially fetchable from a build script.

Upstream:

  - https://wordlist.aspell.net/12dicts/
  - https://sourceforge.net/projects/wordlist/files/12dicts/

Companion list: hand-curated post-2016 additions (acai, blockchain, doomscroll,
yeet, …) live at `curated/neol_supplement.txt` and load alongside this file via
the same Phase-5b code path. See `curated/README.md` for editing conventions.
