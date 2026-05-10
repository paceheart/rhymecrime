# encoding: utf-8
# frozen_string_literal: true

# Detects "read the letters" pronunciations (initialisms) from flat ARPAbet,
# e.g. USS -> Y UW EH S EH S, FBI -> EH F B IY AY. Used by the rarity rescore
# clamp alongside orthographic dotted forms (see initialism_shaped_headword? in
# phonology.rb).

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
