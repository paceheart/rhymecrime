# encoding: utf-8
# frozen_string_literal: true

# Detects "read the letters" pronunciations (initialisms) from flat ARPAbet,
# e.g. USS -> Y UW EH S EH S, FBI -> EH F B IY AY. Used by the rarity rescore
# clamp alongside orthographic dotted forms (see initialism_shaped_headword? in
# phonology.rb).

require "set"

require_relative "../phoneme"
require_relative "../pronunciation"

# Bare ARPAbet (stress digits stripped) for how each letter is typically named
# in GA when spelled out. Order: try shorter templates first where ambiguous.
LETTER_NAME_BARE_TEMPLATES = {
  "a" => [%w[EY]],
  "b" => [%w[B IY]],
  "c" => [%w[S IY]],
  "d" => [%w[D IY]],
  "e" => [%w[IY]],
  "f" => [%w[EH F]],
  "g" => [%w[JH IY]],
  "h" => [%w[EY CH]],
  "i" => [%w[AY]],
  "j" => [%w[JH EY]],
  "k" => [%w[K EY]],
  "l" => [%w[EH L]],
  "m" => [%w[EH M]],
  "n" => [%w[EH N]],
  "o" => [%w[OW]],
  "p" => [%w[P IY]],
  "q" => [%w[K Y UW]],
  "r" => [%w[AA R]],
  "s" => [%w[EH S]],
  "t" => [%w[T IY]],
  "u" => [%w[Y UW]],
  "v" => [%w[V IY]],
  "w" => [%w[D AH B AH L Y UW]],
  "x" => [%w[EH K S]],
  "y" => [%w[W AY]],
  "z" => [%w[Z IY]],
}.freeze

SPELLED_OUT_INITIALISM_LETTERS_MIN = 2
SPELLED_OUT_INITIALISM_LETTERS_MAX = 8

def pronunciation_flat_bare_phones(pron)
  pron.phonemes.reject { |p| p == "." }.map { |p| Phoneme.bare_base(p) }
end

def spelling_matches_bare_phones?(letters, bare, li, pi)
  if li == letters.size
    return pi == bare.size
  end
  ch = letters[li]
  tpls = LETTER_NAME_BARE_TEMPLATES[ch]
  return false unless tpls

  tpls.each do |tpl|
    next if pi + tpl.size > bare.size
    match = tpl.each_with_index.all? { |phone, i| bare[pi + i] == phone }
    next unless match
    return true if spelling_matches_bare_phones?(letters, bare, li + 1, pi + tpl.size)
  end
  false
end

# True when this pronunciation is a consecutive letter-by-letter reading of
# +word+ (lowercase a–z only; length bounded).
def pronunciation_spells_out_headword_letters?(word, pron)
  return false unless word.is_a?(String) && word.match?(/\A[a-z]+\z/)
  n = word.length
  return false if n < SPELLED_OUT_INITIALISM_LETTERS_MIN || n > SPELLED_OUT_INITIALISM_LETTERS_MAX

  letters = word.chars.to_a
  bare = pronunciation_flat_bare_phones(pron)
  return false if bare.empty?

  spelling_matches_bare_phones?(letters, bare, 0, 0)
end

# Two-letter function words that can carry both a letter-by-letter reading and an ordinary
# pronunciation under the same spelling (e.g. *us*). Never drop the non-letter row for
# these — we only strip CMU's bogus "word" alts for clear initialisms (ip, mt, …).
TWO_LETTER_MIXED_INITIALISM_STRIP_BLOCKLIST = %w[
  us we he me my it is in on at as an am or of be do go no so up if
].to_set.freeze

# Dict-build: CMU often lists a letter-spelled row alongside a word-like alternate for the
# same lowercase headword (NOAA+N OW AH, IP+IH P). Drop the non-letter rows so runtime
# rhyme/rime indexing never treats the token as an ordinary word. See rhyme_spec initialisms.
#
# Skips headwords in authoritative_pronunciations.txt (curator-owned multi-pron) and
# two-letter blocklist words (homograph guard).
def drop_mixed_initialism_nonletter_pronunciations!(pronunciation_map, authoritative_words: Set.new)
  auth = authoritative_words.to_set

  dropped_prons = 0
  touched_headwords = 0

  pronunciation_map.each do |word, prons|
    next if prons.nil? || prons.size < 2
    next if auth.include?(word)
    next if word.length == 2 && TWO_LETTER_MIXED_INITIALISM_STRIP_BLOCKLIST.include?(word)

    spelled = prons.map { |p| pronunciation_spells_out_headword_letters?(word, p) }
    n_spelled = spelled.count(true)
    next if n_spelled < 1 || n_spelled == spelled.size

    kept = prons.each_with_index.select { |_, i| spelled[i] }.map(&:first)
    next if kept.empty?

    n_drop = prons.size - kept.size
    next if n_drop <= 0

    dropped_prons += n_drop
    touched_headwords += 1
    pronunciation_map[word] = kept
  end

  if dropped_prons > 0
    puts "Dropped #{dropped_prons} word-like alternate pronunciations for #{touched_headwords} initialism headwords (letter-reading kept)"
  end
  dropped_prons
end
