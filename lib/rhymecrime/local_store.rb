# frozen_string_literal: true

# local_store.rb — SQLite-backed local mirror of the Lambda DynamoDB schema.
#
# Only the +related#<lemma>+ partition is mirrored today; words / rimes still
# load from the in-process Ruby dict in dev. The schema matches the DDB item
# shape (+words+ and +scores+ as parallel JSON arrays) so +bin/precompute-
# relatedness+ can populate this file and +bin/upload-to-dynamodb+ can stream
# straight from it up to prod.
#
# Not loaded in Lambda runtime: +Rhymecrime::Store+ picks +DynamoRuntime+
# when +RHYMECRIME_DATA_SOURCE=dynamodb+ and only requires this file otherwise.
# The sqlite3 gem is a dev/test dep — see +Gemfile+.

require "forwardable"
require "json"
require "singleton"
require "sqlite3"
require_relative "data_source"
require_relative "dict/utils_rhyme"

module Rhymecrime
  class LocalStore
    include Singleton

    class << self
      extend Forwardable
      def_delegators :instance, :fetch_related_tuples, :fetch_related_words,
                     :find_all_related_precomputed, :find_all_related_precomputed_with_scores,
                     :has_related?, :available?, :clear_session_cache!

      def database_path
        generated_dict_path(LOCAL_STORE_FILENAME)
      end

      # Opens (or creates) a local store SQLite file for writing and yields a
      # +Writer+. Used by +bin/precompute-relatedness+ (workers for per-shard
      # files, parent for the final merged file) and +bin/upload-to-dynamodb+.
      # Always wraps the body in a single transaction — SQLite's per-commit
      # fsync dominates write throughput otherwise.
      def open_for_write(path = database_path)
        FileUtils.mkdir_p(File.dirname(path))
        db = SQLite3::Database.new(path)
        configure_for_bulk_write!(db)
        db.execute(Writer::SCHEMA_SQL)
        writer = Writer.new(db)
        db.transaction
        begin
          yield writer
          db.commit
        rescue StandardError
          db.rollback
          raise
        ensure
          db.close
        end
      end

      # Bulk-write PRAGMAs. WAL lets parallel readers (specs, a running web
      # server) stay up while precompute is writing; +synchronous=NORMAL+ is
      # enough durability for a derivable local cache (we never keep the sole
      # copy of anything here — JSONL-style source-of-truth is the classifier
      # + the KBs).
      def configure_for_bulk_write!(db)
        db.execute("PRAGMA journal_mode = WAL")
        db.execute("PRAGMA synchronous = NORMAL")
        db.execute("PRAGMA temp_store = MEMORY")
        db.execute("PRAGMA cache_size = -65536") # 64 MB page cache
      end
    end

    # Row-level writer helper yielded by +open_for_write+.
    class Writer
      SCHEMA_SQL = <<~SQL
        CREATE TABLE IF NOT EXISTS related (
          pk TEXT PRIMARY KEY,
          words TEXT NOT NULL,
          scores TEXT
        ) WITHOUT ROWID
      SQL

      def initialize(db)
        @db = db
        @upsert = db.prepare(
          "INSERT INTO related (pk, words, scores) VALUES (?, ?, ?) " \
          "ON CONFLICT(pk) DO UPDATE SET words = excluded.words, scores = excluded.scores"
        )
      end

      # +words+ and +scores+ are parallel arrays. Pass +nil+ or +[]+ for
      # +scores+ on old data; readers fall back to +RELATEDNESS_SCORE_THRESHOLD+
      # for every surviving word.
      def upsert_related(lemma_key, words, scores = nil)
        @upsert.execute(
          "related##{lemma_key}",
          JSON.generate(words),
          scores && !scores.empty? ? JSON.generate(scores) : nil
        )
      end

      # Attach +shard_path+ as a secondary database and bulk-copy its +related+
      # rows into the main table. Used by the parent process in
      # +bin/precompute-relatedness+ to merge per-worker shards.
      def merge_shard(shard_path)
        @db.execute("ATTACH DATABASE ? AS shard", shard_path)
        @db.execute(
          "INSERT OR REPLACE INTO related (pk, words, scores) " \
          "SELECT pk, words, scores FROM shard.related"
        )
      ensure
        @db.execute("DETACH DATABASE shard") rescue nil
      end
    end

    def clear_session_cache!
      @row_cache = {}
    end

    def initialize
      clear_session_cache!
    end

    def database_path
      self.class.database_path
    end

    # True when the local store exists on disk. Dev code uses this to decide
    # whether to fall through to the full-scan compute pipeline (pre-precompute
    # checkouts).
    def available?
      File.exist?(database_path)
    end

    def db
      @db ||= begin
        # +readonly: true+ + +immutable: false+ lets Puma threads share a single
        # handle safely; WAL mode means precompute can write while we read.
        handle = SQLite3::Database.new(database_path, readonly: true)
        handle.execute("PRAGMA query_only = 1")
        handle
      end
    end

    # Returns +[[word, score], ...]+ for the +related#<lemma>+ row, or +[]+.
    # Mirrors +DynamoRuntime.fetch_related_tuples+ so call sites don't care
    # which backend is active.
    def fetch_related_tuples(lemma_key)
      return @row_cache[lemma_key] if @row_cache.key?(lemma_key)
      return @row_cache[lemma_key] = [] unless available?

      row = db.get_first_row("SELECT words, scores FROM related WHERE pk = ?", "related##{lemma_key}")
      return @row_cache[lemma_key] = [] unless row

      words_json, scores_json = row
      words = JSON.parse(words_json)
      return @row_cache[lemma_key] = [] if !words.is_a?(Array) || words.empty?

      scores = scores_json.nil? ? [] : JSON.parse(scores_json)
      scores = [] unless scores.is_a?(Array)

      tuples = Array.new(words.size) do |i|
        s = scores[i]
        [words[i].to_s, s.is_a?(Numeric) ? s.to_i : RELATEDNESS_SCORE_THRESHOLD]
      end
      @row_cache[lemma_key] = tuples
    rescue JSON::ParserError, SQLite3::Exception => e
      warn "local_store: fetch_related_tuples(#{lemma_key.inspect}) failed: #{e.message}"
      @row_cache[lemma_key] = []
    end

    def fetch_related_words(lemma_key)
      fetch_related_tuples(lemma_key).map(&:first)
    end

    # Cheap existence check — used by the dev-only fallback in +related.rb+ to
    # distinguish "cue has no related words" (row exists but empty after filter)
    # from "cue is not precomputed at all" (no row → full-scan fallback).
    def has_related?(lemma_key)
      return false unless available?

      !db.get_first_value("SELECT 1 FROM related WHERE pk = ? LIMIT 1", "related##{lemma_key}").nil?
    rescue SQLite3::Exception
      false
    end

    # Mirror of +DynamoRuntime.find_all_related_precomputed+: returns the word
    # list filtered by the caller's visibility flags. Uses the in-process Ruby
    # dict helpers (+lexicon_word_entry+, +rdict_lookup+) loaded by +crime.rb+.
    def find_all_related_precomputed(lemma_key, include_rhymeless, common_only)
      find_all_related_precomputed_with_scores(lemma_key, include_rhymeless, common_only).map(&:first)
    end

    # Preserves the stored +relatedness_score+ on each surviving tuple so UI
    # sorting / coloring stays O(1) per candidate.
    def find_all_related_precomputed_with_scores(lemma_key, include_rhymeless, common_only)
      raw = fetch_related_tuples(lemma_key)
      return [] if raw.empty?

      # +defined?+ guard so this module is importable in isolation (e.g. by
      # +bin/upload-to-dynamodb+ which doesn't load +crime.rb+); callers that
      # actually need filtering will have those helpers in scope.
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
  end
end
