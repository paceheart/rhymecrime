# Desired lexical POS per lemma (see dict build / part_of_speech.json policy).
# Requires dict/generated/part_of_speech.json from: cd dict && ruby dict.rb
#
# Table: each row is the word, then POS abbreviations — noun, verb, adj, adv (output keys
# match Kaikki strings stored in part_of_speech.json).

PART_OF_SPEECH_EXPECTED = [
  %w[run verb noun],
  %w[apple noun],
  %w[happy adj],
  %w[taboo noun adj],
  %w[khaki noun adj],
  %w[impromptu adj],
  %w[mocha noun adj],
  %w[free verb adj],
  %w[drawer noun],
  %w[chest noun],
  %w[eat verb],
  %w[kitten noun],
  %w[concatenate verb],
  %w[withdraw verb],
  %w[withdrawal noun],
  %w[fox noun],
  %w[foxy adj],
  %w[foxily adv],
  %w[foxiness noun],
  %w[very adv adj], # the very (adj) best
  %w[downtown noun],
  %w[central adj],
  %w[centralize verb],
  %w[centralization noun],
  %w[gobble verb],
  %w[pirate verb noun],
  %w[ballet noun],
].freeze

describe "PART OF SPEECH" do
  def tags(w)
    part_of_speech_tags(w)
  end

  it "returns empty array for unknown lemmas" do
    expect(tags("zzzznotawordzzzz")).to eq([])
  end

  PART_OF_SPEECH_EXPECTED.each do |row|
    word = row[0]
    expected = row[1..]
    it "#{word} is #{expected.join(', ')}" do
      expect(tags(word)).to match_array(expected)
    end
  end
end
