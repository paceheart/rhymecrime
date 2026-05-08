# frozen_string_literal: true

# Dict-build trace helpers (TRACE_WORDS / ENV). Required from build/constants.rb
# alongside the rest of the dict pipeline. Runtime WordNet paths use $debug_mode
# for wn_frequency diagnostics in morphology/lexical.rb instead of loading this file.

require_relative "../pace_utils"

def dict_trace_word?(word)
  trace_word?(word)
end

# Kaikki morph inheritance / common-list + SUBTLEX-anchored Inflect expansion: base →
# infl inflection row touches any word in TRACE_WORDS.
def dict_trace_morph?(base, infl)
  trace_pair?(base, infl)
end

# List-pivot Inflect inheritance: hash key word, common_words candidate listed,
# morph base → infl.
def dict_trace_morph_inherit_listed?(word, listed, base, infl)
  return false if TRACE_WORDS.empty?

  TRACE_WORDS.include?(word) || TRACE_WORDS.include?(listed) || TRACE_WORDS.include?(base) || TRACE_WORDS.include?(infl)
end

# CMU line preprocessing: line changed and mentions a traced substring (token is first field).
def dict_trace_preprocess_line?(original_line, line)
  return false if TRACE_WORDS.empty? || line == original_line

  TRACE_WORDS.any? { |w| line.include?(w) }
end

# body must not include a leading "TRACE". Pass word to print TRACE(word) before the message;
# pass nil or "" for an unscoped TRACE line only.
def dict_trace_format(word, body)
  b = body.to_s
  w = word.is_a?(String) && !word.empty? ? word : nil
  w ? "TRACE(#{w}) #{b}" : "TRACE #{b}"
end

def dict_trace_puts(word, body)
  puts dict_trace_format(word, body)
end
