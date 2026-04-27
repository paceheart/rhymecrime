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
#    Base penalties per mistake:
#      strong false negative  -3   (expected related, not an "ish" row)
#      ish    false negative  -1   (expected related, notes contain word "ish")
#      strong false positive  -3   (expected unrelated, not ish)
#      ish    false positive  -1   (expected unrelated, ish)
#    Rows are "ish" when the +oughta be related?+ column is +related_ish+ or +unrelated_ish+.
#    Rows marked +whatever+ are skipped (either answer is acceptable).
#
#    Two env-var levers let the evaluator mirror training-time class asymmetry
#    (+bin/train-relatedness-classifier+'s +--fn-weight+ / +--fn-penalty+):
#      RELATED_FN_WEIGHT   multiplies the "weighted accuracy" row weights for
#                          positive rows (default 1.0 → symmetric; set to 3.0 to
#                          reproduce the pre-2026 strong-related=9 banner).
#      RELATED_FN_PENALTY  multiplies the FN composite terms (default 1.0; set to
#                          3.0 to reproduce strong-FN=-9 / ish-FN=-3 scoring).
#    Neither knob changes +thematically_related?+'s runtime behavior — they only
#    re-weight the report for apples-to-apples comparison with a given training
#    configuration.
#
#    RELATED_BYPASS_STORE=1   force the compute pipeline (live classifier + rule
#                             bundle) instead of the precomputed SQLite store.
#                             Set this after retraining to evaluate the *current*
#                             pipeline; without it, rows whose precomputed score
#                             is stale (built against an older classifier) are
#                             judged on that stale answer rather than the retrained
#                             one, and the eval can't see your training changes.
#
# 2) Balanced accuracy: 0.5 * TPR + 0.5 * TNR
#

repo = File.expand_path("..", __dir__)
$LOAD_PATH.unshift File.join(repo, "lib")

# Cue → surface forms that should yield identical (or very nearly identical)
# thematic-relatedness classifications. Human judgment, not predicate output:
# if the human who annotated +related.csv+ thinks +pirate+ is related (or
# unrelated) to +X+, they'd make the same call for every form in the list,
# because these derivational / inflectional variants share a single thematic
# neighborhood in ordinary usage.
#
# Used to clone +related.csv+ rows inline: every row where either side is a
# key here spawns extra rows with each variant substituted in, letting the
# evaluation expose pipeline regressions on derived forms that the existing
# +compute_lemma_map+ (which only canonicalizes inflectional morphology)
# doesn't canonicalize to the base.
OUGHTA_BE_IDENTICAL = {
# TODO: investigate different ways of handling inflected/derived forms wrt relatedness
#  "pirate" => %w[pirates piracy pirating piratical],
#  "music"  => %w[musical],
#  "cat"    => %w[cats],
#  "gay"    => %w[gayer gayest],
#  "crime"  => %w[crimes criminal criminals criminality],
#  "food"   => %w[foods],
#  "water"  => %w[waters watery],
}.freeze

def ish_kind?(kind)
  k = kind.to_s.strip
  k == "related_ish" || k == "unrelated_ish"
end

# Expand +rows+ by cloning each row once per derived-form variant of its
# +cue+ / +related+ cells, per +OUGHTA_BE_IDENTICAL+. Each side is expanded
# independently (no cross-product) — for a row +(pirate, crime)+, we emit
# the original plus +(pirates, crime)+, +(piracy, crime)+, ..., +(pirate,
# crimes)+, +(pirate, criminal)+, etc. The +kind+ / +notes+ / ish-ness are
# copied verbatim; the cloning is by construction a no-op on human judgment
# (that's why +OUGHTA_BE_IDENTICAL+ is a human-curated assertion, not a
# derived-from-predicate list).
def expanded_rows_with_clones(rows)
  out = []
  clones = 0
  rows.each do |r|
    out << r
    w1 = r["cue"].to_s.strip.downcase
    w2 = r["related"].to_s.strip.downcase
    if OUGHTA_BE_IDENTICAL.key?(w1)
      OUGHTA_BE_IDENTICAL[w1].each do |variant|
        dup = r.dup
        dup["cue"] = variant
        out << dup
        clones += 1
      end
    end
    if OUGHTA_BE_IDENTICAL.key?(w2)
      OUGHTA_BE_IDENTICAL[w2].each do |variant|
        dup = r.dup
        dup["related"] = variant
        out << dup
        clones += 1
      end
    end
  end
  [out, clones]
end

# For a scored row, the "cue family" for per-family reporting: if either side
# is a +OUGHTA_BE_IDENTICAL+ key or any of its variants, the family is that
# key. nil means the row has no pirate/cat/crime/... cue on either side and
# is irrelevant to the breakdown. If both sides are cue keys (e.g. a row
# +(pirate, crime)+), we pick the cue's family — arbitrary but stable; the
# breakdown is descriptive, not an error partition.
def cue_family_for(w1, w2, family_of_surface)
  family_of_surface[w1] || family_of_surface[w2]
end

want_profile = ARGV.include?("--profile") || ENV["RELATED_PROFILE"] == "1"
want_failures = ARGV.include?("--failures") || ENV["RELATED_DUMP_FAILURES"] == "1"

# Class-asymmetry knobs (see header). Defaults to symmetric; set to 3.0 each to
# reproduce the historical 3:1 banner.
fn_weight = (ENV["RELATED_FN_WEIGHT"] || "1.0").to_f
fn_penalty = (ENV["RELATED_FN_PENALTY"] || "1.0").to_f

# Experimental knob (mirrors +bin/train-relatedness-classifier+): treat
# +whatever+ rows as +unrelated_ish+ instead of skipping them. Scoring them as
# ish-strength negatives honors the "either answer is fine" spirit of the
# annotation while still penalizing overgeneration on them. Set this together
# with the trainer's equivalent +RELATED_WHATEVER_AS_UNRELATED=1+ for matched
# train/eval semantics.
whatever_as_unrelated = ENV["RELATED_WHATEVER_AS_UNRELATED"] == "1"

# Diagnostic line for a single failure: shows lemma pair, every phase-1 signal, the
# phase-2 composite +relatedness_score+, and the +why_thematically_related?+ reason
# (may be non-nil on a false-positive row, nil on a false-negative row).
def related_failure_diagnostic_line(word1, word2, kind)
  # Directional: +word1+ = cue, +word2+ = related candidate, matching the
  # trainer and runtime predicate. The diagnostic must mirror what the predict
  # path actually saw or its +sv_cue_to_related+ / unigram +cue+ / +related+
  # columns will read out backwards on cue-vs-candidate failures.
  a = lemma(word1)
  b = lemma(word2)
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
    signals.sv_cue_to_related, signals.sv_related_to_cue, signals.sv_cue_count, signals.sv_related_count,
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
  raw_rows = CSV.parse(File.read(path, encoding: "UTF-8"), headers: true)
  rows, clone_count = expanded_rows_with_clones(raw_rows)

  # Drop stop-word rows up front. +thematically_related?+ short-circuits any
  # pair involving a stop word to +true+ (contentless glue), which means a row
  # like +("gay", "while", unrelated)+ is an unavoidable FP at the predicate
  # level — it tells us nothing about the classifier or rule bundle and just
  # pads the composite with noise. Mirror the trainer's load-time filter for
  # apples-to-apples numbers. Filter on both surface form and lemma.
  skipped_stopword = 0
  rows = rows.reject do |r|
    w1 = r["cue"]
    w2 = r["related"]
    next true if w1.nil? || w2.nil?
    drop = stop_word?(w1) || stop_word?(w2) || stop_word?(lemma(w1)) || stop_word?(lemma(w2))
    skipped_stopword += 1 if drop
    drop
  end

  # Reverse index: every surface form (key or variant) -> cue-family key.
  # Built once so the scoring loop's family lookup is O(1).
  family_of_surface = {}
  OUGHTA_BE_IDENTICAL.each do |key, variants|
    family_of_surface[key] = key
    variants.each { |v| family_of_surface[v] = key }
  end

  tp = tn = fp = fn = 0
  pos = neg = 0

  strong_fn = ish_fn = strong_fp = ish_fp = 0
  composite = 0
  weighted_total = 0
  weighted_correct = 0

  # Per-family error tracking so you can see which cue family (pirate, crime,
  # music, ...) is dragging the aggregate down. Populated only for rows where
  # at least one side is an +OUGHTA_BE_IDENTICAL+ surface form.
  family_stats = Hash.new do |h, k|
    h[k] = { rows: 0, correct: 0, sfn: 0, ifn: 0, sfp: 0, ifp: 0, composite: 0 }
  end

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

  # Composite penalty schedule: base +-3 / -1+ for "strong / ish", then multiplied
  # by +fn_penalty+ only on FN arms. With both env vars at defaults (1.0) the
  # penalties are symmetric −3/−1/−3/−1; with +RELATED_FN_PENALTY=3+ they revert
  # to the pre-2026 banner (−9/−3/−3/−1).
  ifn_penalty = -1.0 * fn_penalty
  sfn_penalty = -3.0 * fn_penalty
  ifp_penalty = -1.0
  sfp_penalty = -3.0

  skipped_whatever = 0
  relabeled_whatever = 0
  rows.each do |r|
    kind = r["oughta be related?"].to_s.strip
    if kind == "whatever"
      if whatever_as_unrelated
        kind = "unrelated_ish"
        relabeled_whatever += 1
      end
    end
    exp = case kind
          when "related", "related_ish" then true
          when "unrelated", "unrelated_ish" then false
          when "whatever", "" then nil
          else raise "bad oughta be related? #{r['oughta be related?'].inspect} in #{r}"
          end

    if exp.nil?
      skipped_whatever += 1
      next
    end

    ish = ish_kind?(kind)

    exp ? (pos += 1) : (neg += 1)
    act = thematically_related?(r["cue"], r["related"], false)

    base_row_w = ish ? 1.0 : 3.0
    row_w = exp ? base_row_w * fn_weight : base_row_w
    weighted_total += row_w
    weighted_correct += row_w if act == exp

    family = cue_family_for(
      r["cue"].to_s.strip.downcase,
      r["related"].to_s.strip.downcase,
      family_of_surface,
    )
    fs = family ? family_stats[family] : nil
    fs[:rows] += 1 if fs

    if exp
      if act
        tp += 1
        fs[:correct] += 1 if fs
      else
        fn += 1
        if ish
          ish_fn += 1
          composite += ifn_penalty
          if fs
            fs[:ifn] += 1
            fs[:composite] += ifn_penalty
          end
          failures_ish_fn << related_failure_diagnostic_line(r["cue"], r["related"], kind) if want_failures
        else
          strong_fn += 1
          composite += sfn_penalty
          if fs
            fs[:sfn] += 1
            fs[:composite] += sfn_penalty
          end
          failures_strong_fn << related_failure_diagnostic_line(r["cue"], r["related"], kind) if want_failures
        end
      end
    elsif act
      fp += 1
      if ish
        ish_fp += 1
        composite += ifp_penalty
        if fs
          fs[:ifp] += 1
          fs[:composite] += ifp_penalty
        end
        failures_ish_fp << related_failure_diagnostic_line(r["cue"], r["related"], kind) if want_failures
      else
        strong_fp += 1
        composite += sfp_penalty
        if fs
          fs[:sfp] += 1
          fs[:composite] += sfp_penalty
        end
        failures_strong_fp << related_failure_diagnostic_line(r["cue"], r["related"], kind) if want_failures
      end
    else
      tn += 1
      fs[:correct] += 1 if fs
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

  whatever_note = whatever_as_unrelated ? "#{relabeled_whatever} whatever→unrelated_ish" : "+#{skipped_whatever} whatever skipped"
  puts "spec/related.csv  n=#{n}  positive=#{pos}  negative=#{neg}  (#{whatever_note}, #{skipped_stopword} stop-word pairs filtered at load)"
  puts "  raw rows=#{raw_rows.size}  +#{clone_count} OUGHTA_BE_IDENTICAL clones across #{OUGHTA_BE_IDENTICAL.size} cue families"
  puts
  correct = tp + tn

  weighted_pct = 100.0 * weighted_correct / weighted_total

  puts "=== Composite (MAXIMIZE — 0 is perfect, mistakes add negative weight) ==="
  puts "rows correct: #{correct} / #{n}"
  puts format(
    "class asymmetry: fn_weight=%.2f  fn_penalty=%.2f  (both 1.0 = symmetric; env: RELATED_FN_WEIGHT / RELATED_FN_PENALTY)",
    fn_weight, fn_penalty
  )
  pos_strong_w = 3.0 * fn_weight
  pos_ish_w = 1.0 * fn_weight
  puts format(
    "weighted accuracy       %.1f%%  (row weights: related strong %.2f, related ish %.2f, unrelated strong 3.00, unrelated ish 1.00)",
    weighted_pct, pos_strong_w, pos_ish_w
  )
  puts format("total composite score: %.1f", composite)
  puts format("  strong false negatives: %d  @ %.1f → %.1f", strong_fn, sfn_penalty, strong_fn * sfn_penalty)
  puts format("  ish    false negatives: %d  @ %.1f → %.1f", ish_fn, ifn_penalty, ish_fn * ifn_penalty)
  puts format("  strong false positives: %d  @ %.1f → %.1f", strong_fp, sfp_penalty, strong_fp * sfp_penalty)
  puts format("  ish    false positives: %d  @ %.1f → %.1f", ish_fp, ifp_penalty, ish_fp * ifp_penalty)
  puts
  puts "=== Confusion ==="
  puts "TP=#{tp}  FN=#{fn}  FP=#{fp}  TN=#{tn}"
  puts format("accuracy (micro)        %.6f  (%d correct)", accuracy, tp + tn)
  puts format("balanced accuracy       %.6f  (= 0.5*TPR + 0.5*TNR)", balanced)
  puts format("TPR (related)           %.6f", tpr)
  puts format("TNR (unrelated)         %.6f", tnr)
  puts format("precision (related)     %.6f", prec)

  unless family_stats.empty?
    puts
    puts "=== Per-cue-family breakdown (OUGHTA_BE_IDENTICAL) ==="
    puts format("%-10s %6s %8s %6s %4s %4s %4s %4s %9s",
      "family", "rows", "correct", "acc%", "sFN", "iFN", "sFP", "iFP", "composite")
    ordered = OUGHTA_BE_IDENTICAL.keys.select { |k| family_stats.key?(k) }
    ordered.each do |fam|
      s = family_stats[fam]
      acc = s[:rows].zero? ? 0.0 : (100.0 * s[:correct] / s[:rows])
      puts format("%-10s %6d %8d %5.1f%% %4d %4d %4d %4d %9.1f",
        fam, s[:rows], s[:correct], acc,
        s[:sfn], s[:ifn], s[:sfp], s[:ifp], s[:composite])
    end
  end

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
