# corpora/subtlex/

`SUBTLEXus.tsv` — the SUBTLEX-US movie-subtitle word-frequency norms used by
`lib/rhymecrime/dict/frequency.rb` (loaded via `SUBTLEX_FILENAME` in
`constants.rb`). The `FREQlow` column is preferred over `FREQcount` so we
don't double-count sentence-initial capitalization or proper-noun uses.

## Citation

> Brysbaert, M. & New, B. (2009). *Moving beyond Kucera and Francis: A critical
> evaluation of current word frequency norms and the introduction of a new and
> improved word frequency measure for American English.* Behavior Research
> Methods, 41 (4), 977–990.

## Source

Vendored verbatim from the Open Lexicon redistribution at
http://www.lexique.org/databases/SUBTLEX-US/SUBTLEXus74286wordstextversion.tsv
(canonical mirror; the URL has shifted at least once historically, which is
why we vendor rather than fetch).

## License

CC-BY-SA 4.0 — see the top-level `THIRD_PARTY_NOTICES.md` for full attribution.
