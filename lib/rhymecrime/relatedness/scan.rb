#!/usr/bin/env ruby
# coding: utf-8
#
# relatedness/scan.rb — full-scan fallback for +RelatedWords+.
#
# Scans every candidate in +words_we_care_about+ against a cue, scoring each pair
# through +relatedness_score+ (the score-combination stage) and keeping those at or above
# +RELATEDNESS_SCORE_THRESHOLD+. Emits +(word, score)+ tuples so callers can sort /
# cache / serialize the stored-pair score alongside the related-word list in one
# pass (+bin/compute-relatedness+).
#
# Requires +relatedness/signals+ and +relatedness/score+ first; not loaded at
# Lambda runtime. The runtime shim in +lib/rhymecrime/related.rb+ lazy-requires
# this file only in the local-dev fallback path (no DynamoDB, no compute
# JSONL — typically running specs from a repo that hasn't done compute yet).
#

require_relative "signals"
require_relative "score"
require_relative "curated_overrides"

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
    #
    # Curated overrides: pairs explicitly labeled in +curated/related.csv+
    # bypass the classifier entirely (see +relatedness/curated_overrides.rb+).
    # +related+ / +related_ish+ verdicts force the candidate into the result list
    # at +CURATED_OVERRIDE_SCORE_RELATED+ / +CURATED_OVERRIDE_SCORE_RELATED_ISH+;
    # +unrelated+ / +unrelated_ish+ verdicts force-exclude the candidate. This
    # rescues the ~11% of CSV labels the classifier currently disagrees with.
    # Override the override via +RHYMECRIME_RELATED_CSV_OVERRIDE=0+ for A/B work.
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
      overrides = curated_relatedness_overrides
      debug "Finding words related to #{cue}... "
      # Compute the ConceptNet single-source distance table from the cue so
      # every per-candidate +cn_hops+ call collapses to a hash lookup instead of
      # a bidirectional BFS. Cleared after the scan so unrelated callers fall
      # back to the generic BFS.
      prepare_cn_hops_source!(cue_lemma)
      begin
        words_we_care_about(include_rhymeless, common_only).each do |related|
          next if related == cue

          # Semantically promiscuous words (+semantically_promiscuous?+) are
          # related to every other word; mirror +thematically_related?+'s
          # short-circuit so the scan's output matches the predicate exactly.
          if semantically_promiscuous?(cue) || semantically_promiscuous?(related)
            results << [related, 100]
            next
          end

          related_lemma = lemma(related)

          # Curated override: short-circuit the classifier when the (cue_lemma,
          # related_lemma) pair has a non-contradictory verdict in
          # +curated/related.csv+.
          if (verdict = overrides[[cue_lemma, related_lemma]])
            case verdict
            when :related
              results << [related, CURATED_OVERRIDE_SCORE_RELATED]
            when :related_ish
              results << [related, CURATED_OVERRIDE_SCORE_RELATED_ISH]
            when :unrelated, :unrelated_ish
              # Force-exclude: skip both classifier eval and result emission.
              nil
            end
            next
          end

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
