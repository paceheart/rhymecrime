# encoding: utf-8

require_relative "../lib/rhymecrime/build/initialism_pronunciation"
require_relative "../lib/rhymecrime/pronunciation"

RSpec.describe "pronunciation_spells_out_headword_letters?" do
  it "detects CMU-style letter-by-letter readings" do
    expect(pronunciation_spells_out_headword_letters?(
             "uss",
             Pronunciation.new(%w[Y UW1 EH1 S EH1 S]),
           )).to eq(true)
    expect(pronunciation_spells_out_headword_letters?(
             "fbi",
             Pronunciation.new(%w[EH1 F B IY1 AY1]),
           )).to eq(true)
    expect(pronunciation_spells_out_headword_letters?(
             "cia",
             Pronunciation.new(%w[S IY1 AY1 EY1]),
           )).to eq(true)
  end

  it "rejects word-like pronunciations and spoken acronyms" do
    expect(pronunciation_spells_out_headword_letters?(
             "cat",
             Pronunciation.new(%w[K AE1 T]),
           )).to eq(false)
    expect(pronunciation_spells_out_headword_letters?(
             "nato",
             Pronunciation.new(%w[N EY1 T OW0]),
           )).to eq(false)
    expect(pronunciation_spells_out_headword_letters?(
             "nasa",
             Pronunciation.new(%w[N AE1 S AH0]),
           )).to eq(false)
  end

  it "does not treat the pronoun reading of us as spelled-out U+S" do
    expect(pronunciation_spells_out_headword_letters?(
             "us",
             Pronunciation.new(%w[AH1 S]),
           )).to eq(false)
  end

  it "treats Y UW EH S as spelled-out us (letter reading; rarity skips multi-pron)" do
    expect(pronunciation_spells_out_headword_letters?(
             "us",
             Pronunciation.new(%w[Y UW1 EH1 S]),
           )).to eq(true)
  end
end
