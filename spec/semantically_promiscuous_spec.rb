# Unit tests for semantically_promiscuous?: the predicate that flags content-empty
# words ("could", "perhaps", "henceforth") whose relatedness short-circuits to "related
# to everything" in scoring / display. See the long-form comment in prefix_clusters.rb
# alongside SEMANTICALLY_PROMISCUOUS_FILENAME for the curation policy.

def oughta_be_promiscuous(word)
  it "promiscuous: #{word.inspect}" do
    expect(semantically_promiscuous?(word)).to(
      be(true),
      "expected #{word.inspect} to be semantically promiscuous, but it isn't"
    )
  end
end

def ought_not_be_promiscuous(word)
  it "not promiscuous: #{word.inspect}" do
    expect(semantically_promiscuous?(word)).to(
      be(false),
      "expected #{word.inspect} not to be semantically promiscuous, but it is"
    )
  end
end

# Sister predicate to oughta_be_promiscuous: function words and contractions
# ("the", "a", "you'll") that are valid English but make poor rhyme targets, so
# we delete them from word_dict at build time. Curated in
# unrhymable_stop_words.txt, disjoint-in-spirit from the promiscuous list (see
# the long-form comment near SEMANTICALLY_PROMISCUOUS_FILENAME in
# prefix_clusters.rb for the why).
def oughta_be_unrhymable(word)
  it "unrhymable: #{word.inspect}" do
    expect(unrhymable_stop_word?(word)).to(
      be(true),
      "expected #{word.inspect} to be an unrhymable stop word, but it isn't"
    )
  end
end

describe 'semantically_promiscuous?' do
  oughta_be_promiscuous 'about'
  oughta_be_unrhymable 'the'
  ought_not_be_promiscuous 'cat'
  ought_not_be_promiscuous 'ass'
  ought_not_be_promiscuous 'assed'
end
