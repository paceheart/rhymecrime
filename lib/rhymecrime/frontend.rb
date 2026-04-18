#
# control parameters
#

# 'cgi' or 'text'
OUTPUT_FORMAT = "cgi"
DEBUG_MODE = false

#
# Front end for RhymeCrime.
#

require_relative "crime"

def cgi_puts(string)
  if $html_output_buffer
    $html_output_buffer << string.to_s << "\n"
  elsif OUTPUT_FORMAT == "cgi"
    puts string
  end
end

def parse_cgi_input
  cgi = CGI.new
  word1 = cgi["word1"].downcase
  word2 = cgi["word2"].downcase

  if word1 == "" && word2 != ""
    word1, word2 = word2, word1
  end
  [word1, word2]
end

def parse_query_words(word1, word2)
  w1 = word1.to_s.downcase.strip
  w2 = word2.to_s.downcase.strip
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
    output, dregs, type, header = rhymecrime(word1, word2, goal, OUTPUT_FORMAT, DEBUG_MODE)
    print_html_column(goal, output, dregs, word1, type, header, width, i == goals.length - 1)
  end
end

# Per-column focal word for tuple coloring. Every slot in a +set_related+ tuple
# is meant to be topically related to +word1+, so coloring each by its stored
# relatedness_score vs +word1+ matches the column's semantic. Pair-rhyme goals
# don't have a single focal (the two slots target different focals), so we
# skip coloring there.
def tuple_focal_word_for_goal(goal, word1)
  goal == "set_related" ? word1 : nil
end

def print_html_column(goal, output, dregs, input_word1, type, header, width, is_last_column)
  cgi_puts "<td style='vertical-align: top; width:#{width}%;' label='#{goal}'>"
  tuple_focal = tuple_focal_word_for_goal(goal, input_word1)
  print_html_column_data(output, dregs, input_word1, type, header, tuple_focal)
  cgi_puts "</td>"
  unless is_last_column
    cgi_puts "<td style='width:1%;'> </td>"
    cgi_puts "<td style='border-left: 2px solid; width:2%;'> </td>"
  end
end

def print_html_column_data(output, dregs, input_word1, type, header, tuple_focal_word = nil)
  case type
  when :words, :tuples, :synsets
    print_interesting_html_column_data(output, dregs, input_word1, header, type, tuple_focal_word)
  when :bad_input
    emit_line header
  when :error
    emit_line "Unexpected error."
  else
    emit_line "Very unexpected error."
  end
end

def print_interesting_html_column_data(output, dregs, input_word1, header, output_type, tuple_focal_word = nil)
  cgi_puts header
  if output.empty?
    if dregs.empty?
      emit_line "No matching results."
    else
      emit_line "No good results."
    end
  else
    print_output(output, input_word1, output_type, tuple_focal_word)
  end
  unless dregs.empty?
    cgi_puts "<br/><hr><p>For the desperate:</p>"
    print_output(dregs, input_word1, output_type, tuple_focal_word)
  end
end

def print_output(output, input_word1, output_type, tuple_focal_word = nil)
  case output_type
  when :words
    print_words(output)
  when :tuples
    print_tuples(output, tuple_focal_word)
  when :synsets
    print_synsets(output, input_word1)
  end
end

def print_html_footer
  cgi_puts IO.read(File.join(REPO_ROOT, "assets", "footer.html"), encoding: "UTF-8")
end

# Full HTML page (Sinatra / Lambda). Uses +$html_output_buffer+ so +cgi_print+ / +emit_*+ accumulate.
def build_rhymecrime_page(word1, word2)
  Rhymecrime::DynamoRuntime.clear_session_cache! if defined?(Rhymecrime::DynamoRuntime) && Rhymecrime::DataSource.dynamodb?
  RelatedWords.instance_variable_set(:@related_word_cache, {}) if defined?(RelatedWords)
  buf = +""
  $html_output_buffer = buf
  w1, w2 = parse_query_words(word1, word2)
  print_html_header(w1, w2)
  compute_and_print_html_middle(w1, w2)
  print_html_footer
  buf
ensure
  $html_output_buffer = nil
end

# CGI: reads params from environment, prints to stdout.
def compute_and_print_html
  Rhymecrime::DynamoRuntime.clear_session_cache! if defined?(Rhymecrime::DynamoRuntime) && Rhymecrime::DataSource.dynamodb?
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
  Rhymecrime::DynamoRuntime.clear_session_cache! if defined?(Rhymecrime::DynamoRuntime) && Rhymecrime::DataSource.dynamodb?
  RelatedWords.instance_variable_set(:@related_word_cache, {}) if defined?(RelatedWords)
  buf = +""
  $html_output_buffer = buf
  w1, w2 = parse_query_words(word1, word2)
  print_html_header(w1, w2, "Thematic Similarity", "/similar")
  compute_and_print_html_similar_middle(w1, w2)
  print_html_footer
  buf
ensure
  $html_output_buffer = nil
end

def compute_and_print_similar_html
  word1, word2 = parse_cgi_input
  puts build_similar_page(word1, word2)
end
