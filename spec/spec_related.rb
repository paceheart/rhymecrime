require_relative 'test_utils'

#
# related
#

def oughta_be_related(word1, word2, is_working=true)
  if(is_working)
    test_name = "'#{word1}' oughta be related to '#{word2}'"
    it test_name do
      expect(related?(word1, word2, false)).to eql(true), "'#{word1}' is #{similarity(word1, word2).round} related to '#{word2}', which is under the similarity threshold of #{similarity_threshold()} (#{debug_info(word1)} / #{debug_info(word2)})"
    end
  else # NOT_WORKING
    if TEST_FOR_SURPRISING_SUCCESSES
      ought_not_be_related(word1, word2, true)
    end
  end
end
  
def ought_not_be_related(word1, word2, is_working=true)
  if(is_working)
    test_name = "'#{word1}' ought not be related to '#{word2}'"
    it test_name do
      expect(related?(word1, word2, false)).to eql(false), "'#{word1}' is #{similarity(word1, word2).round} related to '#{word2}', which meets the similarity threshold of #{similarity_threshold()} (#{debug_info(word1)} / #{debug_info(word2)})"
    end
  else # NOT_WORKING
    if TEST_FOR_SURPRISING_SUCCESSES
      oughta_be_related(word1, word2, true)
    end
  end
end

def related_words_ought_not_include(word1, word2, is_working=true)
  if(is_working)
    test_name = "'Words related to #{word1}' ought not include '#{word2}'"
    related_words = find_related_words(word1, false)
    it test_name do
      expect(related_words.include?(word2)).to eql(false), "Words related to '#{word1}' ought not include '#{word2}', but they do: #{related_words}"
    end
  else # NOT_WORKING
    if TEST_FOR_SURPRISING_SUCCESSES
      expect(related_words.include?(word2)).to eql(true), "Words related to '#{word1}' oughta include '#{word2}', but they do not: #{related_words}"
    end
  end
end

describe 'RELATED' do
  
  context 'reflexivity' do
    related_words_ought_not_include 'death', 'death'
  end

  context 'slurs are forbidden' do
    related_words_ought_not_include 'gypsy', 'romanian'
    related_words_ought_not_include 'romanian', 'gypsy'
    related_words_ought_not_include 'gypsies', 'romanian'
    related_words_ought_not_include 'romanian', 'gypsies'
  end

  load_and_define_relatedness_test_cases

end
