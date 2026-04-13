#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Strong related.csv rows (expected related, not "ish") where surface scoring passes but
# lemma-conflated scoring fails — with Numberbatch cosines for pattern search.
#
#   cd <repo> && ruby -I lib spec/lemma_conflation_regression_cosines.rb
#
# Surface pass: +thematically_related_pair_uncached?+ on sorted surface headwords.
# Lemma pass:   same on sorted +lemma(word1)+, +lemma(word2)+ (dict-build lemma column).

repo = File.expand_path("..", __dir__)
$LOAD_PATH.unshift File.join(repo, "lib")

def ish_case?(notes)
  notes.to_s.match?(/\bish\b/i)
end

def sorted_surface(w1, w2)
  w1 <= w2 ? [w1, w2] : [w2, w1]
end

def thematically_related_surface_uncached?(w1, w2)
  return false if stop_word?(w1) || stop_word?(w2)

  a, b = sorted_surface(w1, w2)
  thematically_related_pair_uncached?(a, b)
end

def thematically_related_lemma_conflated_uncached?(w1, w2)
  return false if stop_word?(w1) || stop_word?(w2)

  l1 = lemma(w1)
  l2 = lemma(w2)
  a, b = sorted_surface(l1, l2)
  thematically_related_pair_uncached?(a, b)
end

# Numberbatch table keys are base lemmas; +numberbatch_cosine+ expects lemmas. For diagnostics we still
# want cosines that mix surface vs base keys without double-+lemma+.
def numberbatch_cosine_raw_spellings(k1, k2)
  nb = numberbatch_table
  v1 = nb[hyphens_to_underscores(k1)]
  v2 = nb[hyphens_to_underscores(k2)]
  return 0.0 if v1.nil? || v2.nil?

  dot = 0.0
  v1.size.times { |i| dot += v1[i] * v2[i] }
  dot
end

Dir.chdir(repo) do
  require "csv"
  require "rhymecrime/crime"

  path = File.join(repo, "spec", "related.csv")
  rows = CSV.parse(File.read(path, encoding: "UTF-8"), headers: true)

  regressions = []
  rows.each_with_index do |r, i|
    exp = case r["oughta be related?"].to_s.strip
          when "1" then true
          when "0" then false
          else next
          end
    next unless exp
    next if ish_case?(r["notes"])

    w1 = r["word1"].to_s.strip
    w2 = r["word2"].to_s.strip
    next if w1.empty? || w2.empty?

    surf = thematically_related_surface_uncached?(w1, w2)
    lem = thematically_related_lemma_conflated_uncached?(w1, w2)
    next unless surf && !lem

    l1 = lemma(w1)
    l2 = lemma(w2)
    c_ab = numberbatch_cosine_raw_spellings(w1, w2)
    c_lb = numberbatch_cosine_raw_spellings(l1, w2)
    c_al = numberbatch_cosine_raw_spellings(w1, l2)
    c_ll = numberbatch_cosine(l1, l2)

    regressions << {
      csv_row: i + 2, # 1-based file line ≈ header + 1 + i
      w1: w1, w2: w2, l1: l1, l2: l2,
      c_ab: c_ab, c_lb: c_lb, c_al: c_al, c_ll: c_ll,
      notes: r["notes"].to_s.strip.tr("\t", " ")[0, 80],
    }
  end

  puts "Strong related.csv rows: surface OK, lemma-conflation FAIL (#{regressions.size} total)"
  puts ""
  puts [
    "csv_row", "A", "B", "lemma(A)", "lemma(B)",
    "cos(A,B)", "cos(lemma(A),B)", "cos(A,lemma(B))", "cos(lemma(A),lemma(B))",
    "notes_preview",
  ].join("\t")

  regressions.each do |x|
    puts [
      x[:csv_row], x[:w1], x[:w2], x[:l1], x[:l2],
      format("%.5f", x[:c_ab]), format("%.5f", x[:c_lb]), format("%.5f", x[:c_al]), format("%.5f", x[:c_ll]),
      x[:notes],
    ].join("\t")
  end
end
