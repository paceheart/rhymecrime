#!/usr/bin/env ruby
# coding: utf-8
#
# relatedness/scan.rb — full-scan fallback for +RelatedWords+.
#
# Scans every candidate in +words_we_care_about+ against a cue, scoring each pair
# through +relatedness_score+ (phase 2) and keeping those at or above
# +RELATEDNESS_SCORE_THRESHOLD+. Emits +(word, score)+ tuples so callers can sort /
# cache / serialize the stored-pair score alongside the related-word list in one
# pass (+bin/precompute-relatedness+).
#
# Requires +relatedness/signals+ and +relatedness/score+ first; not loaded at
# Lambda runtime. The runtime shim in +lib/rhymecrime/related.rb+ lazy-requires
# this file only in the local-dev fallback path (no DynamoDB, no precompute
# JSONL — typically running specs from a repo that hasn't done precompute yet).
#

require_relative "signals"
require_relative "score"

class RelatedWords
  class << self
    # Returns +[[word, score], ...]+ pairs for every +words_we_care_about+ entry
    # that scores at or above +RELATEDNESS_SCORE_THRESHOLD+ against +word+.
    # +score+ is the raw +relatedness_score+ (0..100 from the rule bundle; 100 for
    # stop-word candidates mirroring +thematically_related?+'s short-circuit).
    #
    # Order is +words_we_care_about+ insertion order (alphabetical); callers sort
    # as needed. The OOV-Numberbatch guard short-circuits to +[]+ for cues whose
    # lemma has no Numberbatch vector — such a cue cannot produce a non-trivial
    # +base_similarity+ and scanning all ~20k candidates would waste ~minutes.
    def find_all_thematically_related_words_by_scan(word, include_rhymeless = true, common_only = false)
      unless dictionary_lemma_has_numberbatch_vector?(word)
        if ENV["RHYMECRIME_WARN_OOV_NUMBERBATCH"] == "1"
          warn "related: skipping full scan for '#{word}' (lemma '#{lemma(word)}' not in Numberbatch export)"
        end
        debug "Finding words related to #{word}... 0 (no Numberbatch vector for lemma)\n"
        return []
      end

      results = []
      l1 = lemma(word)
      debug "Finding words related to #{word}... "
      # Precompute the ConceptNet single-source distance table from the cue so
      # every per-candidate +cn_hops+ call collapses to a hash lookup instead of
      # a bidirectional BFS. Cleared after the scan so unrelated callers fall
      # back to the generic BFS.
      prepare_cn_hops_source!(l1)
      begin
        words_we_care_about(include_rhymeless, common_only).each do |w|
          next if w == word

          # Stop words (+stop_word?+) are related to every other word; mirror
          # +thematically_related?+'s short-circuit so the scan's output matches
          # the predicate exactly.
          if stop_word?(word) || stop_word?(w)
            results << [w, 100]
            next
          end

          l2 = lemma(w)
          a, b = l1 <= l2 ? [l1, l2] : [l2, l1]
          score = relatedness_score(PairSignals.new(a, b))
          next if score < RELATEDNESS_SCORE_THRESHOLD

          results << [w, score]
        end
      ensure
        clear_cn_hops_source!
      end
      debug "#{results.length}\n"
      results
    end
  end
end
