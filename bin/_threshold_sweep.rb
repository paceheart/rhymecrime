#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Sweep classifier decision threshold over the +curated/related.csv+ eval set and
# report the composite / weighted-accuracy / TPR / TNR at each candidate cutoff.
# Bypasses the precomputed SQLite store (so we evaluate the *current* classifier,
# matching +RELATED_BYPASS_STORE=1 spec/related_spec.rb+'s semantics).
#
# Mechanics: we compute the classifier probability +p+ once per eval row (the GBT
# is the bottleneck), then scan thresholds in pure arithmetic — predicate result
# at threshold +t+ is +p >= t+ in +RELATED_LEARNED_MODE=replace+ (default), so
# this is exact, not an approximation. Stop-word rows and +whatever+ rows are
# filtered the same way the RSpec eval filters them.
#
# Usage:
#   bundle exec ruby bin/_threshold_sweep.rb               # default range 0.20..0.55 step 0.01
#   bundle exec ruby bin/_threshold_sweep.rb 0.30 0.50 0.005

repo = File.expand_path("..", __dir__)
$LOAD_PATH.unshift File.join(repo, "lib")
ENV["RELATED_BYPASS_STORE"] = "1"

require "csv"
require "rhymecrime/crime"
require "rhymecrime/relatedness/signals"
require "rhymecrime/relatedness/score"

# CLI: optional [min max step] override.
sweep_min = (ARGV[0] || "0.20").to_f
sweep_max = (ARGV[1] || "0.55").to_f
sweep_step = (ARGV[2] || "0.01").to_f

abort "RELATED_LEARNED_MODE must be 'replace' for the sweep to be exact (got #{$RELATED_LEARNED_MODE.inspect})" \
  unless $RELATED_LEARNED_MODE == "replace"

# Force-load the classifier so we can read its current threshold for the banner.
clf = relatedness_classifier
abort "relatedness classifier failed to load (RELATED_LEARNED_MODE=#{$RELATED_LEARNED_MODE.inspect})" if clf.nil?
clf_t = clf["threshold"].to_f
puts "current classifier threshold = #{format('%.3f', clf_t)}"

# Mirror the RSpec eval filter pipeline.
path = File.join(repo, "curated", "related.csv")
raw_rows = CSV.parse(File.read(path, encoding: "UTF-8"), headers: true)

skipped_stopword = 0
rows = raw_rows.reject do |r|
  w1 = r["cue"]
  w2 = r["related"]
  next true if w1.nil? || w2.nil?
  drop = stop_word?(w1) || stop_word?(w2) || stop_word?(lemma(w1)) || stop_word?(lemma(w2))
  skipped_stopword += 1 if drop
  drop
end

# Score every kept row once. +scored+ holds {p:, exp:, ish:} for the threshold scan.
# +nil+ probabilities (classifier returns nil only when a vector is missing — rare on
# our eval set) are treated as +p = 0+: deterministic "unrelated" regardless of t.
scored = []
skipped_whatever = 0
n_pos = n_neg = 0
rows.each do |r|
  kind = r["oughta be related?"].to_s.strip
  exp = case kind
        when "related", "related_ish" then true
        when "unrelated", "unrelated_ish" then false
        when "whatever", "" then nil
        else raise "bad oughta be related? #{kind.inspect}"
        end
  if exp.nil?
    skipped_whatever += 1
    next
  end
  ish = (kind == "related_ish" || kind == "unrelated_ish")
  exp ? (n_pos += 1) : (n_neg += 1)

  cue_lemma = lemma(r["cue"])
  related_lemma = lemma(r["related"])
  # Directional: +word1+ = cue, +word2+ = related candidate, matching the
  # trainer and runtime predicate (see +bin/train-relatedness-classifier+).
  p = learned_relatedness_probability(PairSignals.new(cue_lemma, related_lemma)) || 0.0
  scored << { p: p, exp: exp, ish: ish }
end

puts format(
  "curated/related.csv  n=%d  positive=%d  negative=%d  (+%d whatever skipped, %d stop-word pairs filtered)",
  scored.size, n_pos, n_neg, skipped_whatever, skipped_stopword
)
puts

# Tally composite / weighted-accuracy / confusion at a given threshold. Mirrors the
# RSpec evaluator's class-balanced -3 / -1 schedule (3× weight on strong rows,
# 1× on +*_ish+; FN penalty == FP penalty within each weight tier).
def tally(scored, t)
  tp = tn = fp = fn_ = 0
  sfn = ifn = sfp = ifp = 0
  composite = 0
  weighted_total = 0
  weighted_correct = 0
  scored.each do |r|
    pred = r[:p] >= t
    base_w = r[:ish] ? 1 : 3
    weighted_total += base_w
    if pred == r[:exp]
      weighted_correct += base_w
      r[:exp] ? (tp += 1) : (tn += 1)
    elsif r[:exp]
      fn_ += 1
      if r[:ish] then ifn += 1; composite += -1
      else sfn += 1; composite += -3
      end
    else
      fp += 1
      if r[:ish] then ifp += 1; composite += -1
      else sfp += 1; composite += -3
      end
    end
  end
  tpr = tp.to_f / [tp + fn_, 1].max
  tnr = tn.to_f / [tn + fp, 1].max
  weighted_pct = 100.0 * weighted_correct / weighted_total
  bal = 0.5 * (tpr + tnr)
  {
    threshold: t, composite: composite, weighted_pct: weighted_pct,
    tp: tp, fn: fn_, fp: fp, tn: tn, tpr: tpr, tnr: tnr, bal: bal,
    sfn: sfn, ifn: ifn, sfp: sfp, ifp: ifp,
  }
end

candidates = []
t = sweep_min
while t <= sweep_max + 1e-9
  candidates << t.round(4)
  t += sweep_step
end

results = candidates.map { |tt| tally(scored, tt) }

puts format("%-7s  %-10s  %-9s  %-7s  %-7s  %-7s  %-5s %-5s %-5s %-5s",
            "thresh", "composite", "weighted%", "TPR", "TNR", "balanced",
            "sfn", "ifn", "sfp", "ifp")
results.each do |s|
  puts format("%-7.3f  %-10d  %8.2f%%  %6.2f%%  %6.2f%%  %6.2f%%  %-5d %-5d %-5d %-5d",
              s[:threshold], s[:composite], s[:weighted_pct],
              s[:tpr] * 100, s[:tnr] * 100, s[:bal] * 100,
              s[:sfn], s[:ifn], s[:sfp], s[:ifp])
end

best_composite = results.max_by { |r| r[:composite] }
best_weighted = results.max_by { |r| r[:weighted_pct] }
best_balanced = results.max_by { |r| r[:bal] }

puts
puts format("best composite : t=%.3f  composite=%d  weighted=%.2f%%  TPR=%.2f%%  TNR=%.2f%%",
            best_composite[:threshold], best_composite[:composite], best_composite[:weighted_pct],
            best_composite[:tpr] * 100, best_composite[:tnr] * 100)
puts format("best weighted%% : t=%.3f  composite=%d  weighted=%.2f%%  TPR=%.2f%%  TNR=%.2f%%",
            best_weighted[:threshold], best_weighted[:composite], best_weighted[:weighted_pct],
            best_weighted[:tpr] * 100, best_weighted[:tnr] * 100)
puts format("best balanced  : t=%.3f  composite=%d  weighted=%.2f%%  TPR=%.2f%%  TNR=%.2f%%",
            best_balanced[:threshold], best_balanced[:composite], best_balanced[:weighted_pct],
            best_balanced[:tpr] * 100, best_balanced[:tnr] * 100)
