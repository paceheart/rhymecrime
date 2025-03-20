#!/usr/bin/env ruby

require_relative 'crime'

word1 = ARGV[0]
word2 = ARGV[1]
raise "Must specify two words to debug" unless word1 && word2
puts "Debugging '#{word1}' and '#{word2}'"

wet = IndexedWetCorpus.new
$debug_mode = true

puts "related? #{related?(word1, word2)}"
puts "adjusted gloss cooccurrence: #{adjusted_gloss_cooccurrence(word1, word2)}"
wet.print_cooccurrence(word1, word2)
puts wet.cooccurrence_documents(word1, word2)
