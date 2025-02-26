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

def print_html_header(word1, word2, lang)
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

  if(lang=="es")
    head = head.gsub("rhyme.rb", "rimar.rb")
    head = head.gsub("Word:", "Palabra:")
    head = head.gsub("Word 2:", "Palabra 2:")
    head = head.gsub("value=Search", "value=Busca")
    head = head.gsub("(optional)", "(opcional)")
  end
  cgi_puts head
  debug "DEBUG MODE"
end

def compute_and_print_html_middle(word1, word2, lang)
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
    output, dregs, type, header = rhymecrime(word1, word2, goal, lang, OUTPUT_FORMAT, DEBUG_MODE)
    print_html_column(goal, output, dregs, word1, type, header, width, lang, i == goals.length - 1)
  end
end

def print_html_column(goal, output, dregs, input_word1, type, header, width, lang, is_last_column)
  cgi_puts "<td style='vertical-align: top; width:#{width}%;' label='#{goal}'>"
  print_html_column_data(output, dregs, input_word1, type, header, lang)
  cgi_puts "</td>"
  unless(is_last_column)
    # 3% spacing between columns
    cgi_puts "<td style='width:1%;'> </td>" # @todo fix width computation
    cgi_puts "<td style='border-left: 2px solid; width:2%;'> </td>"
  end  
end

def print_html_column_data(output, dregs, input_word1, type, header, lang)
  case type # :words, :tuples, :synsets, :bad_input, :error
  when :words, :tuples, :synsets
    print_interesting_html_column_data(output, dregs, input_word1, header, lang, type)
  when :bad_input
    puts header
  when :error
    case lang
    when "en"
      puts "Unexpected error."
    when "es"
      puts "Error inesperado."
    else
      puts "Unexpected language #{lang}"
    end
  else
    case lang
    when "en"
      puts "Very unexpected error."
    when "es"
      puts "Error muy inesperado."
    else
      puts "Very unexpected language #{lang}"
    end
  end
end

def print_interesting_html_column_data(output, dregs, input_word1, header, lang, output_type)
  cgi_puts header
  if output.empty?
    if dregs.empty?
      puts lang(lang, "No matching results.", "Ningun resultados coincidos.")
    else
      puts lang(lang, "No good results.", "Ningun resultados buenos.")
    end
  else
    print_output(output, input_word1, lang, output_type)
  end
  if(!dregs.empty?)
    cgi_puts "<br/><hr><p>"
    puts lang(lang, "For the desperate:", "Para los desesperados:")
    cgi_puts "</p>"
    print_output(dregs, input_word1, lang, output_type)
  end
end

def print_output(output, input_word1, lang, output_type)
  case output_type
  when :words
    print_words(output, lang)
  when :tuples
    print_tuples(output, lang)
  when :synsets
    print_synsets(output, input_word1, lang)
  end
end

def print_html_footer
  cgi_puts IO.read("html/footer.html");
end

def compute_and_print_html(lang)
  # CGI Input: word1, word2 (optional)
  # Output: A bunch of stuff
  word1, word2 = parse_cgi_input
  print_html_header(word1, word2, lang)
  compute_and_print_html_middle(word1, word2, lang)
  print_html_footer
end

