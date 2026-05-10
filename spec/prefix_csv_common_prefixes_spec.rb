# frozen_string_literal: true

require_relative "spec_helper"
require "csv"
require "rhymecrime/morphology/prefix_clusters"

PREFIX_CSV_SPEC_PATH = File.expand_path("../curated/prefix.csv", __dir__)

RSpec.describe "curated/prefix.csv vs COMMON_PREFIXES" do
  def distinct_prefixes_in_curated_csv
    CSV.read(PREFIX_CSV_SPEC_PATH, headers: true, encoding: "UTF-8").filter_map do |row|
      pfx = row["prefix"]&.strip
      next if pfx.nil? || pfx.empty?

      pfx
    end.uniq
  end

  it "includes every distinct prefix column value in COMMON_PREFIXES" do
    from_csv = distinct_prefixes_in_curated_csv
    missing = from_csv - COMMON_PREFIXES
    expect(missing).to be_empty,
      "Add these to COMMON_PREFIXES in morphology/prefix_clusters.rb (or fix the CSV): " \
      "#{missing.sort.inspect}"
  end
end
