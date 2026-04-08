# Desired lexical POS per lemma (see dict build / part_of_speech.json policy).
# Requires generated/part_of_speech.json from: cd dict && ruby dict.rb
#
# Table: each row is the word, then POS abbreviations — noun, verb, adj, adv (output keys
# match Kaikki strings stored in part_of_speech.json), with an optional final NOT_WORKING.

PART_OF_SPEECH_EXPECTED = [
  %w[run verb noun],
  %w[apple noun],
  %w[happy adj],
  %w[sad adj],
  %w[taboo noun adj],
  %w[khaki noun adj],
  %w[impromptu adj],
  %w[mocha noun],
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
  %w[foxiness noun NOT_WORKING],
  %w[very adv adj], # the very (adj) best
  %w[downtown noun adj NOT_WORKING],
  %w[central adj],
  %w[centralize verb],
  %w[centralization noun],
  %w[gobble verb],
  %w[pirate verb noun],
  %w[ballet noun],
  %w[analyze verb],
  %w[analysis noun],
  %w[jaw noun verb],
  %w[breaker noun],
  %w[jawbreaker noun NOT_WORKING],
  %w[decide verb],
  %w[throuple noun],
  %w[blog noun verb],
  %w[wiggle verb noun],
  %w[jog verb noun],
  %w[jogger noun],
  %w[dance noun verb],
  %w[ant noun],
  %w[ants noun NOT_WORKING],
  %w[magenta adj noun],
  %w[yellow adj noun verb],
  %w[margin noun],
  %w[marginal adj],
  %w[quickly adv],
  %w[yeet verb NOT_WORKING],
  %w[twerk verb]
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
    not_working = (expected[-1] == "NOT_WORKING")
    expected = expected[0...-1] if not_working # remove the NOT_WORKING
    it "#{word} is #{expected.join(', ')}" do
      skip "marked NOT_WORKING in PART_OF_SPEECH_EXPECTED" if not_working
      expect(tags(word)).to match_array(expected)
    end
  end
end
