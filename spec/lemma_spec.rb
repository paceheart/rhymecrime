# Lemma column expectations from generated/word_dict (see bin/dict-build and lemma_base_overrides).
# Rows: surface, lemma, optional skip (1 to skip unless RHYMECRIME_RUN_SKIPPED), optional notes.

require "csv"
require_relative "test_utils"

def lemma_csv_path
  File.join(__dir__, "lemma.csv")
end

def load_lemma_csv_rows
  raw = File.read(lemma_csv_path, encoding: "UTF-8")
  CSV.parse(raw, headers: true, encoding: "UTF-8")
end

def validate_lemma_csv_row!(row, line_hint = nil)
  hint = line_hint ? " (#{line_hint})" : ""
  surface = row["surface"].to_s.strip
  lem = row["lemma"].to_s.strip
  raise "lemma.csv: empty surface#{hint}" if surface.empty?
  raise "lemma.csv: empty lemma#{hint}" if lem.empty?
end

def oughta_lemma(surface, expected_lemma, not_working_message: nil)
  it "lemma('#{surface}') is '#{expected_lemma}'" do
    skip_if_not_working(not_working_message)
    got = lemma(surface)
    expect(got).to eq(expected_lemma), "expected lemma('#{surface}') == '#{expected_lemma}', got '#{got}' (word_dict column / overrides)"
  end
end

describe "LEMMA" do
  rows = load_lemma_csv_rows
  rows.each_with_index do |row, i|
    validate_lemma_csv_row!(row, "line #{i + 2}")
  end
  rows.each do |row|
    surface = row["surface"].to_s.strip
    expected = row["lemma"].to_s.strip
    skip = row["skip"].to_s.strip == "1" ? true : nil
    oughta_lemma surface, expected, not_working_message: skip
  end
end
