#!/usr/bin/env ruby

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "rhymecrime/frontend/query"
# Eager-load the compute pipeline so the debug run falls through to the rule
# bundle + learned classifier when the compute JSONL has no row for the
# query pair. The runtime shim in lib/rhymecrime/related.rb also lazy-loads
# these at first use.
require "rhymecrime/relatedness/signals"
require "rhymecrime/relatedness/score"

word1 = ARGV[0]
word2 = ARGV[1]
raise "Must specify two words to debug" unless word1 && word2
puts "Debugging '#{word1}' and '#{word2}'"

$debug_mode = true

puts "related? #{related?(word1, word2)}"
puts "thematically_related? #{thematically_related?(word1, word2, false)}"
puts "similarity #{similarity(word1, word2)}"
