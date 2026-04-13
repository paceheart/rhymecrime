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
                     :fetch_related_words, :batch_get_words, :batch_get_rimes,
                     :find_all_related_precomputed
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
      item = get_item("related##{lemma_key}")
      return [] unless item

      w = item["words"]
      return [] unless w

      w.is_a?(Array) ? w.map(&:to_s) : JSON.parse(w.to_s)
    rescue JSON::ParserError
      []
    end

    # +lemma_key+ is +lemma(word)+ for the query headword (see +related.rb+).
    def find_all_related_precomputed(lemma_key, include_rhymeless, common_only)
      raw = fetch_related_words(lemma_key)
      return [] if raw.empty?

      batch_get_words(raw)
      unless include_rhymeless
        rimes = raw.flat_map do |w|
          entry = @word_cache[w]
          entry ? entry[1].map(&:rime) : []
        end.uniq
        batch_get_rimes(rimes)
      end

      raw.select do |w|
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
