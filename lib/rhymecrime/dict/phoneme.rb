# frozen_string_literal: true

# Flyweight pool for ARPAbet token strings (CMU / Wiktionary / Inflect) to cut heap churn during dict-build.
module Phoneme
  @pool = {}
  def self.intern(str)
    s = str.to_s
    @pool[s] ||= s.dup.freeze
  end

  def self.intern_tokens(tokens)
    tokens.map { |t| intern(t) }
  end
end

class String
  # treat strings as phonemes

  STRESS_DIGIT_RE = /[012]/.freeze

  def vowel?
    match?(STRESS_DIGIT_RE)
  end

  def syllable_boundary?
    self == "."
  end

  def sanitize
    # sanitizes STR so it can be saved in a space-delimited text file
    gsub(" ", "_")
  end

  def desanitize
    # desanitizes STR. The result may contain spaces.
    gsub("_", " ")
  end
end
