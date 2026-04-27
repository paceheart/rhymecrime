#!/usr/bin/env ruby
# frozen_string_literal: true
# encoding: UTF-8
#
# Finds CSV rows the human labelled +unrelated+ / +unrelated_ish+ where
# the USF free-association norms say "related" (direct cue->target with
# any forward strength, OR validated 2-hop). Lets you eyeball the
# "human disagrees with the norms" pairs without filtering on classifier
# output.
Encoding.default_external = Encoding::UTF_8
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "csv"
require "rhymecrime/crime"
require "rhymecrime/relatedness/signals"

word_dict

raw = CSV.read("curated/related.csv", headers: true, encoding: "UTF-8")

direct_hits = []
twohop_only = []
neg_total = 0

raw.each do |r|
  w1 = r["cue"].to_s.strip.downcase
  w2 = r["related"].to_s.strip.downcase
  next if w1.empty? || w2.empty?
  kind = r["oughta be related?"].to_s.strip
  next unless kind == "unrelated" || kind == "unrelated_ish"
  ish = (kind == "unrelated_ish")
  neg_total += 1

  l1 = lemma(w1) || w1
  l2 = lemma(w2) || w2
  a, b = l1 <= l2 ? [l1, l2] : [l2, l1]
  signals = PairSignals.new(a, b)
  next if signals.involves_stop_word?

  direct = signals.usf_direct_max.to_i
  twohop = signals.usf_twohop_validated?

  rec = {
    a: a, b: b, w1: w1, w2: w2, ish: ish,
    direct: direct, twohop: twohop,
    notes: r["notes"].to_s,
  }
  if direct > 0
    direct_hits << rec
  elsif twohop
    twohop_only << rec
  end
end

warn "scanned #{neg_total} negatives (unrelated + unrelated_ish)"

puts
puts "DIRECT USF cue->target hits  (n=#{direct_hits.size}):"
puts "  sorted by USF strength desc; '*' = unrelated_ish"
direct_hits.sort_by { |r| -r[:direct] }.each do |r|
  surf = (r[:a] == r[:w1] && r[:b] == r[:w2]) ? "" : " surf=#{r[:w1]}/#{r[:w2]}"
  marker = r[:ish] ? "*" : " "
  puts "  #{marker} usf=#{r[:direct].to_s.rjust(3)}  #{r[:a]}/#{r[:b]}#{surf}  #{r[:notes][0, 50]}"
end

puts
puts "USF 2-HOP-VALIDATED ONLY  (n=#{twohop_only.size}):"
twohop_only.each do |r|
  surf = (r[:a] == r[:w1] && r[:b] == r[:w2]) ? "" : " surf=#{r[:w1]}/#{r[:w2]}"
  marker = r[:ish] ? "*" : " "
  puts "  #{marker} #{r[:a]}/#{r[:b]}#{surf}  #{r[:notes][0, 50]}"
end

puts
puts "TOTAL USF-vs-human disagreements: #{direct_hits.size + twohop_only.size} / #{neg_total} negatives"
