# frozen_string_literal: true

# Coverage for the Rhymecrime::LocalStore schema split: words live in
# related and scores live in related_scores, so the cheap read path
# (fetch_related_words) doesn't pay for a JSON parse it doesn't need and
# a row that has words but no related_scores row falls back cleanly to
# RELATEDNESS_SCORE_THRESHOLD. The DDB backend does the same thing in
# its own read path; testing the SQLite mirror exercises the same
# threshold-fallback contract without needing AWS credentials.

require "tmpdir"
require "sqlite3"
require "json"
require_relative "spec_helper"
require "rhymecrime/dev/local_store"

RSpec.describe Rhymecrime::LocalStore do
  let(:tmpdir) { Dir.mktmpdir("rhymecrime-localstore-spec") }
  let(:db_path) { File.join(tmpdir, "store.sqlite3") }

  after do
    FileUtils.remove_entry(tmpdir) if File.exist?(tmpdir)
  end

  describe "Writer schema split" do
    it "creates separate related and related_scores tables" do
      described_class.open_for_write(db_path) do |writer|
        writer.upsert_related("cat", %w[dog mouse], [80, 60])
      end

      raw = SQLite3::Database.new(db_path, readonly: true)
      tables = raw.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").flatten
      expect(tables).to include("related", "related_scores")

      cols_related = raw.execute("PRAGMA table_info(related)").map { |r| r[1] }
      cols_scores  = raw.execute("PRAGMA table_info(related_scores)").map { |r| r[1] }
      expect(cols_related).to contain_exactly("pk", "words")
      expect(cols_scores).to contain_exactly("pk", "scores")
      raw.close
    end

    it "writes scores only when non-empty and drops a stale related_scores row when scores are cleared" do
      described_class.open_for_write(db_path) do |writer|
        writer.upsert_related("cat", %w[dog mouse], [80, 60])
        writer.upsert_related("dog", %w[bone], nil)
        writer.upsert_related("cat", %w[dog mouse], nil) # second pass: clear scores
      end

      raw = SQLite3::Database.new(db_path, readonly: true)
      score_pks = raw.execute("SELECT pk FROM related_scores ORDER BY pk").flatten
      expect(score_pks).to be_empty
      word_pks = raw.execute("SELECT pk FROM related ORDER BY pk").flatten
      expect(word_pks).to contain_exactly("related#cat", "related#dog")
      raw.close
    end
  end

  describe "Reader path" do
    # Singleton instance is process-wide, so reset it between examples that
    # point at distinct on-disk fixtures to keep the row caches honest. The
    # after block reopens any subsequent same-process read against the real
    # path by re-stubbing — instance.@db memoization is also cleared so we
    # don't leak a tmpdir handle across examples.
    before do
      allow(described_class).to receive(:database_path).and_return(db_path)
      described_class.instance.instance_variable_set(:@db, nil)
      described_class.instance.clear_session_cache!
    end

    after do
      described_class.instance.instance_variable_set(:@db, nil)
      described_class.instance.clear_session_cache!
    end

    it "returns words without touching the scores table" do
      described_class.open_for_write(db_path) do |writer|
        writer.upsert_related("cat", %w[dog mouse], [80, 60])
      end

      expect(described_class.fetch_related_words("cat")).to eq(%w[dog mouse])
    end

    it "zips parallel scores when related_scores has a row" do
      described_class.open_for_write(db_path) do |writer|
        writer.upsert_related("cat", %w[dog mouse], [80, 60])
      end

      expect(described_class.fetch_related_tuples("cat")).to eq([["dog", 80], ["mouse", 60]])
    end

    it "falls back to RELATEDNESS_SCORE_THRESHOLD when the related_scores row is missing" do
      described_class.open_for_write(db_path) do |writer|
        writer.upsert_related("cat", %w[dog mouse], nil)
      end

      tuples = described_class.fetch_related_tuples("cat")
      expect(tuples.map(&:first)).to eq(%w[dog mouse])
      expect(tuples.map(&:last)).to all(eq(RELATEDNESS_SCORE_THRESHOLD))
    end

    it "falls back to the threshold for individual indices the scores array does not cover" do
      # Simulate a length mismatch between words and scores — defensive
      # path that protects the runtime from a shorter-than-words score row.
      described_class.open_for_write(db_path) do |writer|
        writer.upsert_related("cat", %w[dog mouse rat], [80])
      end

      tuples = described_class.fetch_related_tuples("cat")
      expect(tuples).to eq([
        ["dog", 80],
        ["mouse", RELATEDNESS_SCORE_THRESHOLD],
        ["rat", RELATEDNESS_SCORE_THRESHOLD]
      ])
    end

    it "returns [] when the cue is absent from both tables" do
      described_class.open_for_write(db_path) do |writer|
        writer.upsert_related("cat", %w[dog], [80])
      end

      expect(described_class.fetch_related_words("nonsense_cue")).to eq([])
      expect(described_class.fetch_related_tuples("nonsense_cue")).to eq([])
    end
  end

  describe ".delete_database_file!" do
    # Regression: bin/compute-relatedness used to do a bare
    # File.delete(shard_path) on the shard mains between runs and leave the
    # -shm / -wal sidecars on disk. SQLite then re-opened the freshly
    # created shard, found a WAL pair whose header counters didn't match the
    # new (empty) main, and faulted the very first execute_batch with a
    # disk I/O error (SQLITE_IOERR). delete_database_file! exists to
    # take the WAL pair down with the main file so the next open_for_write
    # always sees a clean slate.
    it "removes the main file alongside its WAL sidecars" do
      described_class.open_for_write(db_path) do |writer|
        writer.upsert_related("cat", %w[dog], [80])
      end
      # Sanity: WAL mode is on so the sidecars exist on disk after the
      # transaction; if WAL ever defaults change this assertion makes the
      # behaviour shift loud rather than silently making the regression
      # untestable.
      expect(File.exist?(db_path)).to be true
      expect(File.exist?("#{db_path}-wal")).to be true
      expect(File.exist?("#{db_path}-shm")).to be true

      described_class.delete_database_file!(db_path)

      expect(File.exist?(db_path)).to be false
      expect(File.exist?("#{db_path}-wal")).to be false
      expect(File.exist?("#{db_path}-shm")).to be false
    end

    it "is a no-op on missing paths and tolerates a partial sidecar set" do
      # Pre-fork cleanup runs unconditionally before every shard, so the
      # common case is "nothing exists yet"; it must not raise. Likewise a
      # crash that left only the -shm behind (no main) should still get
      # cleaned up so the next open starts fresh.
      missing = File.join(tmpdir, "never_existed.sqlite3")
      expect { described_class.delete_database_file!(missing) }.not_to raise_error

      File.write("#{missing}-shm", "")
      described_class.delete_database_file!(missing)
      expect(File.exist?("#{missing}-shm")).to be false
    end

    it "lets a fresh open_for_write on the same path succeed even when stale sidecars were present" do
      # Direct reproduction of the failure mode. Simulate a previous-run
      # crash by writing a sidecar then dropping the main file the way the
      # old cleanup did, and confirm the new helper unblocks the next
      # open_for_write where a bare File.delete would have left the
      # SQLITE_IOERR landmine in place.
      described_class.open_for_write(db_path) do |writer|
        writer.upsert_related("cat", %w[dog], [80])
      end
      File.delete(db_path) # the old buggy cleanup
      expect(File.exist?("#{db_path}-wal")).to be true

      described_class.delete_database_file!(db_path)
      expect {
        described_class.open_for_write(db_path) do |writer|
          writer.upsert_related("frog", %w[toad], nil)
        end
      }.not_to raise_error

      raw = SQLite3::Database.new(db_path, readonly: true)
      pks = raw.execute("SELECT pk FROM related ORDER BY pk").flatten
      raw.close
      expect(pks).to contain_exactly("related#frog")
    end
  end

  describe "merge_shard" do
    it "copies rows from both tables across attached databases" do
      shard_path = File.join(tmpdir, "shard.sqlite3")
      described_class.open_for_write(shard_path) do |w|
        w.upsert_related("cat", %w[dog], [80])
        w.upsert_related("frog", %w[toad], nil)
      end

      described_class.open_for_write(db_path, transaction: false) do |w|
        w.upsert_related("cat", %w[mouse], [10]) # later merge should overwrite
        w.merge_shard(shard_path)
      end

      raw = SQLite3::Database.new(db_path, readonly: true)
      cat_words = JSON.parse(raw.get_first_value("SELECT words FROM related WHERE pk = 'related#cat'"))
      cat_scores = JSON.parse(raw.get_first_value("SELECT scores FROM related_scores WHERE pk = 'related#cat'"))
      frog_words = JSON.parse(raw.get_first_value("SELECT words FROM related WHERE pk = 'related#frog'"))
      frog_scores = raw.get_first_value("SELECT scores FROM related_scores WHERE pk = 'related#frog'")
      raw.close

      expect(cat_words).to eq(%w[dog])
      expect(cat_scores).to eq([80])
      expect(frog_words).to eq(%w[toad])
      expect(frog_scores).to be_nil
    end
  end

  describe "set_related table" do
    # set_related#<lemma> is the computed post-prune rhyming-tuple list
    # the runtime hot path reads (see Rhymecrime::Store.fetch_set_related_
    # tuples). Schema lives in its own table so a missing-row miss
    # (fetch_set_related_tuples returns nil) cleanly distinguishes
    # "this cue isn't in our universe — show the friendly bad_input
    # message" from "this cue exists but happened to have no rhyming
    # friends — render an empty result list."
    it "creates a set_related table with the documented schema" do
      described_class.open_for_write(db_path) do |writer|
        writer.upsert_set_related("cat", [%w[bat hat], %w[mouse louse]])
      end

      raw = SQLite3::Database.new(db_path, readonly: true)
      tables = raw.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").flatten
      expect(tables).to include("set_related")
      cols = raw.execute("PRAGMA table_info(set_related)").map { |r| r[1] }
      expect(cols).to contain_exactly("pk", "tuples")
      raw.close
    end

    describe "Reader cache" do
      before do
        allow(described_class).to receive(:database_path).and_return(db_path)
        described_class.instance.instance_variable_set(:@db, nil)
        described_class.instance.clear_session_cache!
      end

      after do
        described_class.instance.instance_variable_set(:@db, nil)
        described_class.instance.clear_session_cache!
      end

      it "round-trips the tuples list" do
        described_class.open_for_write(db_path) do |writer|
          writer.upsert_set_related("cat", [%w[bat hat], %w[mouse louse]])
        end

        expect(described_class.fetch_set_related_tuples("cat")).to eq([%w[bat hat], %w[mouse louse]])
        expect(described_class.has_set_related?("cat")).to be true
      end

      it "round-trips an empty tuples list as [] (computed-but-no-rhymes contract)" do
        # Empty arrays are valid: the runtime renders them as a
        # computed hit with no tuples, distinct from the nil "unknown
        # cue" fallback that triggers the friendly message.
        described_class.open_for_write(db_path) do |writer|
          writer.upsert_set_related("lonely_cue", [])
        end

        expect(described_class.fetch_set_related_tuples("lonely_cue")).to eq([])
        expect(described_class.has_set_related?("lonely_cue")).to be true
      end

      it "returns nil when the cue is absent (signal for the friendly-message branch)" do
        described_class.open_for_write(db_path) do |writer|
          writer.upsert_set_related("cat", [%w[bat hat]])
        end

        expect(described_class.fetch_set_related_tuples("missing_cue")).to be_nil
        expect(described_class.has_set_related?("missing_cue")).to be false
      end

      it "caches both hits and misses across calls without re-reading SQLite" do
        described_class.open_for_write(db_path) do |writer|
          writer.upsert_set_related("cat", [%w[bat hat]])
        end

        # Prime the cache: one hit, one miss.
        expect(described_class.fetch_set_related_tuples("cat")).to eq([%w[bat hat]])
        expect(described_class.fetch_set_related_tuples("missing_cue")).to be_nil

        # Now break the underlying handle so any second SQLite read raises;
        # the cache must satisfy both calls without going to disk.
        described_class.instance.instance_variable_set(:@db, nil)
        allow(described_class.instance).to receive(:db).and_raise(SQLite3::Exception.new("forced"))

        expect(described_class.fetch_set_related_tuples("cat")).to eq([%w[bat hat]])
        expect(described_class.fetch_set_related_tuples("missing_cue")).to be_nil
      end
    end

    it "merge_shard copies set_related rows alongside related / related_scores" do
      shard_path = File.join(tmpdir, "shard.sqlite3")
      described_class.open_for_write(shard_path) do |w|
        w.upsert_set_related("cat", [%w[bat hat]])
        w.upsert_set_related("frog", [])
      end

      described_class.open_for_write(db_path, transaction: false) do |w|
        w.upsert_set_related("cat", [%w[mat]]) # later merge should overwrite
        w.merge_shard(shard_path)
      end

      raw = SQLite3::Database.new(db_path, readonly: true)
      cat_tuples = JSON.parse(raw.get_first_value("SELECT tuples FROM set_related WHERE pk = 'set_related#cat'"))
      frog_tuples = JSON.parse(raw.get_first_value("SELECT tuples FROM set_related WHERE pk = 'set_related#frog'"))
      raw.close

      expect(cat_tuples).to eq([%w[bat hat]])
      expect(frog_tuples).to eq([])
    end
  end
end
