# Desired lexical POS per lemma (see dict build / part_of_speech.json policy).
# Requires generated/part_of_speech.json from: ./bin/dict-build
#
# Table: each row is either
#   - an Array: word, then POS abbreviations (noun, verb, adj, adv — keys match Kaikki), or
#   - a Hash: :word, :expect (array of tags), optional :not_working_message (truthy → skip with that reason; use true for "not working").

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
  { word: "foxiness", expect: %w[noun], not_working_message: true },
  %w[very adv adj], # the very (adj) best
  { word: "downtown", expect: %w[noun adj], not_working_message: true },
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
  %w[jawbreaker noun],
  %w[decide verb],
  %w[throuple noun],
  %w[blog noun verb],
  %w[wiggle verb noun],
  %w[jog verb noun],
  %w[jogger noun],
  %w[dance noun verb],
  %w[ant noun],
  { word: "ants", expect: %w[noun], not_working_message: true },
  %w[magenta adj noun],
  %w[yellow adj noun verb],
  %w[margin noun],
  %w[marginal adj],
  %w[quickly adv],
  { word: "yeet", expect: %w[verb], not_working_message: true },
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
    word, expected, not_working_message =
      if row.is_a?(Hash)
        [row.fetch(:word), row.fetch(:expect), row[:not_working_message]]
      else
        [row[0], row[1..], nil]
      end
    it "#{word} is #{expected.join(', ')}" do
      skip_if_not_working(not_working_message)
      expect(tags(word)).to match_array(expected)
    end
  end
end
