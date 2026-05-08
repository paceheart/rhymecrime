# frozen_string_literal: true

# Process-wide DEBUG gate. Set via ENV["DEBUG"]=1 at boot, and additionally
# flipped to true per-request by build_rhymecrime_page when ?debug=1 is on
# the URL (so the same flag drives CLI debug output and request-scoped
# diagnostic rendering — pruning visualizer, score-tinted set_related,
# verbose-prune logging in query.rb's tuple sweepers). Reset in the request
# ensure block. The legacy VERBOSE env var was folded in here in May 2026.
$debug_mode = ENV["DEBUG"].to_s == "1"

def debug(string)
  if($debug_mode)
    puts string
  end
end

# Process-wide trace headword set. Read from ENV["TRACE_WORDS"]
# (comma/space/semicolon-separated) at load time. Used by every layer that
# wants to spam diagnostics for a specific headword without flooding the
# build / runtime log: dict-build (frequency, CMU ingest, rime, disconnect
# pruning), the relatedness predicates (compute, memo lookups), and any new
# trace site that needs the same gate. Empty -> all tracing is a no-op.
#
# Examples:
#   TRACE_WORDS=kitchening ./bin/dict-build
#   TRACE_WORDS="kitchening,puffin" ./bin/dict-build
#   TRACE_WORDS="foo bar;baz" bundle exec rspec
TRACE_WORDS = ENV["TRACE_WORDS"].to_s.split(/[\s,;]+/).map(&:strip).reject(&:empty?).uniq.freeze unless defined?(TRACE_WORDS)

# True iff word is in TRACE_WORDS. Cheap empty-check short-circuit so
# untraced runs pay one nil-check per call site.
def trace_word?(word)
  !TRACE_WORDS.empty? && TRACE_WORDS.include?(word)
end

# True iff either a or b (b optional) is a traced headword. Used by every
# pair-keyed trace site (relatedness predicates, tuple sweepers).
def trace_pair?(a, b = nil)
  return false if TRACE_WORDS.empty?
  TRACE_WORDS.include?(a) || (!b.nil? && TRACE_WORDS.include?(b))
end

class File
  def writeln(str)
    self.write("#{str}\n")
  end
end

class String
  def ensure_trailing(final_char)
    self[-1] == final_char ? self : self + final_char
  end

  def ensure_trailing_newline
    self.ensure_trailing("\n")
  end
end
