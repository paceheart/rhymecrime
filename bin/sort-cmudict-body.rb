#!/usr/bin/env ruby
# encoding: utf-8
# frozen_string_literal: true

# Re-sort corpora/cmudict/cmudict-0.7c.txt body lines by ASCII on the
# (n)-stripped headword, then by alt-pron index — see CmudictFileSort.

repo = File.expand_path("..", __dir__)
$LOAD_PATH.unshift File.join(repo, "lib")

require_relative File.join(repo, "lib", "rhymecrime", "dict", "cmudict_file_sort")

path = File.join(repo, "corpora", "cmudict", "cmudict-0.7c.txt")
lines = CmudictFileSort.read_text(path).lines
header = []
i = 0
while i < lines.length
  s = lines[i].strip
  if s.empty? || s.start_with?(";;;")
    header << lines[i]
    i += 1
  else
    break
  end
end

body = lines[i..]
sorted = body.sort_by { |line| CmudictFileSort.body_line_sort_key(line) }

File.write(path, (header + sorted).join, encoding: Encoding::UTF_8)

warn "Sorted #{sorted.size} body lines in #{path} (CMU root order: ASCII on (n)-stripped headword, then alt-pron index)."
