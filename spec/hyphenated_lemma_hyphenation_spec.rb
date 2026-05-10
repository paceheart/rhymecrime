# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "Hyphenated lemma hyphenation consistency" do
  it "requires a hyphen in every surface whose lemma contains a hyphen" do
    bad = []
    word_dict.each_key do |w|
      lem = lemma(w)
      next unless lem.include?("-")
      next if w.include?("-")

      bad << "lemma(#{w.inspect}) == #{lem.inspect} but the headword has no hyphen"
    end
    expect(bad).to be_empty, bad.join("\n")
  end
end
