#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Evaluate thematic relatedness on spec/related.csv (same predicate as RSpec).
#
#   cd <repo> && ruby -I lib experiments/related_weighted_accuracy.rb
#   cd <repo> && ruby -I lib experiments/related_weighted_accuracy.rb --profile
#
# With --profile (or RELATED_PROFILE=1): TracePoint inclusive-time report for related.rb
# (PROFILE_TRACE=related,crime same as experiments/profile_related.rb).
#
# 1) Composite score (MAXIMIZE — 0 is perfect)
#    Penalties per mistake:
#      strong false negative  -9   (expected related, not an "ish" row)
#      ish    false negative  -3   (expected related, notes contain word "ish")
#      strong false positive  -3   (expected unrelated, not ish)
#      ish    false positive  -1   (expected unrelated, ish)
#    Rows are "ish" when the notes column matches /\bish\b/i (word boundary, so not dish/wish/squeamish).
#
# 2) Balanced accuracy: 0.5 * TPR + 0.5 * TNR
#

repo = File.expand_path("..", __dir__)
$LOAD_PATH.unshift File.join(repo, "lib")

def ish_case?(notes)
  notes.to_s.match?(/\bish\b/i)
end

want_profile = ARGV.include?("--profile") || ENV["RELATED_PROFILE"] == "1"

Dir.chdir(repo) do
  require "csv"
  require "rhymecrime/crime"
  require_relative "inclusive_profiler" if want_profile

  path = File.join(repo, "spec", "related.csv")
  rows = CSV.parse(File.read(path, encoding: "UTF-8"), headers: true)

  tp = tn = fp = fn = 0
  pos = neg = 0

  strong_fn = ish_fn = strong_fp = ish_fp = 0
  composite = 0
  weighted_total = 0
  weighted_correct = 0

  prof = nil
  t_wall = nil
  if want_profile
    prof = MethodInclusiveProfiler.new(MethodInclusiveProfiler.patterns_from_env)
    prof.enable
    t_wall = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  rows.each do |r|
    exp = case r["oughta be related?"].to_s.strip
          when "1" then true
          when "0" then false
          else raise "bad oughta be related? #{r['oughta be related?'].inspect} in #{r}"
          end

    notes = r["notes"].to_s
    ish = ish_case?(notes)

    exp ? (pos += 1) : (neg += 1)
    act = thematically_related?(r["word1"], r["word2"], false)

    row_w = if exp
              ish ? 3 : 9
            else
              ish ? 1 : 3
            end
    weighted_total += row_w
    weighted_correct += row_w if act == exp

    if exp
      if act
        tp += 1
      else
        fn += 1
        if ish
          ish_fn += 1
          composite += -3
        else
          strong_fn += 1
          composite += -9
        end
      end
    elsif act
      fp += 1
      if ish
        ish_fp += 1
        composite += -1
      else
        strong_fp += 1
        composite += -3
      end
    else
      tn += 1
    end
  end

  wall_profiled = want_profile && prof ? (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t_wall) : nil
  prof&.disable

  n = rows.size
  accuracy = (tp + tn).to_f / n
  tpr = tp.to_f / pos
  tnr = tn.to_f / neg
  balanced = (tpr + tnr) / 2.0
  prec = (tp + fp).zero? ? 0.0 : (tp.to_f / (tp + fp))

  puts "spec/related.csv  n=#{n}  positive=#{pos}  negative=#{neg}"
  puts
  correct = tp + tn

  weighted_pct = 100.0 * weighted_correct / weighted_total

  puts "=== Composite (MAXIMIZE — 0 is perfect, mistakes add negative weight) ==="
  puts "rows correct: #{correct} / #{n}"
  puts format(
    "weighted accuracy       %.4f%%  (row weights: related strong 9, related ish 3, unrelated strong 3, unrelated ish 1)",
    weighted_pct
  )
  puts format("total composite score: %d", composite)
  puts "  strong false negatives: #{strong_fn}  @ -9 → #{strong_fn * -9}"
  puts "  ish    false negatives: #{ish_fn}  @ -3 → #{ish_fn * -3}"
  puts "  strong false positives: #{strong_fp}  @ -3 → #{strong_fp * -3}"
  puts "  ish    false positives: #{ish_fp}  @ -1 → #{ish_fp * -1}"
  puts
  puts "=== Confusion ==="
  puts "TP=#{tp}  FN=#{fn}  FP=#{fp}  TN=#{tn}"
  puts format("accuracy (micro)        %.6f  (%d correct)", accuracy, tp + tn)
  puts format("balanced accuracy       %.6f  (= 0.5*TPR + 0.5*TNR)", balanced)
  puts format("TPR (related)           %.6f", tpr)
  puts format("TNR (unrelated)         %.6f", tnr)
  puts format("precision (related)     %.6f", prec)

  if want_profile && prof && wall_profiled
    puts
    puts "=== Profile (TracePoint inclusive time, related.rb) ==="
    puts format("Wall time (thematically_related? × %d rows): %.3fs", n, wall_profiled)
    prof.report(top: 40, io: $stdout)
  end
end
