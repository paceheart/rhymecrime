# Unit tests for +semantically_promiscuous?+: the predicate that flags content-empty
# words ("could", "perhaps", "henceforth") whose relatedness short-circuits to "related
# to everything" in scoring / display. See the long-form comment in +utils_rhyme.rb+
# alongside +SEMANTICALLY_PROMISCUOUS_FILENAME+ for the curation policy.

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

# Sister predicate to +oughta_be_promiscuous+: function words and contractions
# ("the", "a", "you'll") that are valid English but make poor rhyme targets, so
# we delete them from +word_dict+ at build time. Curated in
# +unrhymable_stop_words.txt+, disjoint-in-spirit from the promiscuous list (see
# the long-form comment near +SEMANTICALLY_PROMISCUOUS_FILENAME+ in
# +utils_rhyme.rb+ for the why).
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
  # Derived forms of semantically promiscuous words ought to inherit promiscuity
  # via the +lemma()+ fallback in the predicate. +outs+ (lemma=out) survives
  # +stopword_inflection_scrub+ via its corpus attestation (Zipf > COMMON), so
  # it's still in +word_dict+ at runtime — and the runtime needs the predicate
  # to flag it so relatedness scoring short-circuits it as a function-word-like
  # candidate. +abouts+ used to be the canonical example here but it's now
  # tombstoned by +stopword_inflection_scrub+ (no WN entry, no rarity.csv row,
  # Zipf below COMMON), and a tombstoned word is absent from the lemma map so
  # the predicate's fallback can't reach +about+ from +abouts+ any more.
  oughta_be_promiscuous 'outs'
  oughta_be_unrhymable 'the' # different category from promiscuous: deleted from word_dict at build time
  ought_not_be_promiscuous 'cat'
  ought_not_be_promiscuous 'ass'
  ought_not_be_promiscuous 'assed'
end
