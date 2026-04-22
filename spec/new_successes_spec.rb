#
# rhymes
#

def oughta_rhyme(word1, word2, not_working_message: nil)
  oughta_rhyme_one_way(word1, word2, not_working_message: not_working_message)
  oughta_rhyme_one_way(word2, word1, not_working_message: not_working_message)
end

def oughta_rhyme_one_way(word1, word2, not_working_message: nil)
  test_name = "'#{word1}' oughta have '#{word2}' in its list of rhymes"
  it test_name do
    skip_if_not_working(not_working_message)
    rhymes = find_preferred_rhyming_words(word1)
    # Accept any spelling variant of +word2+: the rhyme list only contains preferred forms,
    # so if the spec names a dispreferred variant (+spectre+ vs +specter+, +cord+ vs +chord+)
    # we still want the positive test to pass. The negative matcher stays literal so tests
    # like +ought_not_rhyme_one_way 'goner', 'honour'+ (which specifically assert the
    # dispreferred form is filtered) still do what they say.
    word2_forms = all_forms(word2)
    matched = (rhymes & word2_forms).any?
    expect(matched).to eql(true), "'#{word1}' (#{debug_info(word1)}) oughta include '#{word2}' ((#{debug_info(word2)}) in its list of rhymes, but instead it only rhymes with #{rhymes}"
  end
end

def ought_not_rhyme(word1, word2, not_working_message: nil)
  ought_not_rhyme_one_way(word1, word2, not_working_message: not_working_message)
  ought_not_rhyme_one_way(word2, word1, not_working_message: not_working_message)
end

def ought_not_rhyme_one_way(word1, word2, not_working_message: nil)
  test_name = "'#{word1}' ought not have '#{word2}' in its list of rhymes"
  it test_name do
    skip_if_not_working(not_working_message)
    expect(find_preferred_rhyming_words(word1).include?(word2)).to eql(false), "'#{word1}' (#{debug_info(word1)}) ought not include '#{word2}' (#{debug_info(word2)}) as a rhyme, but it does, and it also rhymes with #{find_preferred_rhyming_words(word1)}"
  end
end

def could_go_either_way(word1, word2, not_working_message: nil)
end

describe 'RHYMES' do

  context 'new successes' do
    ought_not_rhyme 'biopic', 'myopic'
    oughta_rhyme 'eyeball', 'highball'
    ought_not_rhyme 'adherence', 'adherents'
    oughta_rhyme 'bay', 'lei'
    ought_not_rhyme 'find', 'upwind'
    oughta_rhyme 'unowned', 'zoned'
    oughta_rhyme 'owned', 'rezoned'
    oughta_rhyme 'unowned', 'rezoned'
      oughta_rhyme 'percussion', 'repercussion'
      oughta_rhyme 'lied', 'relied'
      oughta_rhyme 'corded', 'recorded'
      oughta_rhyme 'tween', 'between'
    oughta_rhyme 'troll', 'patrol' #
    oughta_rhyme 'troll', 'control' #
    oughta_rhyme 'jar', 'ajar'
    oughta_rhyme 'nest', 'finessed'
    oughta_rhyme 'keto', 'mosquito'
    oughta_rhyme 'cord', 'record'
    oughta_rhyme 'chord', 'record'
    oughta_rhyme 'hemiola', 'viola'
    oughta_rhyme 'mandolin', 'violin'
    oughta_rhyme 'serve', 'deserve'
    oughta_rhyme 'served', 'deserved'
    oughta_rhyme 'served', 'undeserved'
    oughta_rhyme 'coital', 'colloidal'
    oughta_rhyme 'whiteout', 'hideout'
    oughta_rhyme "hits", "it's"
    oughta_rhyme "f'd", "bereft"
    ought_not_rhyme_one_way 'flaws', 'inlaws'
    oughta_rhyme 'okey-dokey', 'hokey'
    oughta_rhyme_one_way 'okeydokey', 'hokey'
    oughta_rhyme 'papier-mache', 'way'
    oughta_rhyme 'tutti-frutti', 'booty'
    oughta_rhyme 'roly-poly', 'holy'
    oughta_rhyme 'hara-kiri', 'weary'
    oughta_rhyme 'so-so', 'mafioso'
    oughta_rhyme 'pet', 'nyet'
    oughta_rhyme 'array', 'hurray'
    oughta_rhyme 'array', 'moray'
    oughta_rhyme 'informant', 'torment'
    oughta_rhyme "winnin'", "linen"
    oughta_rhyme "failin'", "wailin'"
    oughta_rhyme "poopin'", "scoopin'"
    oughta_rhyme 'greediest', 'devious'
    oughta_rhyme 'fence', 'wince'
    oughta_rhyme 'vintage', 'percentage'
    oughta_rhyme 'girl', 'world'
    oughta_rhyme 'poor', 'core'
    oughta_rhyme 'cajun', 'occasion'
    ought_not_rhyme 'bocce', 'mocha'
    ought_not_rhyme 'url', 'curl'
    oughta_rhyme 'freer', 'seer'
    ought_not_rhyme 'seer', 'beer'
    oughta_rhyme 'latex', 'paychecks'
    oughta_rhyme 'pitiful', 'biddable'
    oughta_rhyme 'cello', 'concerto'
    oughta_rhyme 'symphony', 'timpani'
      oughta_rhyme 'cello', 'hell no'
      oughta_rhyme 'bounty', 'brown tea'
    oughta_rhyme 'eau', 'flow'
    ought_not_rhyme 'marine', 'saline'
    oughta_rhyme 'heinz', 'maligns'
  end

end
