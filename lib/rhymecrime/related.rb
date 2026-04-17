#!/usr/bin/env ruby
# coding: utf-8
#
# related.rb — runtime relatedness lookup. Load: require "rhymecrime/related"
#
# Answers every relatedness question — "is this pair topically related?",
# "what's the similarity score?", "which headwords are related to this cue?"
# — from a precomputed source:
#
#   * DynamoDB (+Rhymecrime::DataSource.dynamodb?+): items at +related#<lemma>+
#     carry parallel +words+ + +scores+ attributes.
#   * Precompute JSONL (+generated/related_precompute.jsonl+): same schema,
#     read once at load time.
#
# Neither path pulls in Numberbatch, ConceptNet, WordNet, USF, MPNet, or the
# learned classifier — those live in +lib/rhymecrime/relatedness/*+ and are
# only required at seed time (+bin/precompute-relatedness+,
# +bin/train-relatedness-classifier+, related specs) or by the local-dev
# fallback below.
#
# Local-dev fallback: when neither DynamoDB is configured nor the precompute
# JSONL exists (fresh clone, running specs before precompute), +similarity+
# returns 0 and the thematic predicates lazy-require the full compute
# pipeline (+relatedness/signals+ + +score+ + +scan+) and fall through to it.
#
# Accepted trade-off: when neither (A, B) is a cached cue, +similarity(A, B)+
# returns 0 and +thematically_related?(A, B)+ is false at runtime — typical
# for pairs where both sides are rare headwords (no row in precompute).
#

require "json"
require_relative "pace_utils"
require_relative "dict/utils_rhyme"

SIMILAR_MAX = 50000 # O_o

# Composite-score threshold for "topically related" (see +relatedness_score+ in
# +relatedness/score.rb+). Also the floor of every entry in a precomputed
# related-words list — anything below 50 is by definition unrelated.
RELATEDNESS_SCORE_THRESHOLD = 50

def related_trace_memo?
  ENV["RELATED_TRACE_MEMO"].to_s == "1"
end

# Lazy-require the full relatedness compute pipeline. Only invoked when neither
# DynamoDB nor the precompute JSONL has an answer (local-dev / spec fallback).
# Once loaded, heavy knowledge bases (Numberbatch, ConceptNet, WordNet, etc.)
# stay in memory for the life of the process.
$relatedness_compute_loaded = false
def relatedness_lazy_load_compute!
  return if $relatedness_compute_loaded
  require_relative "relatedness/signals"
  require_relative "relatedness/score"
  require_relative "relatedness/scan"
  $relatedness_compute_loaded = true
end

# --- Runtime similarity (cached relatedness_score 0..100) ---

# Stored relatedness_score (0..100 integer) between two headwords, read from
# the precomputed source. Returns 0 when neither endpoint is a cached cue or
# either side is a stop word (stop words short-circuit to "related" in the
# predicate but contribute no UI-meaningful similarity score).
def similarity(word1, word2)
  return 0 if stop_word?(word1) || stop_word?(word2)
  RelatedWords.lookup_score(word1, word2)
end

def percent_similarity(word1, word2)
  "#{similarity(word1, word2)}%"
end

# Map the stored +relatedness_score+ (0..100 integer) to a legend color. Bands
# are sized for roughly equal mass across the observed stored-pair distribution
# (six ~1/6-quantile buckets above the +RELATEDNESS_SCORE_THRESHOLD+ floor,
# plus a red "unrelated" band for anything below).
def similarity_color(score)
  s = score.to_i
  if s >= 98
    "violet"
  elsif s >= 86
    "#aa33cc" # purple
  elsif s >= 72
    "#8888ff" # blue
  elsif s >= 62
    "#00cc22" # green
  elsif s >= 56
    "yellow"
  elsif s >= 50
    "orange"
  else
    "#ff5555" # red
  end
end

def word_similarity_color(word1, word2)
  similarity_color(similarity(word1, word2))
end

def print_similarity_color_legend_entry(score, text)
  cgi_print "<td style='color: #{similarity_color(score)}'><font size=-2>#{text}</font></td><td>&nbsp;</td>"
end

def print_similarity_color_legend
  cgi_print "<table><tr><td><font size=-2>legend:&nbsp;</font></td>"
  print_similarity_color_legend_entry(0,  "unrelated")
  print_similarity_color_legend_entry(50, "almost related")
  print_similarity_color_legend_entry(56, "barely related")
  print_similarity_color_legend_entry(62, "somewhat related")
  print_similarity_color_legend_entry(72, "related")
  print_similarity_color_legend_entry(86, "strongly related")
  print_similarity_color_legend_entry(98, "related af")
  cgi_print "</tr></table>"
end

def print_html_percent_similarity(word, focal_word)
  cgi_print " <span style='color: #{word_similarity_color(word, focal_word)}'>(#{percent_similarity(word, focal_word)})</span>"
end

def print_similarity(word1, word2)
  puts "#{word1} #{word2}: #{similarity(word1, word2)}"
end

# --- Thematic relatedness predicate ---

# True iff the two headwords are topically related. Symmetric. Stop words are
# treated as related to every other word (contentless glue). At runtime the
# predicate is answered from the precomputed source via
# +RelatedWords.pair_in_precomputed?+; only the local-dev fallback lazy-loads
# the full compute pipeline.
def thematically_related?(word1, word2, include_self = false)
  if ENV["RELATED_TRACE_THEMATIC"] == "1"
    warn "thematically_related? word1=#{word1.inspect} word2=#{word2.inspect} include_self=#{include_self.inspect}"
  end

  return true if include_self && (word1 == word2 || lemma(word1) == lemma(word2))
  return true if stop_word?(word1) || stop_word?(word2)

  puts "thematically_related? #{word1} #{word2}" if related_trace_memo?

  l1 = lemma(word1)
  l2 = lemma(word2)
  a, b = l1 <= l2 ? [l1, l2] : [l2, l1]
  puts "  -> lemma key #{a} #{b}" if related_trace_memo?

  return true if RelatedWords.pair_in_precomputed?(a, b)

  # DDB is the canonical runtime source: if it doesn't have the pair, we
  # accept the "missing means unrelated" trade-off (see file header) and
  # return false without ever loading the compute pipeline. The precompute
  # JSONL is weaker — it's a dev-time cache that may not cover every pair —
  # so we fall through to compute on miss instead of a hard false. Lambda
  # never hits the fallback because DDB is always configured there.
  return false if defined?(Rhymecrime::DataSource) && Rhymecrime::DataSource.dynamodb?

  relatedness_lazy_load_compute!
  thematically_related_pair_memoized?(a, b)
end

# Same decision as +thematically_related?+, but returns a short reason string
# when true, or +nil+ when false.
def why_thematically_related?(word1, word2, include_self = false)
  return "self: same headword" if include_self && word1 == word2
  return "self: same lexeme (lemma)" if include_self && lemma(word1) == lemma(word2)
  return "stop_word: #{word1.inspect} is a stop word (related to everything)" if stop_word?(word1)
  return "stop_word: #{word2.inspect} is a stop word (related to everything)" if stop_word?(word2)

  l1 = lemma(word1)
  l2 = lemma(word2)
  a, b = l1 <= l2 ? [l1, l2] : [l2, l1]

  score = RelatedWords.lookup_score_by_lemmas(a, b)
  return "precomputed: topically related (score=#{score})" if score >= RELATEDNESS_SCORE_THRESHOLD

  # DDB mode is authoritative (see +thematically_related?+): no compute
  # fallback, so there's no "why" to report on a miss.
  return nil if defined?(Rhymecrime::DataSource) && Rhymecrime::DataSource.dynamodb?

  relatedness_lazy_load_compute!
  why_thematically_related_full?(word1, word2, include_self)
end

# --- RelatedWords: cue -> related headwords (+ stored scores) ---

# Enumerates RhymeCrime headwords and returns those topically related to a cue.
# Prefers DynamoDB (when configured) or the precompute JSONL; falls back to the
# lazy-loaded full scan for local dev.
class RelatedWords
  class << self
    # Lazy-loaded {lemma => [[word, score], ...]} from the precompute JSONL.
    # Empty hash when the file doesn't exist — that's the signal to the
    # runtime shim that we have no precomputed source (so thematic predicates
    # will fall back to the lazy-loaded compute pipeline).
    def related_precompute_by_lemma
      return @related_precompute_by_lemma if instance_variable_defined?(:@related_precompute_by_lemma)

      @related_precompute_by_lemma = {}
      path = generated_dict_path(RELATED_PRECOMPUTE_JSONL_FILENAME)
      unless File.exist?(path)
        return @related_precompute_by_lemma
      end

      n = 0
      File.foreach(path, encoding: "UTF-8") do |line|
        line = line.strip
        next if line.empty?

        obj = JSON.parse(line)
        pk = obj["pk"].to_s
        next unless pk.start_with?("related#")

        lem = pk.delete_prefix("related#")
        words = obj["words"]
        next unless words.is_a?(Array)

        scores = obj["scores"]
        scores = [] unless scores.is_a?(Array)
        tuples = words.each_with_index.map do |w, i|
          score = scores[i]
          [w.to_s, score.is_a?(Numeric) ? score.to_i : RELATEDNESS_SCORE_THRESHOLD]
        end

        @related_precompute_by_lemma[lem] = tuples
        n += 1
      end
      puts "loaded #{n} precomputed related lemmas from #{path}" if n.positive?
      @related_precompute_by_lemma
    rescue JSON::ParserError => e
      warn "related: skip precompute load (#{path}): #{e.message}"
      @related_precompute_by_lemma = {}
    end

    def precompute_loaded?
      !related_precompute_by_lemma.empty?
    end

    # Filter a precompute row's [[word, score], ...] tuples by the caller's
    # visibility flags. Preserves +(word, score)+ pairing so callers that need
    # the stored score downstream can read it without a second lookup.
    def filter_precomputed_tuples(raw, include_rhymeless, common_only)
      return [] if raw.nil? || raw.empty?
      unless defined?(lexicon_word_entry) && defined?(rdict_lookup)
        return raw.dup
      end

      raw.select do |(w, _score)|
        entry = lexicon_word_entry(w)
        next false unless entry
        next false if common_only && entry[0].to_i <= RARE_FREQ_MAX
        if include_rhymeless
          true
        else
          entry[1].any? { |pron| !pron.rime.to_s.empty? && !rdict_lookup(pron.rime).empty? }
        end
      end
    end

    # Returns [[word, score], ...] for the row keyed by +lemma_a+ under the
    # active data source. DDB fetches the parallel words + scores lists;
    # precompute JSONL uses the pre-parsed cache. Empty list when the row
    # doesn't exist.
    def lookup_tuples_for_lemma(lemma_a)
      if defined?(Rhymecrime::DataSource) && Rhymecrime::DataSource.dynamodb?
        Rhymecrime::DynamoRuntime.fetch_related_tuples(lemma_a)
      else
        related_precompute_by_lemma[lemma_a] || []
      end
    end

    # Membership test for a lemma pair. Tries +related#lemma_a+ first, then
    # +related#lemma_b+ — only one side needs to be a cached cue (scores are
    # symmetric). The +lemma(w) == lemma_b+ check covers the common case
    # where the row stores a surface headword whose lemma is the other side
    # (e.g. row for +car+ contains +cars+; query is +cars+/+car+).
    def pair_in_precomputed?(lemma_a, lemma_b)
      return false if lemma_a.nil? || lemma_b.nil?

      tuples = lookup_tuples_for_lemma(lemma_a)
      return true if tuples.any? { |(w, _s)| w == lemma_b || lemma(w) == lemma_b }

      tuples = lookup_tuples_for_lemma(lemma_b)
      tuples.any? { |(w, _s)| w == lemma_a || lemma(w) == lemma_a }
    end

    # Stored +relatedness_score+ (0..100) for (word1, word2), or 0 when
    # neither endpoint has the other in its precompute row. Symmetric.
    def lookup_score(word1, word2)
      lookup_score_by_lemmas(lemma(word1), lemma(word2))
    end

    def lookup_score_by_lemmas(lemma_a, lemma_b)
      return 0 if lemma_a.nil? || lemma_b.nil?

      tuples = lookup_tuples_for_lemma(lemma_a)
      tuples.each { |(w, s)| return s.to_i if w == lemma_b || lemma(w) == lemma_b }

      tuples = lookup_tuples_for_lemma(lemma_b)
      tuples.each { |(w, s)| return s.to_i if w == lemma_a || lemma(w) == lemma_a }

      0
    end

    # +max_candidates+ default +SIMILAR_MAX+ caps the list by stored
    # +relatedness_score+ for UI / display. Pass +nil+ for no cap (e.g.
    # set_related / pair rhyming): truncation can drop words with lower
    # stored scores that are still legitimately related. Sort uses the
    # stored scores from the cue's precompute row — no per-candidate DDB
    # lookup.
    def find_thematically_related_words(word, include_self, include_rhymeless = true, common_only = false, max_candidates = SIMILAR_MAX)
      tuples = find_all_thematically_related_words_with_scores(word, include_rhymeless, common_only)
      if max_candidates && tuples.length > max_candidates
        tuples = tuples.sort_by { |(_w, s)| -s }.first(max_candidates)
      end
      words = tuples.map(&:first)
      words.push(word) if include_self
      words
    end

    def find_all_thematically_related_words(word, include_rhymeless = true, common_only = false)
      find_all_thematically_related_words_with_scores(word, include_rhymeless, common_only).map(&:first)
    end

    # Companion to +find_all_thematically_related_words+ that preserves the
    # stored +relatedness_score+ on every returned tuple. Used by
    # +find_thematically_related_words+ for score-aware sorting without N
    # extra +similarity+ lookups.
    def find_all_thematically_related_words_with_scores(word, include_rhymeless = true, common_only = false)
      @related_word_cache ||= {}
      key = [word, include_rhymeless, common_only]
      return @related_word_cache[key] if @related_word_cache.key?(key)

      # Stop words (+stop_word?+) are related to every other word; short-circuit
      # to +words_we_care_about+ rather than a per-pair scan / precompute
      # lookup, which is both wasteful and (for DDB / JSONL) not populated for
      # stop-word keys (see +bin/precompute-relatedness+, which skips them).
      # Stop-word pairs have no meaningful stored score — assign the
      # +RELATEDNESS_SCORE_THRESHOLD+ floor so sort order is stable.
      if stop_word?(word) || stop_word?(lemma(word))
        candidates = words_we_care_about(include_rhymeless, common_only).reject { |w| w == word }
        tuples = candidates.map { |w| [w, RELATEDNESS_SCORE_THRESHOLD] }
        debug "Finding words related to #{word} (stop word, all candidates)... #{tuples.length}\n"
        @related_word_cache[key] = tuples
        return tuples
      end

      if defined?(Rhymecrime::DataSource) && Rhymecrime::DataSource.dynamodb?
        lemma_key = lemma(word)
        tuples = Rhymecrime::DynamoRuntime.find_all_related_precomputed_with_scores(lemma_key, include_rhymeless, common_only)
        debug "Finding words related to #{word} (Dynamo, lemma=#{lemma_key})... #{tuples.length}\n"
        @related_word_cache[key] = tuples
        return tuples
      end

      if precompute_loaded?
        lemma_key = lemma(word)
        raw = related_precompute_by_lemma[lemma_key]
        if raw
          tuples = filter_precomputed_tuples(raw, include_rhymeless, common_only)
          debug "Finding words related to #{word} (precompute, lemma=#{lemma_key})... #{tuples.length}\n"
          @related_word_cache[key] = tuples
          return tuples
        end
        # Cue's lemma has no precompute row — fall through to the full scan
        # (local-dev). DDB mode was handled above and doesn't reach here.
      end

      # Local-dev fallback: no DDB, and either no precompute JSONL at all or
      # no row for this cue. Lazy-require the full compute pipeline and scan.
      relatedness_lazy_load_compute!
      tuples = find_all_thematically_related_words_by_scan(word, include_rhymeless, common_only)
      debug "Finding words related to #{word} (full scan)... #{tuples.length}\n"
      @related_word_cache[key] = tuples
      tuples
    end
  end
end
