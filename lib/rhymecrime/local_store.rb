# frozen_string_literal: true

# local_store.rb — SQLite-backed local mirror of the Lambda DynamoDB schema.
#
# Three partitions are mirrored: +related#<lemma>+ (cheap words list),
# +score#<lemma>+ (lazy parallel scores), and +set_related#<lemma>+
# (post-prune rhyming-tuple list, the runtime hot-path answer for the
# +set_related+ goal). Words / rimes still load from the in-process Ruby
# dict in dev.
#
# Splitting +related+ from +related_scores+ keeps the cheap read path
# (+fetch_related_words+) free of a JSON parse for the score array
# whenever the caller doesn't need it (+/similar+ and +?debug=1+ are the
# only consumers). +bin/compute-relatedness+ writes both;
# +bin/compute-set-related+ writes the +set_related+ table after; and
# +bin/upload-to-dynamodb+ streams all three out as +related#<lemma>+,
# +score#<lemma>+, and +set_related#<lemma>+ items respectively.
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
                     :find_all_related_computed, :find_all_related_computed_with_scores,
                     :has_related?, :fetch_set_related_tuples, :has_set_related?,
                     :available?, :clear_session_cache!

      def database_path
        generated_dict_path(LOCAL_STORE_FILENAME)
      end

      # Opens (or creates) a local store SQLite file for writing and yields a
      # +Writer+. Used by +bin/compute-relatedness+ (workers for per-shard
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
      # server) stay up while compute is writing; +synchronous=NORMAL+ is
      # enough durability for a derivable local cache (we never keep the sole
      # copy of anything here — JSONL-style source-of-truth is the classifier
      # + the KBs).
      def configure_for_bulk_write!(db)
        db.execute("PRAGMA journal_mode = WAL")
        db.execute("PRAGMA synchronous = NORMAL")
        db.execute("PRAGMA temp_store = MEMORY")
        db.execute("PRAGMA cache_size = -65536") # 64 MB page cache
      end

      # Delete a SQLite database file along with its WAL sidecars (+-wal+,
      # +-shm+) and any rollback journal. Use this instead of
      # +File.delete(path)+ whenever you want to recreate the database from
      # scratch: SQLite stores uncommitted/unmerged frames in the +-wal+ file
      # and a memory-mapped index in +-shm+, and re-opening a freshly created
      # main file with a stale WAL pair surfaces as +SQLITE_IOERR+ ("disk I/O
      # error") on the very first write because the header counters disagree.
      # A previous +bin/compute-relatedness+ crash that left the +.shardN.tmp+
      # main files cleaned but the +-wal+ / +-shm+ behind would otherwise
      # silently break every subsequent shard run on the same paths until the
      # generated/ dir was hand-cleaned.
      def delete_database_file!(path)
        return unless path
        [path, "#{path}-wal", "#{path}-shm", "#{path}-journal"].each do |p|
          File.delete(p) if File.exist?(p)
        end
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
        CREATE TABLE IF NOT EXISTS set_related (
          pk TEXT PRIMARY KEY,
          tuples TEXT NOT NULL
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
        @upsert_set_related = db.prepare(
          "INSERT INTO set_related (pk, tuples) VALUES (?, ?) " \
          "ON CONFLICT(pk) DO UPDATE SET tuples = excluded.tuples"
        )
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

      # Stash the post-prune rhyming-tuple list for +lemma_key+. +tuples+ is
      # an Array of Arrays — each inner Array is a sorted list of headwords
      # that rhyme with each other and are all related to the cue. Mirrors
      # the runtime contract of +really_find_rhyming_tuples+ in +crime.rb+:
      # tuples are sorted-uniq, contain at least 2 entries, and are
      # cross-tuple-redundancy-pruned. Empty +tuples+ array is a valid
      # "this cue has no rhyming friends" answer (rare but real — e.g.
      # cues with relateds that have no shared rime cohorts) and gets
      # written as such; the reader distinguishes "empty tuples" from
      # "no row" via +has_set_related?+.
      def upsert_set_related(lemma_key, tuples)
        pk = "set_related##{lemma_key}"
        @upsert_set_related.execute(pk, JSON.generate(tuples))
      end

      # Attach +shard_path+ as a secondary database and bulk-copy its
      # +related+ / +related_scores+ rows into the main tables. Used by the
      # parent process in +bin/compute-relatedness+ to merge per-worker
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
          @db.execute(
            "INSERT OR REPLACE INTO set_related (pk, tuples) " \
            "SELECT pk, tuples FROM shard.set_related"
          )
        ensure
          @db.execute("DETACH DATABASE shard")
        end
      end
    end

    def clear_session_cache!
      # Three caches: +@words_cache+ is the cheap +fetch_related_words+ path,
      # +@scores_cache+ is the lazy +fetch_related_tuples+ companion, and
      # +@set_related_cache+ is the computed-tuples cache. They're
      # separate so the cheap path doesn't pay the parse cost or memory of
      # data it doesn't need, and so a row absent from one table (e.g. a
      # lemma with +related+ but no computed +set_related+ — which
      # shouldn't happen post-compute but is harmless mid-deploy)
      # caches its emptiness independently of the others.
      #
      # +@set_related_table_exists+ is a per-DB-handle flag, not a per-
      # request one (the schema doesn't change mid-process); we reset
      # it here so test fixtures that swap +@db+ between examples pick
      # up the new file's schema instead of carrying the previous file's
      # detection result.
      @words_cache = {}
      @scores_cache = {}
      @set_related_cache = {}
      @set_related_table_exists = nil
    end

    def initialize
      clear_session_cache!
    end

    def database_path
      self.class.database_path
    end

    # True when the local store exists on disk. Dev code uses this to decide
    # whether to fall through to the full-scan compute pipeline (pre-compute
    # checkouts).
    def available?
      File.exist?(database_path)
    end

    def db
      @db ||= begin
        # +readonly: true+ + +immutable: false+ lets Puma threads share a single
        # handle safely; WAL mode means compute can write while we read.
        handle = SQLite3::Database.new(database_path, readonly: true)
        handle.execute("PRAGMA query_only = 1")
        announce_cache_age!
        handle
      end
    end

    # Print the cache path + creation/modification time exactly once per
    # process. Loud-on-load so we never silently consume a stale compute
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
      warn "[related-cache] loading computed store from #{path} " \
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
    # from "cue is not computed at all" (no row → full-scan fallback).
    def has_related?(lemma_key)
      return false unless available?

      !db.get_first_value("SELECT 1 FROM related WHERE pk = ? LIMIT 1", "related##{lemma_key}").nil?
    rescue SQLite3::Exception
      false
    end

    # Hot-path read for the runtime +set_related+ goal: returns the
    # computed Array of tuples (each a sorted Array of headwords) for
    # +lemma_key+, or +nil+ when no row exists for this cue. Mirrors
    # +DynamoRuntime.fetch_set_related_tuples+ in shape so the +Store+
    # facade can dispatch transparently.
    #
    # +nil+ vs +[]+ matters: an empty array is a valid "this cue survived
    # the cueniverse filter but has no rhyming friends" answer that the
    # caller will render normally, while +nil+ signals "we never
    # computed this cue" and routes to the friendly-message branch in
    # +crime.rb+'s goal dispatch.
    def fetch_set_related_tuples(lemma_key)
      return @set_related_cache[lemma_key] if @set_related_cache.key?(lemma_key)
      return @set_related_cache[lemma_key] = nil unless available?
      # During the migration window after the +set_related+ schema lands
      # but before +bin/compute-set-related+ has populated the table,
      # the schema upgrade hasn't happened on the dev's local SQLite
      # file yet. Treat that as "no row" silently — the live-compute
      # fallback in +crime.rb+'s +find_rhyming_tuples+ still produces
      # results — and only reach for the warn-on-corruption branch on
      # real read failures.
      return @set_related_cache[lemma_key] = nil unless set_related_table_exists?

      row = db.get_first_row("SELECT tuples FROM set_related WHERE pk = ?", "set_related##{lemma_key}")
      return @set_related_cache[lemma_key] = nil unless row

      parsed = JSON.parse(row[0])
      @set_related_cache[lemma_key] = parsed.is_a?(Array) ? parsed : nil
    rescue JSON::ParserError, SQLite3::Exception => e
      warn "local_store: fetch_set_related_tuples(#{lemma_key.inspect}) failed: #{e.message}"
      @set_related_cache[lemma_key] = nil
    end

    # Cheap existence check sibling of +has_related?+. Used by the runtime
    # to short-circuit goal dispatch with a friendly message when no row
    # is present, without paying the JSON parse of +fetch_set_related_tuples+.
    def has_set_related?(lemma_key)
      return false unless available?
      return false unless set_related_table_exists?

      !db.get_first_value("SELECT 1 FROM set_related WHERE pk = ? LIMIT 1", "set_related##{lemma_key}").nil?
    rescue SQLite3::Exception
      false
    end

    # Detected once per process: whether the +set_related+ table is
    # present in the local SQLite. Pre-compute-set-related checkouts
    # have a +rhymecrime_local.sqlite3+ from an earlier
    # +bin/compute-relatedness+ run with only +related+ /
    # +related_scores+; we don't want to spam stderr with a "no such
    # table" warning for every cue until the user runs the new
    # compute. The check itself is one cheap +sqlite_master+ lookup.
    def set_related_table_exists?
      return @set_related_table_exists unless @set_related_table_exists.nil?

      @set_related_table_exists =
        !db.get_first_value(
          "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'set_related' LIMIT 1"
        ).nil?
    rescue SQLite3::Exception
      @set_related_table_exists = false
    end

    # Mirror of +DynamoRuntime.find_all_related_computed+: returns the word
    # list filtered by the caller's visibility flags, without fetching scores.
    # Uses the in-process Ruby dict helpers (+lexicon_word_entry+,
    # +rime_dict_lookup+) loaded by +crime.rb+.
    def find_all_related_computed(lemma_key, include_rhymeless, common_only)
      words = fetch_related_words(lemma_key)
      return [] if words.empty?

      filter_related_words(words, include_rhymeless, common_only)
    end

    # Preserves the stored +relatedness_score+ on each surviving tuple so UI
    # sorting / coloring stays O(1) per candidate. Pays for the +related_scores+
    # lookup; only callers that need scores should reach this.
    def find_all_related_computed_with_scores(lemma_key, include_rhymeless, common_only)
      raw = fetch_related_tuples(lemma_key)
      return [] if raw.empty?

      unless defined?(lexicon_word_entry) && defined?(rime_dict_lookup)
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
      return words.dup unless defined?(lexicon_word_entry) && defined?(rime_dict_lookup)

      words.select do |w|
        entry = lexicon_word_entry(w)
        next false unless entry
        next false if common_only && entry[0].to_i <= RARE_FREQ_MAX

        if include_rhymeless
          true
        else
          entry[1].any? { |pron| !pron.rime.to_s.empty? && !rime_dict_lookup(pron.rime).empty? }
        end
      end
    end
  end
end
