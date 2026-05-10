# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "#inherit_prons_from_dispreferred_to_preferred!" do
  let(:bad_pron) { Pronunciation.new("M AA0 R V EH1 L D".split) }
  let(:word_dict) do
    {
      "marveled" => [10, []],
      "marvelled" => [10, [bad_pron]],
    }
  end

  before do
    require "rhymecrime/build/rime"
    allow(Object).to receive(:preferred_form_in_build_lexicon) do |word, _word_dict|
      (word == "marvelled") ? "marveled" : word
    end
  end

  after do
    $authoritative_pronunciation_words = nil
  end

  it "does not copy dispreferred prons onto a preferred headword listed in authoritative_pronunciations" do
    $authoritative_pronunciation_words = Set.new(["marveled"])
    inherit_prons_from_dispreferred_to_preferred!(word_dict, log: false)
    expect(word_dict["marveled"][1]).to eq([])
    expect(word_dict["marvelled"][1]).to eq([bad_pron])
  end

  it "still copies when the preferred headword is not authoritative" do
    $authoritative_pronunciation_words = Set.new
    inherit_prons_from_dispreferred_to_preferred!(word_dict, log: false)
    expect(word_dict["marveled"][1].map(&:to_s)).to eq([bad_pron.to_s])
  end
end
