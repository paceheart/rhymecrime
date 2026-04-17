# frozen_string_literal: true

require "singleton"
require "forwardable"
require "aws-sdk-dynamodb"
require "json"
require_relative "data_source"
require_relative "dict/utils_rhyme"
require_relative "dict/phoneme.rb"
require_relative "dict/pronunciation.rb"

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

    def clear_session_cache!
      @word_cache = {}
      @rime_cache = {}
    end

    def initialize
      clear_session_cache!
      @client = nil
    end

    def client
      @client ||= Aws::DynamoDB::Client.new(
        region: ENV.fetch("AWS_REGION", "us-east-1")
      )
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
      @word_cache[word] = parse_word_item(word, item)
    end

    def batch_get_words(words)
      keys = words.uniq.reject { |w| @word_cache.key?(w) }
      return if keys.empty?

      keys.each_slice(100) do |slice|
        resp = client.batch_get_item(
          request_items: {
            table_name => {
              keys: slice.map { |w| { "pk" => "word##{w}" } }
            }
          }
        )
        (resp.responses[table_name] || []).each do |item|
          w = item["pk"].to_s.sub(/\Aword#/, "")
          @word_cache[w] = parse_word_item(w, item)
        end
        slice.each { |w| @word_cache[w] = nil unless @word_cache.key?(w) }
      end
    end

    def fetch_rime(rime)
      return @rime_cache[rime] if @rime_cache.key?(rime)

      item = get_item("rime##{rime}")
      @rime_cache[rime] = parse_rime_item(item)
    end

    def batch_get_rimes(rimes)
      keys = rimes.uniq.reject { |r| @rime_cache.key?(r) }
      return if keys.empty?

      keys.each_slice(100) do |slice|
        resp = client.batch_get_item(
          request_items: {
            table_name => {
              keys: slice.map { |r| { "pk" => "rime##{r}" } }
            }
          }
        )
        (resp.responses[table_name] || []).each do |item|
          r = item["pk"].to_s.sub(/\Arime#/, "")
          @rime_cache[r] = parse_rime_item(item)
        end
        slice.each { |r| @rime_cache[r] = [] unless @rime_cache.key?(r) }
      end
    end

    def fetch_related_words(lemma_key)
      fetch_related_tuples(lemma_key).map(&:first)
    end

    # Returns parallel [[word, score], ...] tuples for the +related#<lemma>+
    # row. +score+ is the stored +relatedness_score+ (0..100 integer) from
    # precompute; defaults to +RELATEDNESS_SCORE_THRESHOLD+ when the row
    # predates the scores-schema (old precompute upload without a +scores+
    # attr) so UI sorting / coloring still yields sensible values instead of
    # painting every related word with a 0 score.
    def fetch_related_tuples(lemma_key)
      item = get_item("related##{lemma_key}")
      return [] unless item

      w = item["words"]
      return [] unless w

      words = w.is_a?(Array) ? w.map(&:to_s) : JSON.parse(w.to_s)
      return [] if words.empty?

      s = item["scores"]
      scores = if s.is_a?(Array)
                 s
               elsif s.is_a?(String) && !s.empty?
                 JSON.parse(s)
               else
                 []
               end

      words.each_with_index.map do |word, i|
        raw = scores[i]
        score = raw.is_a?(Numeric) ? raw.to_i : Object.const_get(:RELATEDNESS_SCORE_THRESHOLD)
        [word, score]
      end
    rescue JSON::ParserError
      []
    rescue NameError
      # RELATEDNESS_SCORE_THRESHOLD hasn't been loaded yet (dynamo_store is
      # being required in isolation). Fall back to a hardcoded 50 — matches
      # the runtime constant in lib/rhymecrime/related.rb.
      words.each_with_index.map { |word, _i| [word, 50] }
    end

    # +lemma_key+ is +lemma(word)+ for the query headword (see +related.rb+).
    def find_all_related_precomputed(lemma_key, include_rhymeless, common_only)
      find_all_related_precomputed_with_scores(lemma_key, include_rhymeless, common_only).map(&:first)
    end

    # Companion to +find_all_related_precomputed+ that preserves the stored
    # +relatedness_score+ alongside each surviving word. UI paths that need to
    # sort / color / serialize by score read this directly instead of paying
    # for N separate +similarity+ lookups.
    def find_all_related_precomputed_with_scores(lemma_key, include_rhymeless, common_only)
      raw = fetch_related_tuples(lemma_key)
      return [] if raw.empty?

      words = raw.map(&:first)
      batch_get_words(words)
      unless include_rhymeless
        rimes = words.flat_map do |w|
          entry = @word_cache[w]
          entry ? entry[1].map(&:rime) : []
        end.uniq
        batch_get_rimes(rimes)
      end

      raw.select do |(w, _score)|
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
  end
end
