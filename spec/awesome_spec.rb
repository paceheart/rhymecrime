require "csv"

require_relative "similar_rhymes_set_related_support"

AWESOME_CSV_PATH = File.expand_path("../curated/awesome.csv", __dir__)

def awesome_csv_rows
  CSV.read(AWESOME_CSV_PATH, encoding: "UTF-8").each_with_index.map do |row, index|
    cue, *words = row.map { |cell| cell.to_s.strip }
    raise "curated/awesome.csv line #{index + 1}: expected cue and at least two rhyming words" if cue.empty? || words.length < 2 || words.any?(&:empty?)

    [index + 1, cue, words]
  end
end

RSpec.describe "curated/awesome.csv" do
  awesome_csv_rows.each do |line_number, cue, words|
    it "line #{line_number}: set_related #{cue} includes #{words.join(' / ')}" do
      hit, diag = with_similar_spec_pruning_fallback(cue, false) do |tuples, _mode|
        next false if tuples.nil?

        tuples.any? { |tuple| words.all? { |word| tuple.include?(word) } }
      end

      expect(hit).to eql(true),
        "Set-related rhymes for '#{cue}' oughta include #{words.map { |w| "'#{w}'" }.join(' / ')} together, but #{summarize_tuples_for_failure(diag, *words)}"
    end
  end
end
