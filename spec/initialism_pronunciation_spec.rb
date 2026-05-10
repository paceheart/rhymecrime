# encoding: utf-8

require "set"

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

RSpec.describe "drop_mixed_initialism_nonletter_pronunciations!" do
  it "keeps only letter-spelled rows when CMU also lists a word-like alt" do
    letter = Pronunciation.new(%w[AY2 . P IY2])
    word_like = Pronunciation.new(%w[IH1 P])
    m = { "ip" => [letter, word_like] }
    drop_mixed_initialism_nonletter_pronunciations!(m, authoritative_words: Set.new)
    expect(m["ip"].size).to eq(1)
    expect(m["ip"].first.rime).to eq(letter.rime)
  end

  it "does not strip two-letter blocklist homographs" do
    y_us = Pronunciation.new(%w[Y UW1 EH1 S])
    ah_s = Pronunciation.new(%w[AH1 S])
    m = { "us" => [y_us, ah_s] }
    drop_mixed_initialism_nonletter_pronunciations!(m, authoritative_words: Set.new)
    expect(m["us"].size).to eq(2)
  end

  it "skips headwords listed as authoritative" do
    letter = Pronunciation.new(%w[AY2 . P IY2])
    word_like = Pronunciation.new(%w[IH1 P])
    m = { "ip" => [letter, word_like] }
    drop_mixed_initialism_nonletter_pronunciations!(m, authoritative_words: Set.new(["ip"]))
    expect(m["ip"].size).to eq(2)
  end
end
