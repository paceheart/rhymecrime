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
    # Returns +[[related, score], ...]+ pairs for every +words_we_care_about+ entry
    # that scores at or above +RELATEDNESS_SCORE_THRESHOLD+ against +cue+.
    # +score+ is the raw +relatedness_score+ (0..100 from the rule bundle; 100 for
    # stop-word candidates mirroring +thematically_related?+'s short-circuit).
    #
    # Directional: each pair is fed to +PairSignals+ as +(cue_lemma, related_lemma)+
    # without lex-order canonicalization, so any directional signal downstream sees
    # them as +PairSignals#cue+ and +PairSignals#related+. Order is
    # +words_we_care_about+ insertion order (alphabetical); callers sort as needed.
    # The OOV-Numberbatch guard short-circuits to +[]+ for cues whose lemma has no
    # Numberbatch vector — such a cue cannot produce a non-trivial
    # +base_similarity+ and scanning all ~20k candidates would waste ~minutes.
    def find_all_thematically_related_words_by_scan(cue, include_rhymeless = true, common_only = false)
      unless dictionary_lemma_has_numberbatch_vector?(cue)
        if ENV["RHYMECRIME_WARN_OOV_NUMBERBATCH"] == "1"
          warn "related: skipping full scan for '#{cue}' (lemma '#{lemma(cue)}' not in Numberbatch export)"
        end
        debug "Finding words related to #{cue}... 0 (no Numberbatch vector for lemma)\n"
        return []
      end

      results = []
      cue_lemma = lemma(cue)
      debug "Finding words related to #{cue}... "
      # Precompute the ConceptNet single-source distance table from the cue so
      # every per-candidate +cn_hops+ call collapses to a hash lookup instead of
      # a bidirectional BFS. Cleared after the scan so unrelated callers fall
      # back to the generic BFS.
      prepare_cn_hops_source!(cue_lemma)
      begin
        words_we_care_about(include_rhymeless, common_only).each do |related|
          next if related == cue

          # Stop words (+stop_word?+) are related to every other word; mirror
          # +thematically_related?+'s short-circuit so the scan's output matches
          # the predicate exactly.
          if stop_word?(cue) || stop_word?(related)
            results << [related, 100]
            next
          end

          related_lemma = lemma(related)
          score = relatedness_score(PairSignals.new(cue_lemma, related_lemma))
          next if score < RELATEDNESS_SCORE_THRESHOLD

          results << [related, score]
        end
      ensure
        clear_cn_hops_source!
      end
      debug "#{results.length}\n"
      results
    end
  end
end
