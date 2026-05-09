# frozen_string_literal: true

require "spec_helper"
require "rhymecrime/lookup_paths"

RSpec.describe Rhymecrime::LookupPaths do
  describe ".parse_path" do
    it "returns nil for root and empty paths" do
      expect(described_class.parse_path("/")).to be_nil
      expect(described_class.parse_path("")).to be_nil
    end

    it "returns nil when any segment contains a dot (static files)" do
      expect(described_class.parse_path("/robots.txt")).to be_nil
      expect(described_class.parse_path("/foo.css")).to be_nil
    end

    it "returns nil when more than two segments" do
      expect(described_class.parse_path("/a/b/c")).to be_nil
    end

    it "returns nil for reserved first segments (production safety)" do
      expect(described_class.parse_path("/similar")).to be_nil
      expect(described_class.parse_path("/_health")).to be_nil
      expect(described_class.parse_path("/_feedback")).to be_nil
    end

    it "parses one- and two-segment lookups with percent-decoding" do
      expect(described_class.parse_path("/food")).to eq(["food", ""])
      expect(described_class.parse_path("/food/evil")).to eq(%w[food evil])
      expect(described_class.parse_path("/caf%C3%A9")).to eq(["café", ""])
    end

    it "documents reserved cue collision: builder emits /similar but parse rejects it" do
      expect(described_class.lookup_path_from_normalized_words("similar", "")).to eq("/similar")
      expect(described_class.parse_path("/similar")).to be_nil
    end
  end

  describe ".lookup_path_from_normalized_words" do
    it "builds slash URLs matching the browser encodeURIComponent contract" do
      expect(described_class.lookup_path_from_normalized_words("", "")).to eq("/")
      expect(described_class.lookup_path_from_normalized_words("food", "")).to eq("/food")
      expect(described_class.lookup_path_from_normalized_words("food", "evil")).to eq("/food/evil")
      expect(described_class.lookup_path_from_normalized_words("café", "")).to eq("/caf%C3%A9")
    end
  end
end
