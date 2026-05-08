#
# control parameters
#

# 'cgi' or 'text'
OUTPUT_FORMAT = "cgi"
DEBUG_MODE = false

#
# Front end for RhymeCrime.
#

require "set"
require_relative "query"

# Per-request debug pruning lives in Thread.current[RHYMECRIME_REQUEST_DEBUG] (see query.rb).
# build_rhymecrime_page sets it when ?debug=1; $debug_mode (pace_utils) is flipped for the same request.

def cgi_puts(string)
  buf = Thread.current[:html_output_buffer]
  if buf
    buf << string.to_s << "\n"
  elsif OUTPUT_FORMAT == "cgi"
    puts string
  end
end

# Rack and CGI may hand us BINARY or malformed UTF-8; String#downcase raises
# ArgumentError on invalid UTF-8 ("input string invalid").
def utf8_query_param(value)
  value.to_s.encode(Encoding::UTF_8, Encoding::UTF_8, invalid: :replace, undef: :replace)
end

def parse_cgi_input
  cgi = CGI.new
  word1 = utf8_query_param(cgi["word1"]).downcase
  word2 = utf8_query_param(cgi["word2"]).downcase

  if word1 == "" && word2 != ""
    word1, word2 = word2, word1
  end
  [word1, word2]
end

def parse_query_words(word1, word2)
  w1 = utf8_query_param(word1).downcase.strip
  w2 = utf8_query_param(word2).downcase.strip
  if w1 == "" && w2 != ""
    w1, w2 = w2, w1
  end
  [w1, w2]
end

def print_html_header(word1, word2, title = "RhymeCrime", handler = "/")
  head = IO.read(File.join(REPO_ROOT, "assets", "header.html"), encoding: "UTF-8")

  clarifier = ""
  if word1 != ""
    clarifier = ": #{word1}"
    if word2 != ""
      clarifier += " / #{word2}"
    end
  end
  head = head.gsub("<title>RhymeCrime</title>", "<title>#{title}#{clarifier}</title>")
  head = head.gsub("RhymeCrime", title)
  head = head.gsub(%(action="/"), %(action="#{handler}"))

  cgi_puts head
  debug "DEBUG MODE"
end

def compute_and_print_html_middle(word1, word2)
  goals = []
  widths = []

  if word1 == ""
    # vacuous
  elsif word2 == ""
    if DEBUG_MODE
      goals = ["rhymes", "related", "set_related"]
      widths = [25, 25, 44]
    else
      goals = ["rhymes", "set_related"]
      widths = [22, 75]
    end
  else
    goals = ["related_rhymes", "pair_related"]
    widths = [45, 52]
  end

  goals.length.times do |i|
    goal = goals[i]
    width = widths[i]
    output, dregs, type, header = compute_column_for_goal(goal, word1, word2)
    print_html_column(goal, output, dregs, word1, word2, type, header, width, i == goals.length - 1)
  end
end

# Per-column dispatch: short-circuits with a "semantically promiscuous"
# message when the goal's relatedness cue is promiscuous, otherwise calls
# the normal rhymecrime pipeline.
#
# Why per-column rather than at the top of compute_and_print_html_middle:
# the rhymes goal has no relatedness cue (feedback_cue_for_goal → nil),
# so a promiscuous word1 doesn't impair it — "perhaps" really does rhyme
# with "lapse", and we want that column to keep working. Only the
# relatedness-bearing goals (related, set_related, related_rhymes,
# pair_related) need to bail out, and the cue-mapping table that says
# *which* word matters per goal is exactly feedback_cue_for_goal — the
# same one that drives the thumbs-feedback widget. Reusing it keeps the
# "what's the cue here" definition single-sourced.
#
# Returning a synthetic (:bad_input, header) tuple piggybacks on
# print_html_column_data's existing emit_line header branch — no new
# render path needed.
#
# Linking parity: promiscuous words are also stripped of their <a href=...>
# in print_word (see link_word), so a user who somehow lands on a
# promiscuous word through search or a typed URL doesn't get tempted by
# clickable rhymes that would only land them back on this same dead-end
# message. (Unrhymable stop words like "the" are deleted from word_dict at
# build time, so this dispatch never sees them.) Color: .stop-word (#bbb)
# in assets/crimestyle.css wraps those surfaces in print_word.
def compute_column_for_goal(goal, word1, word2)
  cue = feedback_cue_for_goal(goal, word1, word2)
  promiscuous = promiscuous_words_in_cue(cue)
  if promiscuous.any?
    return [[], [], :bad_input, promiscuous_message(promiscuous)]
  end
  rhymecrime(word1, word2, goal, OUTPUT_FORMAT, DEBUG_MODE)
end

# Returns the unique semantically promiscuous words in the goal's relatedness
# cue. cue is whatever feedback_cue_for_goal returned: nil (no cue), a
# String, or an Array of Strings (pair_related). Array(cue) flattens all
# three to a uniform iterable; uniq keeps the message stable when the same
# promiscuous word fills both slots of a pair_related query
# (perhaps / perhaps). Empty / blank cue components are pre-filtered so a
# vacuous query (word1="") doesn't accidentally trigger the message.
def promiscuous_words_in_cue(cue)
  Array(cue).reject { |c| c.nil? || c.to_s.empty? }.uniq.select { |c| semantically_promiscuous?(c) }
end

# Format the abort message. Always singular: when both slots of a
# pair_related query are promiscuous (perhaps / however), pluralizing
# inline produces awkward English, so we just name the first offender.
# Loses a bit of info in that rare case, but the user can see the full query
# in the form/URL anyway.
def promiscuous_message(promiscuous_words)
  "\"#{promiscuous_words.first}\" is semantically promiscuous; can't compute related words"
end

# Per-column focal word for tuple coloring. Every slot in a set_related tuple
# is meant to be topically related to word1, so under debug we color each by
# its stored relatedness_score vs word1 to make the relatedness model legible.
# Pair-rhyme goals don't have a single focal (the two slots target different
# focals), so we skip coloring there.
#
# Production default returns nil for every goal — set_related slots render in
# the page's default text color so the visual hierarchy of the page (headers,
# links, body text) reads cleanly without per-word color noise. Pass ?debug=1
# on the URL to flip back to the diagnostic view; see debug_pruning? in query.rb.
def tuple_focal_word_for_goal(goal, word1)
  return nil unless debug_pruning?
  goal == "set_related" ? word1 : nil
end

# Feedback cue per goal. Determines what cue the rendered word is being
# claimed related to, so the thumbs widget can POST a (cue, related, verdict)
# triple matching the curated/related.csv schema:
#
#   * rhymes         → nil (plain rhymes; no relatedness claim being made)
#   * related        → word1 (debug column: "words related to word1")
#   * set_related    → word1 (every tuple slot related to word1)
#   * related_rhymes → word2 (rhymes for word1, related to word2)
#   * pair_related   → [word1, word2] (slot 0 related to word1, slot 1 to
#     word2). print_tuples accepts this Array form natively.
def feedback_cue_for_goal(goal, word1, word2)
  case goal
  when "set_related", "related"
    word1
  when "related_rhymes"
    word2
  when "pair_related"
    [word1, word2]
  end
end

def print_html_column(goal, output, dregs, input_word1, input_word2, type, header, width, is_last_column)
  cgi_puts "<td style='vertical-align: top; width:#{width}%;' label='#{goal}'>"
  tuple_focal = tuple_focal_word_for_goal(goal, input_word1)
  feedback_cue = feedback_cue_for_goal(goal, input_word1, input_word2)
  print_html_column_data(output, dregs, input_word1, type, header, tuple_focal, feedback_cue)
  cgi_puts "</td>"
  unless is_last_column
    cgi_puts "<td style='width:1%;'> </td>"
    cgi_puts "<td style='border-left: 2px solid; width:2%;'> </td>"
  end
end

def print_html_column_data(output, dregs, input_word1, type, header, tuple_focal_word = nil, feedback_cue = nil)
  case type
  when :words, :tuples, :synsets
    print_interesting_html_column_data(output, dregs, input_word1, header, type, tuple_focal_word, feedback_cue)
  when :bad_input
    emit_line header
  when :error
    emit_line "Unexpected error."
  else
    emit_line "Very unexpected error."
  end
end

def print_interesting_html_column_data(output, dregs, input_word1, header, output_type, tuple_focal_word = nil, feedback_cue = nil)
  cgi_puts header
  if output.empty?
    if dregs.empty?
      emit_line "No matching results."
    else
      emit_line "No good results."
    end
  else
    print_output(output, input_word1, output_type, tuple_focal_word, feedback_cue)
  end
  unless dregs.empty?
    cgi_puts "<br/><hr><p>For the desperate:</p>"
    print_output(dregs, input_word1, output_type, tuple_focal_word, feedback_cue)
  end
end

def print_output(output, input_word1, output_type, tuple_focal_word = nil, feedback_cue = nil)
  case output_type
  when :words
    # feedback_cue for :words is always a String (per feedback_cue_for_goal:
    # only pair_related — a :tuples goal — returns an Array).
    print_words(output, false, cue: feedback_cue)
  when :tuples
    print_tuples(output, tuple_focal_word, cues: feedback_cue)
  when :synsets
    print_synsets(output, input_word1)
  end
end

def print_html_footer
  cgi_puts IO.read(File.join(REPO_ROOT, "assets", "footer.html"), encoding: "UTF-8")
end

# Full HTML page (Sinatra / Lambda). Uses a thread-local buffer so cgi_print / emit_* accumulate
# without contaminating concurrent requests on other Puma threads.
#
# debug: true (passed from the debug=1 URL param) turns on debug pruning (query.rb):
# suffix-redundant tuples render inline (output_tuple_pruned), set_related slots tint by score, etc.
#
# Cache lifetime: we deliberately do NOT call Rhymecrime::DynamoRuntime
# .clear_session_cache! or RelatedWords.reset_caches! on entry. The
# word# / rime# rows backing the DDB cache and the per-cue @related_
# word_cache / $rhyming_tuple_word_bases_cache are pure functions of the
# upstream data deploy (frozen until the next bin/upload-to-dynamodb),
# so warm Lambda containers benefit from keeping them across requests —
# the prefetch+find_related DDB phases collapse from ~5s to single-digit
# milliseconds whenever the cohort overlaps a previously-served cue. The
# DDB caches are FIFO-bounded by DDB_WORD_CACHE_CAP / DDB_RIME_CACHE_CAP
# so even a long-lived container that has cumulatively touched every cue
# can't grow them past the dictionary size.
#
# bin/compute-relatedness still calls reset_caches! between shards
# to bound worker RSS — that's a different access pattern (sequential
# distinct-cue scan) where retention has no upside.
def build_rhymecrime_page(word1, word2, debug: false)
  prev_debug_mode = $debug_mode
  Thread.current[RHYMECRIME_REQUEST_DEBUG] = { pruning: debug, pruned: (debug ? Set.new : nil) }
  # Per-request DEBUG override: ?debug=1 turns on the same gate that
  # ENV["DEBUG"]=1 sets at boot, so verbose-prune logging in the tuple
  # sweepers (query.rb) and any future $debug_mode-gated diagnostic fires
  # alongside the pruning visualizer / score-tinting. Restored in ensure
  # so a debug request doesn't leak into subsequent ones on the same
  # warm container / Puma thread.
  $debug_mode = true if debug
  buf = +""
  Thread.current[:html_output_buffer] = buf
  w1, w2 = parse_query_words(word1, word2)
  print_html_header(w1, w2)
  compute_and_print_html_middle(w1, w2)
  print_html_footer
  buf
ensure
  Thread.current[:html_output_buffer] = nil
  Thread.current[RHYMECRIME_REQUEST_DEBUG] = nil
  $debug_mode = prev_debug_mode
end

# CGI: reads params from environment, prints to stdout.
# See build_rhymecrime_page for why we don't reset caches here.
def compute_and_print_html
  word1, word2 = parse_cgi_input
  puts build_rhymecrime_page(word1, word2)
end

#
# Similar
#

def similar_column_count
  12
end

def print_similar_word(word, focal_word)
  word = word.gsub(/\(.*\)/, "")
  cgi_print "<td style='color: #{word_similarity_color(word, focal_word)}'>"
  word = word.gsub("_", " ")
  emit_text word
  cgi_print "</td>"
end

def print_similar_words(similar_words, focal_word)
  success = !similar_words.empty?
  if success
    cgi_print "<table><tr>"
    i = 0
    similar_words.sort_by! { |w| -similarity(focal_word, w) }
    similar_words.each do |word|
      if i > 0 && (i % similar_column_count).zero?
        cgi_print "</tr><tr>"
      end
      i += 1
      print_similar_word(word, focal_word)
      if $display_word_frequencies
        emit_text " (#{frequency(word)})"
      end
      emit_line
    end
    cgi_print "</tr></table>"
  end
  success
end

def compute_and_print_html_similar_pair(word1, word2)
  cgi_print "'#{word1}' is <span style='color: #{word_similarity_color(word1, word2)}'>#{percent_similarity(word1, word2)} similar</span> to '#{word2}'\n"
end

def compute_and_print_html_all_similar(word1)
  similar_words, dregs = filter_out_rare_words(find_related_words(word1, false))
  print_similar_words(similar_words, word1)
end

def compute_and_print_html_similar_middle(word1, word2)
  print_similarity_color_legend
  if word2 != ""
    compute_and_print_html_similar_pair(word1, word2)
  else
    compute_and_print_html_all_similar(word1)
  end
end

def build_similar_page(word1, word2)
  buf = +""
  Thread.current[:html_output_buffer] = buf
  w1, w2 = parse_query_words(word1, word2)
  print_html_header(w1, w2, "Thematic Similarity", "/similar")
  compute_and_print_html_similar_middle(w1, w2)
  print_html_footer
  buf
ensure
  Thread.current[:html_output_buffer] = nil
end

def compute_and_print_similar_html
  word1, word2 = parse_cgi_input
  puts build_similar_page(word1, word2)
end
