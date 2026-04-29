# frozen_string_literal: true

require "singleton"
require "forwardable"
require "aws-sdk-dynamodb"
require "json"
require_relative "data_source"
require_relative "timing"

module Rhymecrime
  # Read-side adapter over the precomputed +related#<lemma>+ / +score#<lemma>+
  # / +set_related#<lemma>+ partitions in DynamoDB. The lexicon (+word#+)
  # and rime cohort (+rime#+) partitions were retired once the corresponding
  # +.msgpack+ files got small enough (~5.5 MB and ~700 KB respectively) to
  # ship in the Lambda deploy bundle — see +lib/rhymecrime/dict/utils_rhyme.rb+
  # (+WORD_DICT_MSGPACK_FILENAME+, +RIME_DICT_MSGPACK_FILENAME+) and
  # +bin/upload-to-dynamodb+ (which now writes +related#+, +score#+, and
  # +set_related#+).
  #
  # +DynamoRuntime+ is therefore a thin wrapper around three GetItems:
  # +related#<lemma>+ (cheap words list), +score#<lemma>+ (lazy scores
  # companion), and +set_related#<lemma>+ (precomputed post-prune
  # rhyming-tuple list, the runtime hot-path answer for the +set_related+
  # goal). Mirrors +Rhymecrime::LocalStore+'s API so +Rhymecrime::Store+
  # can switch on +DataSource.dynamodb?+ without the caller knowing which
  # backend is live.
  class DynamoRuntime
    include Singleton

    # FIFO upper bound for the in-process +set_related#+ cache. Sized to
    # cover the full cue universe (~28K headwords precomputed by
    # +bin/precompute-set-related+) so a long-lived warm Lambda container
    # eventually serves every cached cue from RAM.
    DDB_SET_RELATED_CACHE_CAP = (ENV["RHYMECRIME_DDB_SET_RELATED_CACHE_CAP"] || "30000").to_i

    class << self
      extend Forwardable
      def_delegators :instance, :fetch_related_words, :fetch_related_tuples,
                     :find_all_related_precomputed, :find_all_related_precomputed_with_scores,
                     :fetch_set_related_tuples, :has_set_related?
    end

    def initialize
      @client = nil
      @set_related_cache = {}
    end

    def client
      return @client if @client
      @client = Aws::DynamoDB::Client.new(
        region: ENV.fetch("AWS_REGION", "us-east-1")
      )
      announce_cache_source!
      @client
    end

    # Print the DynamoDB table identity once per process. Mirrors
    # +LocalStore#announce_cache_age!+ so any precompute-cache consumer
    # surfaces the data source it's about to trust — DDB doesn't expose a
    # cheap "last write" timestamp without a +describe_table+ round-trip, so
    # we just identify the table and region.
    #
    # No +RELATED_BYPASS_STORE=1+ hint here (unlike +LocalStore+'s analog):
    # in DDB mode +store_authoritative?+ is true, the live-compute pipeline
    # (+relatedness/signals+, +relatedness/score+) isn't even +require+'d, and
    # the corpora it depends on (Numberbatch, ConceptNet, etc.) aren't in the
    # Lambda bundle by design — see +bin/stage-lambda+. A Store miss is the
    # final answer; there is nothing to fall back to.
    def announce_cache_source!
      return if @announced
      @announced = true
      warn "[related-cache] using DynamoDB precomputed store table=#{table_name} " \
           "region=#{ENV.fetch('AWS_REGION', 'us-east-1')} (authoritative; no live-compute fallback)"
    end

    def table_name
      DataSource.table_name
    end

    # Cheap path: words only, no score GetItem. Used by everything that
    # doesn't need the +relatedness_score+ band — the non-debug rhyme page,
    # +pair_in_store?+ membership checks, +find_all_related_precomputed+'s
    # filter loop. Touches one item (+related#<lemma>+); a missing attribute
    # or a parse failure both yield +[]+, matching the legacy behavior.
    def fetch_related_words(lemma_key)
      item = get_item("related##{lemma_key}")
      parse_words_attr(item)
    end

    # Lazy companion to +fetch_related_words+: GetItems +score#<lemma>+ and
    # returns the parallel score array, or +[]+ when the row is missing
    # (legacy data, or this lemma simply had no precomputed scores). Only
    # called by +fetch_related_tuples+ — i.e. by +/similar+, +?debug=1+, and
    # +lookup_score_by_lemmas+ — so the production rhyme page never pays for
    # it.
    def fetch_scores_array(lemma_key)
      item = get_item("score##{lemma_key}")
      return [] unless item

      s = item["scores"]
      return s.map { |x| x.is_a?(Numeric) ? x.to_i : nil } if s.is_a?(Array)
      return [] unless s.is_a?(String) && !s.empty?

      parsed = JSON.parse(s)
      parsed.is_a?(Array) ? parsed : []
    rescue JSON::ParserError
      []
    end

    # Returns parallel [[word, score], ...] tuples by zipping the cheap
    # +related#<lemma>+ words list with the lazy +score#<lemma>+ scores list.
    # +score+ is the stored +relatedness_score+ (0..100 integer); defaults to
    # +RELATEDNESS_SCORE_THRESHOLD+ when the score row is missing or shorter
    # than the words list so UI sorting / coloring still yields sensible
    # values instead of painting every related word with a 0 score.
    def fetch_related_tuples(lemma_key)
      words = fetch_related_words(lemma_key)
      return [] if words.empty?

      scores = fetch_scores_array(lemma_key)
      threshold = relatedness_score_threshold
      words.each_with_index.map do |word, i|
        raw = scores[i]
        [word, raw.is_a?(Numeric) ? raw.to_i : threshold]
      end
    end

    # +lemma_key+ is +lemma(word)+ for the query headword (see +related.rb+).
    # Hot-path entry point: filters the cheap +related#<lemma>+ words list
    # without ever touching +score#<lemma>+. This is what the non-debug rhyme
    # page goes through.
    def find_all_related_precomputed(lemma_key, include_rhymeless, common_only)
      words = fetch_related_words(lemma_key)
      return [] if words.empty?

      filter_related_words(words, include_rhymeless, common_only)
    end

    # Companion to +find_all_related_precomputed+ that preserves the stored
    # +relatedness_score+ alongside each surviving word. Pays for the
    # +score#<lemma>+ GetItem; only callers that actually consume the score
    # (+/similar+, +?debug=1+, score-aware sorts) should reach this.
    def find_all_related_precomputed_with_scores(lemma_key, include_rhymeless, common_only)
      raw = fetch_related_tuples(lemma_key)
      return [] if raw.empty?

      words = raw.map(&:first)
      survivors = filter_related_words(words, include_rhymeless, common_only).to_set
      raw.select { |(w, _s)| survivors.include?(w) }
    end

    # Hot-path read for the +set_related+ goal: returns the precomputed
    # Array of tuples (each a sorted Array of headwords) for +lemma_key+,
    # or +nil+ when the +set_related#<lemma>+ row doesn't exist for this
    # cue. Mirrors +LocalStore#fetch_set_related_tuples+ in shape.
    #
    # +nil+ vs +[]+ matters: an empty array is a valid "this cue has no
    # rhyming friends" answer the caller renders normally, while +nil+
    # signals "we never precomputed this cue" and routes to the
    # friendly-message branch in +crime.rb+'s goal dispatch
    # (+explicitly_forbidden?+ → "I don't like that word."; otherwise →
    # "Oops, I don't know what words are related to <cue>...").
    #
    # In-process FIFO cache (+@set_related_cache+) covers warm-container
    # repeats; cap is +DDB_SET_RELATED_CACHE_CAP+. Negative results are
    # cached too so a typo'd cue doesn't re-GetItem on every refresh.
    def fetch_set_related_tuples(lemma_key)
      return @set_related_cache[lemma_key] if @set_related_cache.key?(lemma_key)

      item = get_item("set_related##{lemma_key}")
      put_set_related(lemma_key, parse_tuples_attr(item))
    end

    # Cheap existence check sibling of +fetch_set_related_tuples+. Used by
    # callers that just need a yes/no answer without paying the JSON parse
    # of the tuples attribute. Hits the same in-process cache the fetch
    # does, so the typical "has? then fetch?" pattern only round-trips once.
    def has_set_related?(lemma_key)
      !fetch_set_related_tuples(lemma_key).nil?
    end

    # Shared filter step. The lexicon (+lexicon_word_entry+) and rime cohort
    # (+rdict_lookup+) are now in-process from the bundled msgpacks, so the
    # filter is a pure CPU loop — no DDB round-trip. Mirrors
    # +LocalStore#filter_related_words+; the +defined?+ guard keeps this
    # module importable by tools that don't load +crime.rb+ (e.g.
    # +bin/upload-to-dynamodb+).
    def filter_related_words(words, include_rhymeless, common_only)
      return words.dup unless defined?(lexicon_word_entry) && defined?(rdict_lookup)

      words.select do |w|
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

    private

    # Shared decode for the +words+ attribute on +related#<lemma>+ items:
    # tolerate both List-typed (modern uploads) and legacy String-typed
    # (JSON-encoded) shapes, and treat any decode failure as +[]+ so a single
    # corrupt row doesn't 500 the request.
    def parse_words_attr(item)
      return [] unless item

      w = item["words"]
      return [] unless w
      return w.map(&:to_s) if w.is_a?(Array)

      parsed = JSON.parse(w.to_s)
      parsed.is_a?(Array) ? parsed.map(&:to_s) : []
    rescue JSON::ParserError
      []
    end

    # Decodes the +tuples+ attribute on +set_related#<lemma>+ items into an
    # Array of Arrays of words. Returns +nil+ when +item+ is itself nil
    # (missing row → distinct from "row exists but empty list" so the
    # runtime can route to the friendly-message branch). Tolerates List-of-
    # Lists (modern uploads) and JSON-encoded String shapes; a decode
    # failure on a present row degrades to an empty Array rather than +nil+
    # (the row exists, we just couldn't read it — render an empty result
    # rather than the "unknown cue" message that would mislead the user).
    def parse_tuples_attr(item)
      return nil unless item

      t = item["tuples"]
      return [] unless t

      arr =
        if t.is_a?(Array)
          t
        elsif t.is_a?(String) && !t.empty?
          JSON.parse(t)
        end

      return [] unless arr.is_a?(Array)

      arr.map { |tup| tup.is_a?(Array) ? tup.map(&:to_s) : [] }.reject(&:empty?)
    rescue JSON::ParserError
      []
    end

    # FIFO-bounded write to +@set_related_cache+. Returns the value so
    # callers can chain "miss → fetch → cache → return" in one expression.
    # Capacity matches +DDB_SET_RELATED_CACHE_CAP+; eviction is FIFO
    # (Ruby Hash insertion order) — same rationale as +put_word+ in the
    # legacy +word#+ cache: writes are once-per-cue and we don't pay for
    # access-order bookkeeping when the workload is "scan every cue once
    # over the container's lifetime."
    def put_set_related(lemma_key, value)
      @set_related_cache[lemma_key] = value
      @set_related_cache.shift while @set_related_cache.size > DDB_SET_RELATED_CACHE_CAP
      value
    end

    def get_item(pk)
      resp = client.get_item(table_name: table_name, key: { "pk" => pk })
      resp.item
    rescue Aws::DynamoDB::Errors::ServiceError => e
      warn "DynamoDB get_item #{pk}: #{e.message}"
      nil
    end

    # +RELATEDNESS_SCORE_THRESHOLD+ lives in +lib/rhymecrime/related.rb+ and
    # isn't loaded when +dynamo_store+ is required in isolation (e.g. by
    # +bin/upload-to-dynamodb+ tests). Look it up via +Object.const_get+ and
    # fall back to the hardcoded +50+ that matches the runtime constant —
    # keeps this file importable without dragging in the relatedness
    # constants module.
    def relatedness_score_threshold
      Object.const_get(:RELATEDNESS_SCORE_THRESHOLD)
    rescue NameError
      50
    end
  end
end
