#!/usr/bin/env ruby

require_relative 'crime'

word1 = ARGV[0]
word2 = ARGV[1]
raise "Must specify two words to debug" unless word1 && word2
puts "Debugging '#{word1}' and '#{word2}'"

$debug_mode = true

puts "related? #{related?(word1, word2)}"
puts "semantically_related? #{semantically_related?(word1, word2, false)}"
puts "similarity #{similarity(word1, word2)}"
