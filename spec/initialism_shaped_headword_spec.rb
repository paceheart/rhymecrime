# encoding: utf-8

require_relative "../lib/rhymecrime/build/phonology"

RSpec.describe "initialism_shaped_headword?" do
  it "detects period-separated letter spellings" do
    expect(initialism_shaped_headword?("u.s")).to eq(true)
    expect(initialism_shaped_headword?("p.m")).to eq(true)
    expect(initialism_shaped_headword?("c.o.d")).to eq(true)
  end

  it "detects hyphen chains of single letters" do
    expect(initialism_shaped_headword?("b-j")).to eq(true)
  end

  it "does not treat ordinary words or homographs like us as initialism-shaped" do
    expect(initialism_shaped_headword?("us")).to eq(false)
    expect(initialism_shaped_headword?("cat")).to eq(false)
    expect(initialism_shaped_headword?("fbi")).to eq(false)
  end

  it "does not treat hyphenated ordinary compounds as initialism-shaped" do
    expect(initialism_shaped_headword?("e-mail")).to eq(false)
    expect(initialism_shaped_headword?("so-so")).to eq(false)
  end
end
