# frozen_string_literal: true

# Flyweight pool for ARPAbet token strings (CMU / Wiktionary / Inflect) to cut heap churn during dict-build.
module Phoneme
  @pool = {}
  @bare = {}
  def self.intern(str)
    s = str.to_s
    @pool[s] ||= s.dup.freeze
  end

  # Strip stress digits (0–2) from an ARPAbet token; memoized per interned phone.
  def self.bare_base(str)
    s = str.to_s
    @bare[s] ||= s.tr("0-2", "").freeze
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
