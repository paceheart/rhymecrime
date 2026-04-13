# encoding: utf-8
require "rhymecrime/dict/inflect"

def inflects(base_phonemes, base_word, inflected_word, expected)
  it "#{base_word} -> #{inflected_word}" do
    pron = Pronunciation.new(base_phonemes.split)
    result = Inflect.derive(pron, base_word, inflected_word)
    actual = result&.phonemes&.join(" ")
    expect(actual).to eq(expected), "#{base_word} -> #{inflected_word}: got #{actual.inspect}, expected #{expected.inspect}"
  end
end

describe 'Inflect' do
  context 'inflection_of_base? (spelling suffix, for frequency inheritance)' do
    it 'recognizes list-headword plurals and -ing' do
      expect(Inflect.inflection_of_base?('waterbed', 'waterbeds')).to eq(true)
      expect(Inflect.inflection_of_base?('upsize', 'upsizing')).to eq(true)
      expect(Inflect.inflection_of_base?('cul-de-sac', 'cul-de-sacs')).to eq(true)
      expect(Inflect.inflection_of_base?('waterbed', 'water')).to eq(false)
    end

    it 'recognizes -ize / -ized (reverse: stem is morphological base of listed form)' do
      expect(Inflect.inflection_of_base?('regionalize', 'regionalized')).to eq(true)
      expect(Inflect.inflection_of_base?('sensationalize', 'sensationalized')).to eq(true)
    end

    it 'rejects base+es for silent-e bases (not annualizees)' do
      expect(Inflect.inflection_of_base?('annualize', 'annualizes')).to eq(true)
      expect(Inflect.inflection_of_base?('annualize', 'annualizees')).to eq(false)
    end

    it 'recognizes deadjectival -ly and -ful for lemma candidates' do
      expect(Inflect.inflection_of_base?('flawless', 'flawlessly')).to eq(true)
      expect(Inflect.inflection_of_base?('happy', 'happily')).to eq(true)
      expect(Inflect.inflection_of_base?('gentle', 'gently')).to eq(true)
      expect(Inflect.inflection_of_base?('delight', 'delightful')).to eq(true)
    end
  end

  context 'plural -s (voiceless final -> S)' do
    inflects "K AE1 T", "cat", "cats", "K AE1 T S"
    inflects "S T AA1 P", "stop", "stops", "S T AA1 P S"
  end

  context 'plural -s (voiced final -> Z)' do
    inflects "D AO1 G", "dog", "dogs", "D AO1 G Z"
    inflects "K AW1", "cow", "cows", "K AW1 Z"
    inflects "TH R AH1 P AH0 L", "throuple", "throuples", "TH R AH1 P AH0 L Z"
  end

  context 'plural -es (sibilant final -> IH0 Z)' do
    inflects "F AA1 K S", "fox", "foxes", "F AA1 K S IH0 Z"
    inflects "B R AH1 SH", "brush", "brushes", "B R AH1 SH IH0 Z"
  end

  context 'plural -ies (y -> ies)' do
    inflects "S K AY1", "sky", "skies", "S K AY1 Z"
  end

  context 'past -ed (voiceless final -> T)' do
    inflects "S T AA1 P", "stop", "stopped", "S T AA1 P T"
    inflects "W AO1 K", "walk", "walked", "W AO1 K T"
  end

  context 'past -ed (voiced final -> D)' do
    inflects "K AO1 L", "call", "called", "K AO1 L D"
    inflects "P L EY1", "play", "played", "P L EY1 D"
  end

  context 'past -ed (T/D final -> IH0 D)' do
    inflects "Y IY1 T", "yeet", "yeeted", "Y IY1 T IH0 D"
    inflects "N IY1 D", "need", "needed", "N IY1 D IH0 D"
  end

  context 'present participle -ing' do
    inflects "Y IY1 T", "yeet", "yeeting", "Y IY1 T IH0 NG"
    inflects "S T AA1 P", "stop", "stopping", "S T AA1 P IH0 NG"
    inflects "D AE1 N S", "dance", "dancing", "D AE1 N S IH0 NG"
  end

  context '3rd person -s' do
    inflects "Y IY1 T", "yeet", "yeets", "Y IY1 T S"
  end

  context 'comparative -er' do
    inflects "F AE1 S T", "fast", "faster", "F AE1 S T ER0"
  end

  context 'superlative -est' do
    inflects "F AE1 S T", "fast", "fastest", "F AE1 S T AH0 S T"
  end

  context 'edge cases' do
    it 'returns nil for empty pronunciation' do
      pron = Pronunciation.new([])
      expect(Inflect.derive(pron, "cat", "cats")).to be_nil
    end

    it 'returns nil for unrecognized suffix' do
      pron = Pronunciation.new("K AE1 T".split)
      expect(Inflect.derive(pron, "cat", "catlike")).to be_nil
    end
  end
end
