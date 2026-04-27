#!/usr/bin/env ruby
# coding: utf-8
#
# related.rb — runtime relatedness lookup. Load: require "rhymecrime/related"
#
# Answers every relatedness question — "is this pair topically related?",
# "what's the similarity score?", "which headwords are related to this cue?"
# — from the precomputed +related#<lemma>+ rows exposed by
# +Rhymecrime::Store+. The facade picks:
#
#   * +Rhymecrime::DynamoRuntime+ in Lambda (+RHYMECRIME_DATA_SOURCE=dynamodb+),
#   * +Rhymecrime::LocalStore+ (SQLite) everywhere else.
#
# Neither path pulls in Numberbatch, ConceptNet, WordNet, USF, MPNet, or the
# learned classifier — those live in +lib/rhymecrime/relatedness/*+ and are
# only required at seed time (+bin/precompute-relatedness+,
# +bin/train-relatedness-classifier+, related specs) or by the local-dev
# fallback below.
#
# Local-dev fallback: when the LocalStore is absent (fresh clone, pre-precompute)
# or missing a row for a queried cue, +similarity+ returns 0 and the thematic
# predicates lazy-require the full compute pipeline (+relatedness/signals+ +
# +score+ + +scan+). Lambda never reaches this fallback because +Store.available?+
# is always true for DynamoDB.
#
# Accepted trade-off: when neither (A, B) is a cached cue, +similarity(A, B)+
# returns 0 and +thematically_related?(A, B)+ is false at runtime — typical
# for pairs where both sides are rare headwords (no row in precompute).
#

require_relative "pace_utils"
require_relative "dict/utils_rhyme"
require_relative "store"

SIMILAR_MAX = 50000 # O_o

# Composite-score threshold for "topically related" (see +relatedness_score+ in
# +relatedness/score.rb+). Also the floor of every entry in a precomputed
# related-words list — anything below 50 is by definition unrelated.
RELATEDNESS_SCORE_THRESHOLD = 50

def related_trace_memo?
  ENV["RELATED_TRACE_MEMO"].to_s == "1"
end

# Diagnostic knob for +spec/related_weighted_accuracy.rb+ and ad-hoc eval work:
# when set, +thematically_related?+ / +why_thematically_related?+ skip the
# precomputed Store lookup and always run the compute pipeline. Lets
# post-retrain evals measure the *current* classifier + rules against
# +curated/related.csv+ without waiting for a full +bin/precompute-relatedness+
# rebuild. Never consulted at Lambda runtime (production never sets the var).
def related_bypass_store?
  ENV["RELATED_BYPASS_STORE"].to_s == "1"
end

# Lazy-require the full relatedness compute pipeline. Only invoked when the
# Store has no answer (local-dev / spec fallback). Once loaded, heavy
# knowledge bases (Numberbatch, ConceptNet, WordNet, etc.) stay in memory for
# the life of the process.
$relatedness_compute_loaded = false
def relatedness_lazy_load_compute!
  return if $relatedness_compute_loaded
  require_relative "relatedness/signals"
  require_relative "relatedness/score"
  require_relative "relatedness/scan"
  $relatedness_compute_loaded = true
end

# True when the runtime should treat the Store as authoritative (hard +false+
# on a pair miss, no compute fallback). Only DDB is authoritative — the
# LocalStore is a dev cache that may not cover every pair (e.g. eval scripts
# passing rare cues through +thematically_related?+), so a miss there falls
# through to the compute pipeline just like on a fresh clone.
def store_authoritative?
  Rhymecrime::DataSource.dynamodb?
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

# --- Thematic relatedness predicate ---

# True iff +cue+ is topically related to +related+. Directional in
# +(cue, related)+ — see +thematically_related_pair_memoized?+ in
# +relatedness/score.rb+. Stop words are treated as related to every other
# word (contentless glue). At runtime the predicate is answered via
# +RelatedWords.pair_in_store?+; the local-dev fallback lazy-loads the compute
# pipeline when the Store is absent.
#
# Note: the precomputed Store was built under a symmetric predicate, so
# +pair_in_store?+ effectively returns the OR of both orientations. Until the
# Store is rebuilt directionally that's a slight permissiveness gap vs. the
# compute path, hidden behind +RELATED_BYPASS_STORE=1+ for eval work.
def thematically_related?(cue, related, include_self = false)
  if ENV["RELATED_TRACE_THEMATIC"] == "1"
    warn "thematically_related? cue=#{cue.inspect} related=#{related.inspect} include_self=#{include_self.inspect}"
  end

  return true if include_self && (cue == related || lemma(cue) == lemma(related))
  return true if stop_word?(cue) || stop_word?(related)

  puts "thematically_related? #{cue} -> #{related}" if related_trace_memo?

  # Two normalization modes on the way in:
  #   * +RELATED_SKIP_LEMMA=1+ -> raw surfaces (no normalization).
  #   * default                -> inflectional +lemma(w)+.
  # Signals (Numberbatch, MPNet, ConceptNet, USF) are looked up under the
  # resolved key, so training and inference have to agree on which layer is
  # active. The +SKIP_LEMMA+ A/B in +bin/_lemma_ablation+ proved that mismatched
  # layers tank TPR. (R3 derivational collapse via +semantic_base+ was
  # explored — see +word_semantic_base_map.{msgpack,txt}+ — and net-regressed
  # weighted accuracy under the cosine guard sweep, so the runtime stayed on
  # plain +lemma+.)
  cue_lemma = ENV["RELATED_SKIP_LEMMA"] == "1" ? cue : lemma(cue)
  related_lemma = ENV["RELATED_SKIP_LEMMA"] == "1" ? related : lemma(related)
  puts "  -> lemma key #{cue_lemma} -> #{related_lemma}" if related_trace_memo?

  unless related_bypass_store?
    # Store is symmetric internally (queries both endpoints' rows). Pass the
    # cue/related lemmas as-is; the OR-of-orientations semantics is intentional
    # while the Store predates the directional refactor.
    return true if RelatedWords.pair_in_store?(cue_lemma, related_lemma)

    # DDB is authoritative: "missing means unrelated," no compute fallback in
    # Lambda. The LocalStore is a dev cache — it may not cover every pair (eval
    # scripts routinely probe rare cues + rhymeless lemmas), so a miss there
    # falls through to the compute pipeline.
    return false if store_authoritative?
  end

  relatedness_lazy_load_compute!
  thematically_related_pair_memoized?(cue_lemma, related_lemma)
end

# Same decision as +thematically_related?+, but returns a short reason string
# when true, or +nil+ when false. Directional in +(cue, related)+.
def why_thematically_related?(cue, related, include_self = false)
  return "self: same headword" if include_self && cue == related
  return "self: same lexeme (lemma)" if include_self && lemma(cue) == lemma(related)
  return "stop_word: #{cue.inspect} is a stop word (related to everything)" if stop_word?(cue)
  return "stop_word: #{related.inspect} is a stop word (related to everything)" if stop_word?(related)

  cue_lemma = ENV["RELATED_SKIP_LEMMA"] == "1" ? cue : lemma(cue)
  related_lemma = ENV["RELATED_SKIP_LEMMA"] == "1" ? related : lemma(related)

  unless related_bypass_store?
    score = RelatedWords.lookup_score_by_lemmas(cue_lemma, related_lemma)
    return "precomputed: topically related (score=#{score})" if score >= RELATEDNESS_SCORE_THRESHOLD

    return nil if store_authoritative?
  end

  relatedness_lazy_load_compute!
  why_thematically_related_full?(cue, related, include_self)
end

# --- RelatedWords: cue -> related headwords (+ stored scores) ---

# Enumerates RhymeCrime headwords and returns those topically related to a cue.
# Delegates to +Rhymecrime::Store+ (DDB in prod, SQLite locally); falls back to
# a lazy-loaded full scan only when the Store has no row for the cue and isn't
# authoritative (local-dev with incomplete precompute).
class RelatedWords
  class << self
    # Clears every in-process cache derived from +Rhymecrime::Store+ data.
    # Call sites: every request entry point (Sinatra, Lambda, CLI) plus the
    # +bin/precompute-relatedness+ shard loop that invalidates between cues
    # to keep worker RSS bounded. Keep this list in sync with the caches
    # below so freshly-added memoization doesn't accidentally survive across
    # invalidations.
    def reset_caches!
      @related_word_cache = {}
      @lemma_score_map_cache = {}
      $rhyming_tuple_word_bases_cache = {} if defined?($rhyming_tuple_word_bases_cache)
    end

    # Lemma-indexed score hash for a cue's precompute row. Built lazily and
    # cached so that repeated +lookup_score_by_lemmas+ calls against the same
    # focal cue (the common pattern — every colored word in a +set_related+
    # tuple is compared against the same input word) collapse from O(N) tuple
    # scans to O(1) hash lookups. Returns +nil+ when the cue has no row.
    #
    # We only build this for the *second* arg to +lookup_score_by_lemmas+
    # (the focal side), not the first: the first side is typically a distinct
    # surface word per call with an empty row, so building a map for it would
    # just thrash allocations and GC.
    def lemma_score_map_for(lemma_key)
      return nil if lemma_key.nil?

      @lemma_score_map_cache ||= {}
      return @lemma_score_map_cache[lemma_key] if @lemma_score_map_cache.key?(lemma_key)

      tuples = Rhymecrime::Store.fetch_related_tuples(lemma_key)
      return @lemma_score_map_cache[lemma_key] = nil if tuples.empty?

      map = {}
      tuples.each do |(w, s)|
        score = s.to_i
        map[w] = score unless map.key?(w) && map[w] >= score
        l = lemma(w)
        if l && l != w
          map[l] = score unless map.key?(l) && map[l] >= score
        end
      end
      @lemma_score_map_cache[lemma_key] = map
    end

    # Membership test for a lemma pair. Tries the +related#lemma_a+ row first
    # via a linear scan (cheap — usually an empty row), then consults the
    # focal-side score map for +lemma_b+ (O(1)).
    def pair_in_store?(lemma_a, lemma_b)
      return false if lemma_a.nil? || lemma_b.nil?

      tuples = Rhymecrime::Store.fetch_related_tuples(lemma_a)
      return true if tuples.any? { |(w, _s)| w == lemma_b || lemma(w) == lemma_b }

      map = lemma_score_map_for(lemma_b)
      !map.nil? && map.key?(lemma_a)
    end

    # Stored +relatedness_score+ (0..100) for (word1, word2), or 0 when
    # neither endpoint has the other in its precompute row. Symmetric.
    def lookup_score(word1, word2)
      lookup_score_by_lemmas(lemma(word1), lemma(word2))
    end

    def lookup_score_by_lemmas(lemma_a, lemma_b)
      return 0 if lemma_a.nil? || lemma_b.nil?

      # First side: usually an empty row for the tuple's candidate word;
      # skip straight to the focal-side map on miss.
      tuples = Rhymecrime::Store.fetch_related_tuples(lemma_a)
      tuples.each { |(w, s)| return s.to_i if w == lemma_b || lemma(w) == lemma_b }

      map = lemma_score_map_for(lemma_b)
      return 0 if map.nil?
      s = map[lemma_a]
      s ? s : 0
    end

    # +max_candidates+ default +SIMILAR_MAX+ caps the list by stored
    # +relatedness_score+ for UI / display. Pass +nil+ for no cap (e.g.
    # set_related / pair rhyming): truncation can drop words with lower
    # stored scores that are still legitimately related. Sort uses the
    # stored scores from the cue's precompute row — no per-candidate
    # backend lookup.
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
      # to +words_we_care_about+ rather than a per-pair scan / Store lookup,
      # which is both wasteful and (by convention) not populated for stop-word
      # keys (see +bin/precompute-relatedness+, which skips them). Stop-word
      # pairs have no meaningful stored score — assign the
      # +RELATEDNESS_SCORE_THRESHOLD+ floor so sort order is stable.
      if stop_word?(word) || stop_word?(lemma(word))
        candidates = words_we_care_about(include_rhymeless, common_only).reject { |w| w == word }
        tuples = candidates.map { |w| [w, RELATEDNESS_SCORE_THRESHOLD] }
        debug "Finding words related to #{word} (stop word, all candidates)... #{tuples.length}\n"
        @related_word_cache[key] = tuples
        return tuples
      end

      lemma_key = lemma(word)

      # DDB is authoritative — empty row means "no related words," full stop.
      if store_authoritative?
        tuples = Rhymecrime::Store.find_all_related_precomputed_with_scores(lemma_key, include_rhymeless, common_only)
        debug "Finding words related to #{word} (store[authoritative], lemma=#{lemma_key})... #{tuples.length}\n"
        @related_word_cache[key] = tuples
        return tuples
      end

      # Dev-mode LocalStore is a cache: hit it when the cue has a row, fall
      # through to the full-scan compute pipeline when it doesn't (pre-SQLite
      # precompute-set cue miss — e.g. eval scripts or the user typing a
      # rare headword that wasn't in +rep.keys+ at precompute time). We use
      # +has_related?+ to distinguish "row exists but filtered to empty"
      # (legit "no related words" answer) from "row never built for this cue"
      # (fall through).
      if Rhymecrime::Store.available? && Rhymecrime::Store.has_related?(lemma_key)
        tuples = Rhymecrime::Store.find_all_related_precomputed_with_scores(lemma_key, include_rhymeless, common_only)
        debug "Finding words related to #{word} (store[cache], lemma=#{lemma_key})... #{tuples.length}\n"
        @related_word_cache[key] = tuples
        return tuples
      end

      # Local-dev fallback: no Store on disk, or no row for this cue. Lazy-
      # require the full compute pipeline and scan.
      relatedness_lazy_load_compute!
      tuples = find_all_thematically_related_words_by_scan(word, include_rhymeless, common_only)
      debug "Finding words related to #{word} (full scan)... #{tuples.length}\n"
      @related_word_cache[key] = tuples
      tuples
    end
  end
end
