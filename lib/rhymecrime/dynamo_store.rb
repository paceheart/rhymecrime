# frozen_string_literal: true

require "singleton"
require "forwardable"
require "thread"
require "aws-sdk-dynamodb"
require "json"
require_relative "data_source"
require_relative "dict/utils_rhyme"
require_relative "dict/phoneme.rb"
require_relative "dict/pronunciation.rb"
require_relative "timing"

module Rhymecrime
  class DynamoRuntime
    include Singleton

    class << self
      extend Forwardable
      def_delegators :instance, :clear_session_cache!, :headword?, :fetch_word, :fetch_rime,
                     :fetch_related_words, :fetch_related_tuples,
                     :batch_get_words, :batch_get_rimes,
                     :find_all_related_precomputed, :find_all_related_precomputed_with_scores
    end

    # FIFO upper bound for the in-process +word#+ / +rime#+ caches. The full
    # dictionary fits well under both ceilings (~150K words, <10K rimes) so in
    # the common case these caps never trigger — they're insurance against a
    # long-lived Lambda container that has cumulatively touched every cue and
    # would otherwise hold the entire dataset in RAM.
    #
    # Eviction policy is FIFO (drop oldest insertion) rather than LRU because
    # +batch_get_words+ writes once per row and never re-reads on the hot
    # path — adding LRU bookkeeping would slow every cache write to defend
    # against a workload (cyclic re-eviction of recently-fetched keys) that
    # doesn't happen here.
    DDB_WORD_CACHE_CAP = (ENV["RHYMECRIME_DDB_WORD_CACHE_CAP"] || "250000").to_i
    DDB_RIME_CACHE_CAP = (ENV["RHYMECRIME_DDB_RIME_CACHE_CAP"] || "25000").to_i

    # Wipe the in-process caches. Called by +bin/precompute-relatedness+
    # between shards to bound worker RSS; intentionally NOT called per
    # request from the web entry points (+frontend.rb+) — +word#+ / +rime#+
    # rows are immutable per data deploy, so warm Lambda containers benefit
    # from keeping them across invocations.
    def clear_session_cache!
      @word_cache = {}
      @rime_cache = {}
    end

    def initialize
      clear_session_cache!
      @client = nil
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

    def headword?(word)
      fetch_word(word)
      !@word_cache[word].nil?
    end

    def fetch_word(word)
      return @word_cache[word] if @word_cache.key?(word)

      item = get_item("word##{word}")
      put_word(word, parse_word_item(word, item))
    end

    def batch_get_words(words)
      keys = words.uniq.reject { |w| @word_cache.key?(w) }
      return if keys.empty?

      slices = keys.each_slice(100).to_a
      Rhymecrime::Timing.measure("batch_get_words keys=#{keys.size} slices=#{slices.size} parallelism=#{effective_parallelism(slices.size)}") do
        responses = parallel_batch_get_items(slices, "word#")
        slices.zip(responses).each do |slice, resp|
          (resp.responses[table_name] || []).each do |item|
            w = item["pk"].to_s.sub(/\Aword#/, "")
            put_word(w, parse_word_item(w, item))
          end
          slice.each { |w| put_word(w, nil) unless @word_cache.key?(w) }
        end
      end
    end

    def fetch_rime(rime)
      return @rime_cache[rime] if @rime_cache.key?(rime)

      item = get_item("rime##{rime}")
      put_rime(rime, parse_rime_item(item))
    end

    def batch_get_rimes(rimes)
      keys = rimes.uniq.reject { |r| @rime_cache.key?(r) }
      return if keys.empty?

      slices = keys.each_slice(100).to_a
      Rhymecrime::Timing.measure("batch_get_rimes keys=#{keys.size} slices=#{slices.size} parallelism=#{effective_parallelism(slices.size)}") do
        responses = parallel_batch_get_items(slices, "rime#")
        slices.zip(responses).each do |slice, resp|
          (resp.responses[table_name] || []).each do |item|
            r = item["pk"].to_s.sub(/\Arime#/, "")
            put_rime(r, parse_rime_item(item))
          end
          slice.each { |r| put_rime(r, []) unless @rime_cache.key?(r) }
        end
      end
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

    # Shared filter step for the two find_all_* entry points. Prefetches
    # +word#+ rows (and rimes when +include_rhymeless+ is false) in batches,
    # then drops candidates that fail the visibility flags. Returns the
    # surviving words in the same order as +words+ so callers that zip
    # against +scores+ can preserve alignment via a Set membership test.
    def filter_related_words(words, include_rhymeless, common_only)
      batch_get_words(words)
      unless include_rhymeless
        rimes = words.flat_map do |w|
          entry = @word_cache[w]
          entry ? entry[1].map(&:rime) : []
        end.uniq
        batch_get_rimes(rimes)
      end

      words.select do |w|
        entry = @word_cache[w]
        next false unless entry
        next false if common_only && entry[0] <= RARE_FREQ_MAX

        if include_rhymeless
          true
        else
          entry[1].any? { |pron| !(@rime_cache[pron.rime] || []).empty? }
        end
      end
    end

    private

    # FIFO-bounded write to +@word_cache+. Returns the value so the put can be
    # the tail expression of a +fetch_word+-style "miss → fetch → cache → return"
    # chain. Re-assignment to an already-present key preserves its insertion
    # position (Ruby Hash semantics), so we only evict when we're growing past
    # the cap. See +DDB_WORD_CACHE_CAP+ doc comment for the bounding rationale.
    def put_word(word, value)
      @word_cache[word] = value
      @word_cache.shift while @word_cache.size > DDB_WORD_CACHE_CAP
      value
    end

    def put_rime(rime, value)
      @rime_cache[rime] = value
      @rime_cache.shift while @rime_cache.size > DDB_RIME_CACHE_CAP
      value
    end

    # Bounded-parallelism cap on concurrent +BatchGetItem+ calls. Override via
    # +RHYMECRIME_DDB_PARALLELISM+ if a future workload (different cue, different
    # data shape) tips into either DDB-side throttling (lower it) or
    # HTTP-client-side connection-pool starvation (raise it; the AWS SDK's
    # default Net::HTTP pool is +max_connections: 50+ — we're well under that).
    #
    # 8 was picked empirically as the smallest pool that lets the worst-case
    # set_related cue (+cat+: ~150 sequential +BatchGetItem+ calls for word +
    # rime + rhyme-cohort prefetches) come in under the 29-second API Gateway
    # ceiling. Each batch is a single-region, single-partition call so DDB's
    # on-demand instant-burst budget covers a fan-out this small without
    # ProvisionedThroughputExceeded.
    DDB_BATCH_PARALLELISM = (ENV["RHYMECRIME_DDB_PARALLELISM"] || "8").to_i

    def effective_parallelism(slice_count)
      return 1 if slice_count <= 1
      [DDB_BATCH_PARALLELISM, slice_count].min
    end

    # Fan +slices+ across a bounded pool of worker threads, each issuing one
    # +client.batch_get_item+ per slice. Returns the responses in the same
    # order as +slices+ so the caller can zip them back to the input keys.
    #
    # +pk_prefix+ ("word#" or "rime#") is concatenated with each key inside
    # the worker so the per-slice payload is built lazily — keeps the queue
    # entries small and avoids materializing all request payloads up front.
    #
    # Thread safety: +Aws::DynamoDB::Client+ is documented thread-safe (the
    # SDK guide explicitly calls this out for +Client+ classes); we only mutate
    # the shared +responses+ array via distinct indices (no overlapping writes)
    # and never touch +@word_cache+ / +@rime_cache+ from a worker — those are
    # written from the main thread after +Thread#join+ returns.
    #
    # Falls back to a synchronous loop on a single slice — spawning a thread
    # to do one BatchGetItem is pure overhead.
    def parallel_batch_get_items(slices, pk_prefix)
      return [] if slices.empty?

      if slices.size == 1
        return [batch_get_items_call(slices.first, pk_prefix)]
      end

      responses = Array.new(slices.size)
      queue = Queue.new
      slices.each_with_index { |slice, i| queue << [i, slice] }

      pool_size = effective_parallelism(slices.size)
      workers = Array.new(pool_size) do
        Thread.new do
          loop do
            begin
              idx, slice = queue.pop(true)
            rescue ThreadError
              break
            end
            responses[idx] = batch_get_items_call(slice, pk_prefix)
          end
        end
      end
      workers.each(&:join)
      responses
    end

    def batch_get_items_call(slice, pk_prefix)
      client.batch_get_item(
        request_items: {
          table_name => {
            keys: slice.map { |k| { "pk" => "#{pk_prefix}#{k}" } }
          }
        }
      )
    end

    def get_item(pk)
      resp = client.get_item(table_name: table_name, key: { "pk" => pk })
      resp.item
    rescue Aws::DynamoDB::Errors::ServiceError => e
      warn "DynamoDB get_item #{pk}: #{e.message}"
      nil
    end

    def parse_word_item(word, item)
      return nil unless item

      freq = (item["freq"] || item["frequency"] || 0).to_i
      prons_str = item["prons"].to_s
      prons = []
      prons_str.split("|").each do |pronstr|
        phonemes = pronstr.split
        next if phonemes.empty?

        pron = Pronunciation.new(phonemes)
        push_pronunciation_unless_duplicate!(prons, pron)
      end
      lem = item["lemma"].to_s
      lem = word if lem.empty?
      [freq, prons, lem]
    end

    def parse_rime_item(item)
      return [] unless item

      w = item["words"]
      return [] unless w

      w.is_a?(Array) ? w.map(&:to_s) : JSON.parse(w.to_s)
    rescue JSON::ParserError
      []
    end

    # Shared decode for the +words+ attribute on +related#<lemma>+ and
    # +rime#<key>+ items: tolerate both List-typed (modern uploads) and
    # legacy String-typed (JSON-encoded) shapes, and treat any decode
    # failure as +[]+ so a single corrupt row doesn't 500 the request.
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
