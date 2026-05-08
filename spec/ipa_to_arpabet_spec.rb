# encoding: utf-8
require "rhymecrime/build/ipa_to_arpabet"

def converts(ipa, expected)
  it "converts #{ipa}" do
    result = IpaToArpabet.convert(ipa)
    actual = result&.join(" ")
    expect(actual).to eq(expected), "#{ipa} => #{actual}, expected #{expected}"
  end
end

describe 'IpaToArpabet' do
  context 'monosyllables' do
    converts "/miːm/",  "M IY1 M"
    converts "/baɪ/",   "B AY1"
  end

  context 'primary stress' do
    converts "/ˈsɛlfi/",        "S EH1 L F IY0"
    converts "/ˈθɹʌp.əl/",      "TH R AH1 P AH0 L"
    converts "/ˈpælɪmpsɛst/",   "P AE1 L IH0 M P S EH0 S T"
    converts "/ˈkwɪŋkʌŋks/",    "K W IH1 NG K AH0 NG K S"
    converts "/əˈkɪdnə/",       "AH0 K IH1 D N AH0"
  end

  context 'secondary stress' do
    converts "/ˈhæʃˌtæɡ/",          "HH AE1 SH T AE2 G"
    converts "/ˈæk.səˌlɑ.təl/",     "AE1 K S AH0 L AA2 T AH0 L"
    converts "/ˌaɪ.soʊˈmɔɹ.fɪk/",  "AY2 S OW0 M AO1 R F IH0 K"
    converts "/ˌpɑliˈæmərəs/",      "P AA2 L IY0 AE1 M AH0 R AH0 S"
  end

  context 'affricates' do
    converts "/ɪˈmoʊd͡ʒi/",     "IH0 M OW1 JH IY0"
    converts "/tʃiːz/",          "CH IY1 Z"
  end

  context 'unstressed with medial stress' do
    converts "/dɪˈfɛnɪstɹeɪt/", "D IH0 F EH1 N IH0 S T R EY0 T"
  end

  context 'edge cases' do
    it 'returns nil for empty string' do
      expect(IpaToArpabet.convert("")).to be_nil
    end

    it 'returns nil for nil' do
      expect(IpaToArpabet.convert(nil)).to be_nil
    end
  end
end
