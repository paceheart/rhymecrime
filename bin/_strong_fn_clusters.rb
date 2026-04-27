#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Per-row failure analysis for the +strong false negative+ bucket of the relatedness
# eval (+spec/related.csv+ rows with +oughta be related? = related+ that the current
# classifier predicts unrelated). Dominant cost component on the new harder eval set
# (~1100/4900 weighted-composite penalty), so worth structurally attacking.
#
# Mirrors the +RELATED_BYPASS_STORE=1 spec/related_weighted_accuracy.rb+ predicate
# (live classifier, no store), filters whatever / ish / stop-word rows the same way,
# and dumps each strong FN with the signals that drive +PairSignals+ → classifier
# probability +p+. We also bucket each row by failure mode for an at-a-glance
# distribution.
#
# Buckets (priority order; first match wins):
#   * +oov+              one or both lemmas missing from Numberbatch (no semantic vector at all)
#   * +near_miss+        +p in [threshold-0.10, threshold)+ (high-leverage threshold-dependent FNs)
#   * +mid_miss+         +p in [0.20, threshold-0.10)+ (some signal but classifier under-confident)
#   * +very_low_signal+  +p < 0.20+ (classifier sees ~no positive evidence — annotation drift or feature gap)
#
# Usage:
#   bundle exec ruby bin/_strong_fn_clusters.rb               # full dump
#   bundle exec ruby bin/_strong_fn_clusters.rb --summary     # cluster counts only
#   bundle exec ruby bin/_strong_fn_clusters.rb --sample 60   # random-but-deterministic 60-row spread
#   bundle exec ruby bin/_strong_fn_clusters.rb --tsv         # TSV dump for spreadsheet triage
#                                                             #   (sorted by p ASC — most confidently
#                                                             #   rejected first; best demote candidates)

repo = File.expand_path("..", __dir__)
$LOAD_PATH.unshift File.join(repo, "lib")
ENV["RELATED_BYPASS_STORE"] = "1"

require "csv"
require "rhymecrime/crime"
require "rhymecrime/relatedness/signals"
require "rhymecrime/relatedness/score"

want_summary = ARGV.include?("--summary")
want_tsv = ARGV.include?("--tsv")
sample_n = nil
if (idx = ARGV.index("--sample"))
  sample_n = ARGV[idx + 1].to_i
end

clf = relatedness_classifier
abort "no classifier loaded" if clf.nil?
threshold = clf["threshold"].to_f
puts "classifier threshold = #{format('%.3f', threshold)}"

NEAR_MISS_LO = (threshold - 0.10).round(3)
MID_MISS_LO = 0.20

path = File.join(repo, "spec", "related.csv")
raw_rows = CSV.parse(File.read(path, encoding: "UTF-8"), headers: true)

skipped_stopword = 0
rows = raw_rows.reject do |r|
  w1 = r["cue"]; w2 = r["related"]
  next true if w1.nil? || w2.nil?
  drop = stop_word?(w1) || stop_word?(w2) || stop_word?(lemma(w1)) || stop_word?(lemma(w2))
  skipped_stopword += 1 if drop
  drop
end

# Collect strong-FN rows only (kind=related, classifier says unrelated).
strong_fns = []
rows.each do |r|
  kind = r["oughta be related?"].to_s.strip
  next unless kind == "related" # strong (not ish, not whatever)
  # Directional: +word1+ = cue, +word2+ = related candidate, matching the
  # trainer and runtime predicate. (Pre-2026-04 this script lex-canonicalized,
  # which only stayed coherent because every signal was symmetric in +(a, b)+.)
  a = lemma(r["cue"])
  b = lemma(r["related"])
  signals = PairSignals.new(a, b)
  p = learned_relatedness_probability(signals)
  pred = (p || 0.0) >= threshold
  next if pred # skip true positives

  in_nb_a = dictionary_lemma_has_numberbatch_vector?(a)
  in_nb_b = dictionary_lemma_has_numberbatch_vector?(b)
  def_both_in_vocab = signals.def_both_in_vocab?

  bucket =
    if !in_nb_a || !in_nb_b
      "oov"
    elsif p && p >= NEAR_MISS_LO
      "near_miss"
    elsif p && p >= MID_MISS_LO
      "mid_miss"
    else
      "very_low_signal"
    end

  strong_fns << {
    cue: r["cue"], related: r["related"], a: a, b: b,
    p: p || 0.0,
    base: signals.base_similarity, cos_pct: signals.cos_pct, edge: signals.edge_weight,
    gloss: signals.gloss_match?,
    sv_max: signals.both_have_sense_vectors? ? signals.sv_max : nil,
    sv_min: signals.both_have_sense_vectors? ? signals.sv_min : nil,
    def_cos: (signals.def_cos_pct rescue nil),
    usf_a: !usf_associations[a].nil?, usf_b: !usf_associations[b].nil?,
    in_nb_a: in_nb_a, in_nb_b: in_nb_b,
    def_both_in_vocab: def_both_in_vocab,
    bucket: bucket,
    notes: r["notes"].to_s.strip,
  }
end

bucket_order = %w[near_miss mid_miss very_low_signal oov]
counts = Hash.new(0)
strong_fns.each { |r| counts[r[:bucket]] += 1 }

puts
puts "strong-FN total: #{strong_fns.size}"
bucket_order.each do |bn|
  c = counts[bn]
  pct = strong_fns.empty? ? 0 : (100.0 * c / strong_fns.size)
  puts format("  %-16s %4d  (%5.1f%%)", bn, c, pct)
end

if want_summary
  exit 0
end

# TSV triage dump: write every strong-FN row to +notes/strong-fn-audit.tsv+ sorted by
# +p+ ASCENDING (most confidently-rejected first — these are the rows the classifier
# disagrees with most strongly, which makes them top demote-to-+related_ish+ candidates).
# Includes a +decision+ column the user fills in by hand (e.g. +keep+ / +ish+ /
# +whatever+ / +unrelated+) and re-imports.
if want_tsv
  out_path = File.join(repo, "notes", "strong-fn-audit.tsv")
  cols = %w[
    decision cue related p bucket
    base cos_pct edge gloss sv_max sv_min def_cos
    usf_a usf_b in_nb_a in_nb_b def_both_in_vocab
    lemma_a lemma_b notes
  ]
  File.open(out_path, "w") do |f|
    f.puts cols.join("\t")
    strong_fns.sort_by { |r| r[:p] }.each do |r|
      vals = {
        "decision" => "",
        "cue" => r[:cue], "related" => r[:related],
        "p" => format("%.3f", r[:p]), "bucket" => r[:bucket],
        "base" => r[:base], "cos_pct" => r[:cos_pct], "edge" => format("%.2f", r[:edge]),
        "gloss" => r[:gloss] ? 1 : 0,
        "sv_max" => r[:sv_max] || "", "sv_min" => r[:sv_min] || "",
        "def_cos" => r[:def_cos] || "",
        "usf_a" => r[:usf_a] ? 1 : 0, "usf_b" => r[:usf_b] ? 1 : 0,
        "in_nb_a" => r[:in_nb_a] ? 1 : 0, "in_nb_b" => r[:in_nb_b] ? 1 : 0,
        "def_both_in_vocab" => r[:def_both_in_vocab] ? 1 : 0,
        "lemma_a" => r[:a], "lemma_b" => r[:b],
        "notes" => r[:notes].to_s.tr("\t", " "),
      }
      f.puts cols.map { |c| vals[c] }.join("\t")
    end
  end
  puts
  puts "wrote #{strong_fns.size} strong-FN rows to #{out_path}"
  puts "(sorted by classifier probability ascending — top of file is most-confidently-rejected)"
  exit 0
end

# Dump (or sample) per-bucket. Sort within bucket by descending +p+ so the most
# rescuable cases appear first within each cluster.
bucket_order.each do |bn|
  rows_b = strong_fns.select { |r| r[:bucket] == bn }.sort_by { |r| -r[:p] }
  next if rows_b.empty?
  if sample_n
    seed = bn.bytes.sum
    rng = Random.new(seed)
    rows_b = rows_b.shuffle(random: rng).first([sample_n / bucket_order.size, 1].max)
  end
  puts
  puts "=== #{bn} (#{rows_b.size} of #{counts[bn]} shown) ==="
  rows_b.each do |r|
    sv = r[:sv_max].nil? ? "    -    " : format("%2d/%2d", r[:sv_max], r[:sv_min])
    flags = []
    flags << "no-nb-a" unless r[:in_nb_a]
    flags << "no-nb-b" unless r[:in_nb_b]
    flags << "no-def-pair" unless r[:def_both_in_vocab]
    flags << "gloss" if r[:gloss]
    flags << "usf-a" if r[:usf_a]
    flags << "usf-b" if r[:usf_b]
    puts format(
      "  p=%.3f  l=(%-18s %-18s)  base=%3d  cos=%3d  edge=%5.2f  sv=%s  def_cos=%s  %s",
      r[:p], r[:a], r[:b], r[:base], r[:cos_pct], r[:edge], sv,
      r[:def_cos].nil? ? "  -" : format("%3d", r[:def_cos]),
      flags.join(",")
    )
  end
end
