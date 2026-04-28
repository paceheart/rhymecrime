# frozen_string_literal: true

# Coverage for the +Rhymecrime::LocalStore+ schema split: words live in
# +related+ and scores live in +related_scores+, so the cheap read path
# (+fetch_related_words+) doesn't pay for a JSON parse it doesn't need and
# a row that has words but no +related_scores+ row falls back cleanly to
# +RELATEDNESS_SCORE_THRESHOLD+. The DDB backend does the same thing in
# its own read path; testing the SQLite mirror exercises the same
# threshold-fallback contract without needing AWS credentials.

require "tmpdir"
require "sqlite3"
require "json"
require_relative "spec_helper"
require "rhymecrime/local_store"

RSpec.describe Rhymecrime::LocalStore do
  let(:tmpdir) { Dir.mktmpdir("rhymecrime-localstore-spec") }
  let(:db_path) { File.join(tmpdir, "store.sqlite3") }

  after do
    FileUtils.remove_entry(tmpdir) if File.exist?(tmpdir)
  end

  describe "Writer schema split" do
    it "creates separate +related+ and +related_scores+ tables" do
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

    it "writes scores only when non-empty and drops a stale +related_scores+ row when scores are cleared" do
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
    # +after+ block reopens any subsequent same-process read against the real
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

    it "zips parallel scores when +related_scores+ has a row" do
      described_class.open_for_write(db_path) do |writer|
        writer.upsert_related("cat", %w[dog mouse], [80, 60])
      end

      expect(described_class.fetch_related_tuples("cat")).to eq([["dog", 80], ["mouse", 60]])
    end

    it "falls back to RELATEDNESS_SCORE_THRESHOLD when the +related_scores+ row is missing" do
      described_class.open_for_write(db_path) do |writer|
        writer.upsert_related("cat", %w[dog mouse], nil)
      end

      tuples = described_class.fetch_related_tuples("cat")
      expect(tuples.map(&:first)).to eq(%w[dog mouse])
      expect(tuples.map(&:last)).to all(eq(RELATEDNESS_SCORE_THRESHOLD))
    end

    it "falls back to the threshold for individual indices the scores array does not cover" do
      # Simulate a length mismatch between +words+ and +scores+ — defensive
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

    it "returns +[]+ when the cue is absent from both tables" do
      described_class.open_for_write(db_path) do |writer|
        writer.upsert_related("cat", %w[dog], [80])
      end

      expect(described_class.fetch_related_words("nonsense_cue")).to eq([])
      expect(described_class.fetch_related_tuples("nonsense_cue")).to eq([])
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
end
