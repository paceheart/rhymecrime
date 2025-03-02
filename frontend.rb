#
# control parameters
#

# 'cgi' or 'text'
OUTPUT_FORMAT = 'cgi'
DEBUG_MODE = false

#
# Front end for RhymeCrime.
#

require_relative 'crime'

def cgi_puts(string)
  if(OUTPUT_FORMAT == 'cgi')
    puts string
  end
end

def parse_cgi_input
  cgi = CGI.new;
  word1 = cgi['word1'].downcase;
  word2 = cgi['word2'].downcase;

  if(word1 == "" and word2 != "")
    word1, word2 = word2, word1
  end
  return word1, word2
end

def print_html_header(word1, word2)
  head = IO.read("html/header.html");

  # tweak the title of the webpage to include the submitted word(s)
  clarifier = ""
  if(word1 != "")
    clarifier = ": #{word1}"
    if(word2 != "")
      clarifier += " / #{word2}"
    end
  end
  head = head.gsub("<title>RhymeCrime</title>","<title>RhymeCrime#{clarifier}</title>")

  cgi_puts head
  debug "DEBUG MODE"
end

def compute_and_print_html_middle(word1, word2)
  goals = [ ]
  widths = [ ]

  if(word1 == "")
    # vacuous: no goals means nothing will happen
  elsif(word2 == "")
    if(DEBUG_MODE)
      goals = [ "rhymes", "related", "set_related" ]
      widths = [25, 25, 44]
    else
      goals = [ "rhymes", "set_related" ]
      widths = [22, 75]
    end
  else
    goals = [ "related_rhymes", "pair_related" ]
    widths = [45, 52]
  end

  goals.length.times do |i|
    goal = goals[i]
    width = widths[i]
    output, dregs, type, header = rhymecrime(word1, word2, goal, OUTPUT_FORMAT, DEBUG_MODE)
    print_html_column(goal, output, dregs, word1, type, header, width, i == goals.length - 1)
  end
end

def print_html_column(goal, output, dregs, input_word1, type, header, width, is_last_column)
  cgi_puts "<td style='vertical-align: top; width:#{width}%;' label='#{goal}'>"
  print_html_column_data(output, dregs, input_word1, type, header)
  cgi_puts "</td>"
  unless(is_last_column)
    # 3% spacing between columns
    cgi_puts "<td style='width:1%;'> </td>" # @todo fix width computation
    cgi_puts "<td style='border-left: 2px solid; width:2%;'> </td>"
  end  
end

def print_html_column_data(output, dregs, input_word1, type, header)
  case type # :words, :tuples, :synsets, :bad_input, :error
  when :words, :tuples, :synsets
    print_interesting_html_column_data(output, dregs, input_word1, header, type)
  when :bad_input
    puts header
  when :error
      puts "Unexpected error."
  else
      puts "Very unexpected error."
  end
end

def print_interesting_html_column_data(output, dregs, input_word1, header, output_type)
  cgi_puts header
  if output.empty?
    if dregs.empty?
      puts "No matching results."
    else
      puts "No good results."
    end
  else
    print_output(output, input_word1, output_type)
  end
  if(!dregs.empty?)
    cgi_puts "<br/><hr><p>For the desperate:</p>"
    print_output(dregs, input_word1, output_type)
  end
end

def print_output(output, input_word1, output_type)
  case output_type
  when :words
    print_words(output)
  when :tuples
    print_tuples(output)
  when :synsets
    print_synsets(output, input_word1)
  end
end

def print_html_footer
  cgi_puts IO.read("html/footer.html");
end

# RhymeCrime
def compute_and_print_html()
  # CGI Input: word1, word2 (optional)
  # Output: A bunch of stuff
  word1, word2 = parse_cgi_input
  print_html_header(word1, word2)
  compute_and_print_html_middle(word1, word2)
  print_html_footer
end

#
# Similar
#

def similar_column_count
  12 # @todo compute dynamically based on screen width
end

def print_similar_word(word, focal_word)
  word = word.gsub(/\(.*\)/, '') # remove stuff in parentheses
  cgi_print "<td style='color: #{word_similarity_color(word, focal_word)}'>"
  word = word.gsub('_', ' ')
  print word
 cgi_print "</td>"
end

def print_similar_words(similar_words, focal_word)
  success = !similar_words.empty?
  if(success)
    cgi_print "<table><tr>"
    i = 0
    for word in similar_words.sort_by!{|w| -similarity(focal_word, w)}
      if i > 0 && i % similar_column_count == 0
        cgi_print "</tr><tr>"
      end
      i += 1
      print_similar_word(word, focal_word)
      if($display_word_frequencies)
        print " (#{frequency(word)})"
      end
      puts
      end
    cgi_print "</tr></table>"
  end
  return success
end

def compute_and_print_html_similar_middle(word1)
  print_similarity_color_legend
  similar_words = find_related_words(word1, false)
  print_similar_words(similar_words, word1)
end

# Similar
def compute_and_print_similar_html
  # CGI Input: word1, word2 (optional)
  # Output: A bunch of stuff
  word1, word2 = parse_cgi_input
  print_html_header("stub", "stub")
  compute_and_print_html_similar_middle(word1)
  print_html_footer
end
