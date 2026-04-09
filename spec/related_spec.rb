require_relative 'test_utils'

#
# related
#

def oughta_be_related(word1, word2, not_working_message: nil)
  test_name = "'#{word1}' oughta be related to '#{word2}'"
  it test_name do
    skip_if_not_working(not_working_message)
    sim = similarity(word1, word2).round
    expect(related?(word1, word2, false)).to eql(true), "'#{word1}' / '#{word2}': expected related but related? was false. similarity=#{sim} (Numberbatch+ConceptNet centiles, threshold #{similarity_threshold()}); gloss/sense-vector/USF paths can still pass when sim is lower. #{debug_info(word1)} / #{debug_info(word2)}"
  end
end
  
def ought_not_be_related(word1, word2, not_working_message: nil)
  test_name = "'#{word1}' ought not be related to '#{word2}'"
  it test_name do
    skip_if_not_working(not_working_message)
    sim = similarity(word1, word2).round
    expect(related?(word1, word2, false)).to eql(false), "'#{word1}' / '#{word2}': expected unrelated but related? was true. similarity=#{sim} (threshold #{similarity_threshold()}). If sim is below threshold, a rescue path matched (WordNet gloss containment, sense vectors, or USF two-hop). #{debug_info(word1)} / #{debug_info(word2)}"
  end
end

def related_words_ought_not_include(word1, word2, not_working_message: nil)
  test_name = "'Words related to #{word1}' ought not include '#{word2}'"
  it test_name do
    skip_if_not_working(not_working_message)
    related_words = find_related_words(word1, false)
    expect(related_words.include?(word2)).to eql(false), "Words related to '#{word1}' ought not include '#{word2}', but they do: #{related_words}"
  end
end

describe 'RELATED' do
  
  load_and_define_relatedness_test_cases

  context 'reflexivity' do
    related_words_ought_not_include 'death', 'death'
  end

  context 'slurs are forbidden' do
    related_words_ought_not_include 'gypsy', 'romanian'
    related_words_ought_not_include 'gypsies', 'romanian'
    related_words_ought_not_include 'romanian', 'gypsy'
    related_words_ought_not_include 'romanian', 'gypsies'
  end
end
