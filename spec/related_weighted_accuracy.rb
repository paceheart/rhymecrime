#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Evaluate thematic relatedness on spec/related.csv (same predicate as RSpec).
#
#   cd <repo> && ruby -I lib experiments/related_weighted_accuracy.rb
#   cd <repo> && ruby -I lib experiments/related_weighted_accuracy.rb --profile
#   cd <repo> && ruby -I lib experiments/related_weighted_accuracy.rb --failures
#
# With --profile (or RELATED_PROFILE=1): TracePoint inclusive-time report for related.rb
# (PROFILE_TRACE=related,crime same as experiments/profile_related.rb).
#
# With --failures (or RELATED_DUMP_FAILURES=1): per-row diagnostic dump for every mistake,
# grouped by cost bucket (strong FN, ish FN, strong FP, ish FP). Each line shows the lemma
# pair and every signal +thematically_related?+ consults (Numberbatch cosine + ConceptNet
# edge bonus, bidirectional gloss containment, directional sense-vector cosines + morphy
# fallback, USF two-hop cue availability) plus the +why_thematically_related?+ reason that
# won the pair when the predicate said +true+. Useful for grouping failures by root cause
# and for principled threshold / signal work.
#
# 1) Composite score (MAXIMIZE — 0 is perfect)
#    Penalties per mistake:
#      strong false negative  -9   (expected related, not an "ish" row)
#      ish    false negative  -3   (expected related, notes contain word "ish")
#      strong false positive  -3   (expected unrelated, not ish)
#      ish    false positive  -1   (expected unrelated, ish)
#    Rows are "ish" when the +oughta be related?+ column is +related_ish+ or +unrelated_ish+.
#    Rows marked +whatever+ are skipped (either answer is acceptable).
#
# 2) Balanced accuracy: 0.5 * TPR + 0.5 * TNR
#

repo = File.expand_path("..", __dir__)
$LOAD_PATH.unshift File.join(repo, "lib")

def ish_kind?(kind)
  k = kind.to_s.strip
  k == "related_ish" || k == "unrelated_ish"
end

want_profile = ARGV.include?("--profile") || ENV["RELATED_PROFILE"] == "1"
want_failures = ARGV.include?("--failures") || ENV["RELATED_DUMP_FAILURES"] == "1"

# Diagnostic line for a single failure: shows lemma pair, every phase-1 signal, the
# phase-2 composite +relatedness_score+, and the +why_thematically_related?+ reason
# (may be non-nil on a false-positive row, nil on a false-negative row).
def related_failure_diagnostic_line(word1, word2, kind)
  l1 = lemma(word1)
  l2 = lemma(word2)
  a, b = l1 <= l2 ? [l1, l2] : [l2, l1]
  signals = PairSignals.new(a, b)

  morphy = signals.both_have_sense_vectors? ? nil : signals.morphy_sv_directional
  usf_cue_a = !usf_associations[a].nil?
  usf_cue_b = !usf_associations[b].nil?
  reason = why_thematically_related?(word1, word2, false)

  format(
    "%-20s %-20s kind=%-14s l=(%-18s %-18s) score=%3d base=%3d cos=%3d edge=%6.2f gloss=%-5s sv=(%d,%d) n=(%d,%d) morphy=%s usf=(%s,%s) reason=%s",
    word1, word2, kind, a, b,
    relatedness_score(signals), signals.base_similarity, signals.cos_pct, signals.edge_weight,
    signals.gloss_match?.to_s,
    signals.sv_d1, signals.sv_d2, signals.sv_a_count, signals.sv_b_count,
    morphy.inspect,
    usf_cue_a, usf_cue_b,
    reason
  )
end

Dir.chdir(repo) do
  require "csv"
  require "rhymecrime/crime"
  # +PairSignals+ / +relatedness_score+ / +usf_associations+ live in the
  # relatedness compute pipeline, which +rhymecrime/crime+ no longer pulls in
  # at require time. Load it explicitly so the diagnostic path works without
  # relying on the runtime shim's lazy-load.
  require "rhymecrime/relatedness/signals"
  require "rhymecrime/relatedness/score"
  require_relative "inclusive_profiler" if want_profile

  path = File.join(repo, "spec", "related.csv")
  rows = CSV.parse(File.read(path, encoding: "UTF-8"), headers: true)

  tp = tn = fp = fn = 0
  pos = neg = 0

  strong_fn = ish_fn = strong_fp = ish_fp = 0
  composite = 0
  weighted_total = 0
  weighted_correct = 0

  failures_strong_fn = []
  failures_ish_fn = []
  failures_strong_fp = []
  failures_ish_fp = []

  prof = nil
  t_wall = nil
  if want_profile
    prof = MethodInclusiveProfiler.new(MethodInclusiveProfiler.patterns_from_env)
    prof.enable
    t_wall = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  skipped_whatever = 0
  rows.each do |r|
    kind = r["oughta be related?"].to_s.strip
    exp = case kind
          when "related", "related_ish" then true
          when "unrelated", "unrelated_ish" then false
          when "whatever" then nil
          else raise "bad oughta be related? #{r['oughta be related?'].inspect} in #{r}"
          end

    if exp.nil?
      skipped_whatever += 1
      next
    end

    ish = ish_kind?(kind)

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
          failures_ish_fn << related_failure_diagnostic_line(r["word1"], r["word2"], kind) if want_failures
        else
          strong_fn += 1
          composite += -9
          failures_strong_fn << related_failure_diagnostic_line(r["word1"], r["word2"], kind) if want_failures
        end
      end
    elsif act
      fp += 1
      if ish
        ish_fp += 1
        composite += -1
        failures_ish_fp << related_failure_diagnostic_line(r["word1"], r["word2"], kind) if want_failures
      else
        strong_fp += 1
        composite += -3
        failures_strong_fp << related_failure_diagnostic_line(r["word1"], r["word2"], kind) if want_failures
      end
    else
      tn += 1
    end
  end

  wall_profiled = want_profile && prof ? (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t_wall) : nil
  prof&.disable

  n = rows.size - skipped_whatever
  accuracy = (tp + tn).to_f / n
  tpr = tp.to_f / pos
  tnr = tn.to_f / neg
  balanced = (tpr + tnr) / 2.0
  prec = (tp + fp).zero? ? 0.0 : (tp.to_f / (tp + fp))

  puts "spec/related.csv  n=#{n}  positive=#{pos}  negative=#{neg}  (+#{skipped_whatever} whatever rows skipped)"
  puts
  correct = tp + tn

  weighted_pct = 100.0 * weighted_correct / weighted_total

  puts "=== Composite (MAXIMIZE — 0 is perfect, mistakes add negative weight) ==="
  puts "rows correct: #{correct} / #{n}"
  puts format(
    "weighted accuracy       %.1f%%  (row weights: related strong 9, related ish 3, unrelated strong 3, unrelated ish 1)",
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

  if want_failures
    [
      ["STRONG FALSE NEGATIVES (expected related; penalty -9 each)", failures_strong_fn],
      ["ISH FALSE NEGATIVES (expected related_ish; penalty -3 each)", failures_ish_fn],
      ["STRONG FALSE POSITIVES (expected unrelated; penalty -3 each)", failures_strong_fp],
      ["ISH FALSE POSITIVES (expected unrelated_ish; penalty -1 each)", failures_ish_fp],
    ].each do |title, lines|
      puts
      puts "=== #{title} ==="
      puts "count: #{lines.size}"
      lines.each { |l| puts l }
    end
  end

  if want_profile && prof && wall_profiled
    puts
    puts "=== Profile (TracePoint inclusive time, related.rb) ==="
    puts format("Wall time (thematically_related? × %d rows): %.3fs", n, wall_profiled)
    prof.report(top: 40, io: $stdout)
  end
end
