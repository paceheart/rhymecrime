#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Memory profile for bin/dict-build (MemoryProfiler gem).
# Usage:
#   ruby tmp/memory-profile-dict-build.rb              # skips ConceptNet/Numberbatch (faster)
#   ruby tmp/memory-profile-dict-build.rb --full         # full rebuild
# Output: tmp/memory-profiler-dict-build-report.txt

require "memory_profiler"

repo = File.expand_path("..", __dir__)
out = File.join(repo, "tmp", "memory-profiler-dict-build-report.txt")
dict_dir = File.join(repo, "lib", "rhymecrime", "dict")
$LOAD_PATH.unshift File.join(repo, "lib")

if ARGV.include?("--full")
  ENV.delete("RHYMECRIME_DICT_SKIP_CONCEPTNET_NUMBERBATCH")
else
  ENV["RHYMECRIME_DICT_SKIP_CONCEPTNET_NUMBERBATCH"] = "1"
end

report = MemoryProfiler.report do
  Dir.chdir(dict_dir) do
    load File.join(dict_dir, "dict.rb")
    rebuild_rhymecrime_dictionaries
  end
end

File.open(out, "w") do |io|
  report.pretty_print(io)
end
puts "Wrote #{out}"
