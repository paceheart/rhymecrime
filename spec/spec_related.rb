#
# related
#

def oughta_be_related(word1, word2, is_working=true)
  lang = 'en'
  if(is_working)
    test_name = "'#{word1}' oughta be related to '#{word2}'"
    it test_name do
      expect(related?(word1, word2, false, lang)).to eql(true), "'#{word1}' is #{percent_similarity(word1, word2)} related to '#{word2}', which is under the similarity threshold of #{percent_similarity_threshold()}"
    end
  else # NOT_WORKING
    if TEST_FOR_SURPRISING_SUCCESSES
      ought_not_be_related(word1, word2, true)
    end
  end
end
  
def ought_not_be_related(word1, word2, is_working=true)
  lang = 'en'
  if(is_working)
    test_name = "'#{word1}' ought not be related to '#{word2}'"
    it test_name do
      expect(related?(word1, word2, false, lang)).to eql(false), "'#{word1}' is #{percent_similarity(word1, word2)} related to '#{word2}', which meets the similarity threshold of #{percent_similarity_threshold()}"
    end
  else # NOT_WORKING
    if TEST_FOR_SURPRISING_SUCCESSES
      oughta_be_related(word1, word2, true)
    end
  end
end

def related_words_ought_not_include(word1, word2, is_working=true)
  lang = 'en'
  if(is_working)
    test_name = "'Words related to #{word1}' ought not include '#{word2}'"
    related_words = find_related_words(word1, false, lang)
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
  
  context 'basic' do
    oughta_be_related 'meow', 'cat'
    oughta_be_related 'grave', 'death'
    oughta_be_related 'tree', 'leaf'
    oughta_be_related 'tree', 'forest'
    oughta_be_related 'mow', 'lawn'
  end

  context 'reflexivity' do
    related_words_ought_not_include 'death', 'death'
  end

  context 'examples from the documentation' do
    oughta_be_related 'death', 'bled', NOT_WORKING
    oughta_be_related 'death', 'dead'
    oughta_be_related 'death', 'dread', NOT_WORKING
  end

  context 'slurs are forbidden' do
    related_words_ought_not_include 'gypsy', 'romanian'
    related_words_ought_not_include 'romanian', 'gypsy'
    related_words_ought_not_include 'gypsies', 'romanian'
    related_words_ought_not_include 'romanian', 'gypsies'
  end

  context 'trivial stop words ought not show up as related to anything' do
    ought_not_be_related 'food', 'the'
  end
  
  context 'pirate' do
    ought_not_be_related 'pirate', 'pew', NOT_WORKING
    oughta_be_related 'pirate', 'doubloons', NOT_WORKING
  end

  context 'halloween' do
    ought_not_be_related 'halloween', 'ira', NOT_WORKING
    ought_not_be_related 'halloween', 'lindsay'
    ought_not_be_related 'halloween', 'lindsey'
    ought_not_be_related 'halloween', 'nicki'
    ought_not_be_related 'halloween', 'nikki'
    ought_not_be_related 'halloween', 'pauline', NOT_WORKING
  end

  context 'morphological variants oughta be related, but not words that are merely orthographically similar' do
    oughta_be_related 'mow', 'mows'
    oughta_be_related 'mow', 'mowed'
    oughta_be_related 'mow', 'mower'
    oughta_be_related 'mow', 'mowing'
    ought_not_be_related 'mow', 'moll'
    ought_not_be_related 'mow', 'mosh'
    oughta_be_related 'tree', 'trees'
    oughta_be_related 'tree', 'treetop'
    oughta_be_related 'tree', 'treetops'
    ought_not_be_related 'tree', 'treece'
    ought_not_be_related 'tree', 'treese'
    ought_not_be_related 'tree', 'treesh'
  end
end

