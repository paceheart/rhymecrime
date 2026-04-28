# frozen_string_literal: true

# local_store.rb — SQLite-backed local mirror of the Lambda DynamoDB schema.
#
# Only the +related#<lemma>+ partition is mirrored today; words / rimes still
# load from the in-process Ruby dict in dev. The schema mirrors the DDB
# split: +related+ holds just +words+ (one row per cue) and +related_scores+
# holds the parallel +scores+ array. Splitting the two tables keeps the hot
# read path (+fetch_related_words+) free of a JSON parse for the score array
# whenever the caller doesn't need it (+/similar+ and +?debug=1+ are the only
# consumers). +bin/precompute-relatedness+ writes both tables; +bin/upload-
# to-dynamodb+ streams them out as +related#<lemma>+ and +score#<lemma>+
# items respectively.
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
      # Wraps the body in a single transaction by default — SQLite's per-commit
      # fsync dominates write throughput for many small +upsert_related+ calls.
      # Pass +transaction: false+ when the body runs ATTACH/DETACH (e.g. the
      # shard-merge path): SQLite can't DETACH an attached db while an enclosing
      # transaction still holds a read lock on it, which leaves the alias bound
      # and breaks the next ATTACH with "database <alias> is already in use".
      def open_for_write(path = database_path, transaction: true)
        FileUtils.mkdir_p(File.dirname(path))
        db = SQLite3::Database.new(path)
        configure_for_bulk_write!(db)
        # +execute_batch+ rather than +execute+ because +Writer::SCHEMA_SQL+
        # ships two CREATE TABLE statements and +execute+ runs only the first.
        db.execute_batch(Writer::SCHEMA_SQL)
        writer = Writer.new(db)
        if transaction
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
        else
          begin
            yield writer
          ensure
            db.close
          end
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
      SCHEMA_SQL = <<~SQL.freeze
        CREATE TABLE IF NOT EXISTS related (
          pk TEXT PRIMARY KEY,
          words TEXT NOT NULL
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS related_scores (
          pk TEXT PRIMARY KEY,
          scores TEXT NOT NULL
        ) WITHOUT ROWID;
      SQL

      def initialize(db)
        @db = db
        @upsert_words = db.prepare(
          "INSERT INTO related (pk, words) VALUES (?, ?) " \
          "ON CONFLICT(pk) DO UPDATE SET words = excluded.words"
        )
        @upsert_scores = db.prepare(
          "INSERT INTO related_scores (pk, scores) VALUES (?, ?) " \
          "ON CONFLICT(pk) DO UPDATE SET scores = excluded.scores"
        )
        @delete_scores = db.prepare("DELETE FROM related_scores WHERE pk = ?")
      end

      # +words+ and +scores+ are parallel arrays. Pass +nil+ or +[]+ for
      # +scores+ on old data; readers fall back to +RELATEDNESS_SCORE_THRESHOLD+
      # for every surviving word. When +scores+ is empty we proactively delete
      # any prior row in +related_scores+ so an upsert that drops scores
      # doesn't leave a stale parallel-array around.
      def upsert_related(lemma_key, words, scores = nil)
        pk = "related##{lemma_key}"
        @upsert_words.execute(pk, JSON.generate(words))
        if scores && !scores.empty?
          @upsert_scores.execute(pk, JSON.generate(scores))
        else
          @delete_scores.execute(pk)
        end
      end

      # Attach +shard_path+ as a secondary database and bulk-copy its
      # +related+ / +related_scores+ rows into the main tables. Used by the
      # parent process in +bin/precompute-relatedness+ to merge per-worker
      # shards. Must run in autocommit mode (see
      # +open_for_write(transaction: false)+): a wrapping transaction keeps a
      # read lock on the attached db, which prevents DETACH and collides on
      # the next merge's ATTACH.
      def merge_shard(shard_path)
        @db.execute("ATTACH DATABASE ? AS shard", shard_path)
        begin
          @db.execute(
            "INSERT OR REPLACE INTO related (pk, words) " \
            "SELECT pk, words FROM shard.related"
          )
          @db.execute(
            "INSERT OR REPLACE INTO related_scores (pk, scores) " \
            "SELECT pk, scores FROM shard.related_scores"
          )
        ensure
          @db.execute("DETACH DATABASE shard")
        end
      end
    end

    def clear_session_cache!
      # Two caches so the cheap path (+fetch_related_words+) doesn't pay the
      # parse cost or memory of the score array, and the lazy path
      # (+fetch_related_tuples+) can pull scores once and keep them resident
      # for repeat lookups (e.g. the +/similar+ page sorting).
      @words_cache = {}
      @scores_cache = {}
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
        announce_cache_age!
        handle
      end
    end

    # Print the cache path + creation/modification time exactly once per
    # process. Loud-on-load so we never silently consume a stale precompute
    # again when retraining the classifier or changing the score recipe — the
    # runtime predicate happily returns whatever scores the SQLite file holds,
    # which previously masked a +10pp+ accuracy delta in the live classifier
    # behind a "looks fine" eval banner.
    def announce_cache_age!
      return if @announced
      @announced = true
      path = database_path
      mtime = File.mtime(path) rescue nil
      size_mb = (File.size(path).to_f / 1024 / 1024).round(1) rescue nil
      stamp = mtime ? mtime.strftime("%Y-%m-%d %H:%M:%S %z") : "unknown"
      warn "[related-cache] loading precomputed store from #{path} " \
           "(built #{stamp}, #{size_mb} MB) — set RELATED_BYPASS_STORE=1 to force live compute"
    end

    # Hot-path read: pulls the cheap +related+ row only — no scores parse,
    # no second table lookup. Mirrors +DynamoRuntime.fetch_related_words+.
    def fetch_related_words(lemma_key)
      return @words_cache[lemma_key] if @words_cache.key?(lemma_key)
      return @words_cache[lemma_key] = [] unless available?

      row = db.get_first_row("SELECT words FROM related WHERE pk = ?", "related##{lemma_key}")
      return @words_cache[lemma_key] = [] unless row

      words = JSON.parse(row[0])
      @words_cache[lemma_key] = words.is_a?(Array) ? words.map(&:to_s) : []
    rescue JSON::ParserError, SQLite3::Exception => e
      warn "local_store: fetch_related_words(#{lemma_key.inspect}) failed: #{e.message}"
      @words_cache[lemma_key] = []
    end

    # Returns +[[word, score], ...]+ for the +related#<lemma>+ row, or +[]+.
    # Mirrors +DynamoRuntime.fetch_related_tuples+ so call sites don't care
    # which backend is active. Pays for one extra +related_scores+ lookup —
    # only consumed by +/similar+, +?debug=1+, and +lookup_score_by_lemmas+,
    # so the rhyme-page hot path never reaches it.
    def fetch_related_tuples(lemma_key)
      words = fetch_related_words(lemma_key)
      return [] if words.empty?

      scores = fetch_scores_array(lemma_key)
      Array.new(words.size) do |i|
        s = scores[i]
        [words[i], s.is_a?(Numeric) ? s.to_i : RELATEDNESS_SCORE_THRESHOLD]
      end
    end

    # Lazy companion to +fetch_related_words+. Returns the parallel score
    # array for +lemma_key+, or +[]+ when the +related_scores+ row is
    # missing. Cached separately from the words cache so repeat
    # +similarity+ calls on the same cue don't re-parse the JSON.
    def fetch_scores_array(lemma_key)
      return @scores_cache[lemma_key] if @scores_cache.key?(lemma_key)
      return @scores_cache[lemma_key] = [] unless available?

      row = db.get_first_row("SELECT scores FROM related_scores WHERE pk = ?", "related##{lemma_key}")
      return @scores_cache[lemma_key] = [] unless row

      parsed = JSON.parse(row[0])
      @scores_cache[lemma_key] = parsed.is_a?(Array) ? parsed : []
    rescue JSON::ParserError, SQLite3::Exception => e
      warn "local_store: fetch_scores_array(#{lemma_key.inspect}) failed: #{e.message}"
      @scores_cache[lemma_key] = []
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
    # list filtered by the caller's visibility flags, without fetching scores.
    # Uses the in-process Ruby dict helpers (+lexicon_word_entry+,
    # +rdict_lookup+) loaded by +crime.rb+.
    def find_all_related_precomputed(lemma_key, include_rhymeless, common_only)
      words = fetch_related_words(lemma_key)
      return [] if words.empty?

      filter_related_words(words, include_rhymeless, common_only)
    end

    # Preserves the stored +relatedness_score+ on each surviving tuple so UI
    # sorting / coloring stays O(1) per candidate. Pays for the +related_scores+
    # lookup; only callers that need scores should reach this.
    def find_all_related_precomputed_with_scores(lemma_key, include_rhymeless, common_only)
      raw = fetch_related_tuples(lemma_key)
      return [] if raw.empty?

      unless defined?(lexicon_word_entry) && defined?(rdict_lookup)
        return raw.dup
      end

      survivors = filter_related_words(raw.map(&:first), include_rhymeless, common_only).to_set
      raw.select { |(w, _s)| survivors.include?(w) }
    end

    # Shared filter step. +defined?+ guard so this module is importable in
    # isolation (e.g. by +bin/upload-to-dynamodb+ which doesn't load
    # +crime.rb+); callers that actually need filtering will have those
    # helpers in scope. Returns surviving words in the input order so a
    # caller zipping against +scores+ can preserve alignment via Set
    # membership.
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
  end
end
