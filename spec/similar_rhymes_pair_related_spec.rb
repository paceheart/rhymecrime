#
# pair_related — describes "for cues X and Y, what cross-rhyming pairs of related
# words should appear?". Mid-sized of the three similar_rhymes_* describe blocks
# (~50 examples, ~50s pre-LocalStore-warmup); split into its own file from
# similar_rhymes_spec.rb so parallel_rspec can run it concurrently with the
# larger SET_RELATED file.
#

require_relative "similar_rhymes_support"

def pair_related_score_summary(input1, input2, pair1, pair2)
  s1 = similarity(input1, pair1).to_i
  s2 = similarity(input2, pair2).to_i
  "scores #{input1}->#{pair1}=#{s1}, #{input2}->#{pair2}=#{s2}, min=#{[s1, s2].min}"
end

def pair_related_word_debug(input, output)
  "#{debug_info(output)}; #{input}->#{output} similarity=#{similarity(input, output).to_i}"
end

def summarize_pairs_for_failure(input1, input2, pairs, *expected_words)
  summary = summarize_for_failure("pair", pairs, expected_words)
  return summary if pairs.nil? || pairs.empty?

  expected = expected_words.compact.uniq
  involving = pairs.select { |entry| (entry & expected).any? }
  sample = (involving.any? ? involving.first(SIMILAR_SPEC_INVOLVING_LIMIT) : pairs.first(SIMILAR_SPEC_HEAD_LIMIT))
  scored = sample.map do |pair1, pair2|
    "#{pair1.inspect} / #{pair2.inspect} (#{pair_related_score_summary(input1, input2, pair1, pair2)})"
  end
  "#{summary}; sampled #{scored.size} with similarity: #{scored.join('; ')}"
end

$dump_id = 0
def pair_related_contains?(input1, input2, output1, output2)
  # Generate pair_related rhymes for INPUT1 / INPUT2. Is one of them "OUTPUT1 / OUTPUT2"?
  #dumpfile = "/tmp/stackprof-cpu-rhymecrime-" + $dump_id.to_s() + ".dump"
  result = false
  #StackProf.run(mode: :cpu, out: dumpfile) do
  #  $dump_id += 1
    target_pair = [output1, output2]
    result = find_rhyming_pairs(input1, input2).include? target_pair
  #end
  return result
end

def pair_related_base_forms(word)
  forms = Set[word]
  forms.add(lemma(word)) if lemma(word)
  forms.merge(rhyming_tuple_word_bases(word))
  Inflect.raw_candidate_bases_for_inflected(word).each { |base| forms.add(base) }
  forms.reject { |form| form.nil? || form.empty? }
end

def pair_related_base_form_match?(actual_word, expected_word)
  !(pair_related_base_forms(actual_word) & pair_related_base_forms(expected_word)).empty?
end

def pair_related_oughta_contain(input1, input2, output1, output2, not_working_reason: nil)
  test_name = "pair_related: #{input1} / #{input2} -> #{output1} / #{output2}"
  it test_name do
    skip_if_not_working(not_working_reason)
    pairs = find_rhyming_pairs(input1, input2)
    target_pair = [output1, output2]
    expect(pairs.include?(target_pair)).to eql(true), "Pair-related rhymes for '#{input1}' / '#{input2}' oughta include '#{output1}' (#{pair_related_word_debug(input1, output1)}) / '#{output2}' (#{pair_related_word_debug(input2, output2)}) [#{pair_related_score_summary(input1, input2, output1, output2)}], but #{summarize_pairs_for_failure(input1, input2, pairs, output1, output2)}"
  end
end

def pair_related_oughta_contain_base_form(input1, input2, output1, output2, not_working_reason: nil)
  test_name = "pair_related: #{input1} / #{input2} -> base forms of #{output1} / #{output2}"
  it test_name do
    skip_if_not_working(not_working_reason)
    pairs = find_rhyming_pairs(input1, input2)
    matching_pairs = pairs.select do |pair1, pair2|
      pair_related_base_form_match?(pair1, output1) &&
        pair_related_base_form_match?(pair2, output2)
    end
    expect(matching_pairs.empty?).to eql(false), "Pair-related rhymes for '#{input1}' / '#{input2}' oughta include a base-form match for '#{output1}' (#{pair_related_word_debug(input1, output1)}) / '#{output2}' (#{pair_related_word_debug(input2, output2)}) [#{pair_related_score_summary(input1, input2, output1, output2)}], but #{summarize_pairs_for_failure(input1, input2, pairs, output1, output2)}"
  end
end

def pair_related_ought_not_contain(input1, input2, output1, output2, not_working_reason: nil)
  test_name = "pair_related: #{input1} / #{input2} !-> #{output1} / #{output2}"
  it test_name do
    skip_if_not_working(not_working_reason)
    expect(pair_related_contains?(input1, input2, output1, output2)).to eql(false), "Pair-related rhymes for '#{input1}' / '#{input2}' ought not include '#{output1}' / '#{output2}'"
  end
end

describe 'PAIR_RELATED' do
  
  context 'examples from the old documentation' do
    pair_related_oughta_contain_base_form 'crime', 'heaven', 'confessed', 'blessed' # @todo update documentation
  end
  
  context 'examples from the documentation' do
    pair_related_oughta_contain 'crime', 'heaven', 'fraud', 'god' # @todo update documentation
  end
  
  context 'interactive fiction' do
    pair_related_oughta_contain_base_form 'interactive', 'fiction', 'exciting', 'writing'
  end

  context 'food evil' do
    context 'stop words' do
      # in pair_related, we require both to be go-words, otherwise
      # stop words will dominate the cross product
      pair_related_ought_not_contain 'food', 'evil', 'dill', 'will'
      pair_related_ought_not_contain 'food', 'evil', "i'll", "revile"
    end
    pair_related_oughta_contain 'food', 'evil', 'chewed', 'rude'
    pair_related_oughta_contain 'food', 'evil', 'cuisine', 'mean'
    pair_related_oughta_contain 'food', 'evil', 'feed', 'greed'
    pair_related_oughta_contain 'food', 'evil', 'grain', 'pain'
    pair_related_oughta_contain 'food', 'evil', 'grain', 'bane'
    pair_related_oughta_contain 'food', 'evil', 'rice', 'vice'
    pair_related_oughta_contain 'food', 'evil', 'vegetarian', 'totalitarian', not_working_reason: "evil->totalitarian score is 0 under current relatedness data"
    pair_related_oughta_contain 'food', 'evil', 'dinner', 'sinner'
    pair_related_oughta_contain 'food', 'evil', 'cake', 'rake'
    pair_related_ought_not_contain 'food', 'evil', 'mushroom', 'doom' # stress mismatch
    pair_related_ought_not_contain 'food', 'evil', 'chips', 'apocalypse' # stress mismatch
    pair_related_oughta_contain 'food', 'evil', 'seder', 'invader', not_working_reason: "min score 67 falls below the tightened pair_related threshold for this broad query"
    pair_related_oughta_contain 'food', 'evil', 'sachertorte', 'voldemort', not_working_reason: "would be cool, but a big stretch"
    pair_related_oughta_contain 'food', 'evil', 'bread', 'undead'
    pair_related_oughta_contain 'food', 'evil', 'heinz', 'maligns'
    pair_related_oughta_contain 'food', 'evil', 'served', 'undeserved'
    pair_related_oughta_contain 'food', 'evil', 'sanitation', 'temptation' # identical rime
    pair_related_ought_not_contain 'food', 'evil', 'healthy', 'unhealthy'
    pair_related_oughta_contain 'food', 'evil', 'contamination', 'condemnation'
    pair_related_oughta_contain 'food', 'evil', 'savory', 'slavery'
    pair_related_ought_not_contain 'food', 'evil', 'savoury', 'slavery'
    pair_related_oughta_contain 'food', 'evil', 'crumb', 'scum'
    pair_related_oughta_contain 'food', 'evil', 'organic', 'satanic'
    pair_related_oughta_contain 'food', 'evil', 'starvation', 'abomination'
    pair_related_oughta_contain 'food', 'evil', 'wine', 'malign'
    pair_related_oughta_contain 'food', 'evil', 'waiter', 'traitor'
    pair_related_oughta_contain 'food', 'evil', 'wheat', 'deceit'
    pair_related_oughta_contain 'food', 'evil', 'dessert', 'hurt'
    pair_related_ought_not_contain 'food', 'evil', 'produce', 'abuse', not_working_reason: "We'd have to enrich the relatedness to be to a word sense, not just a word, to distinguish between PRO-duce (food) and pro-DUCE (make)"
  end

  context 'food dark' do
    it "keeps pair_related output below the display cap" do
      expect(find_rhyming_pairs('food', 'dark').length).to be <= PAIR_RELATED_MAX_PAIRS
    end

    pair_related_oughta_contain 'food', 'dark', 'turkey', 'murky'
    pair_related_oughta_contain 'food', 'dark', 'veggie', 'edgy'
    pair_related_oughta_contain 'food', 'dark', 'consume', 'gloom'
    pair_related_oughta_contain 'food', 'dark', 'buffet', 'gray'
    pair_related_oughta_contain 'food', 'dark', 'crab', 'drab'
    pair_related_oughta_contain 'food', 'dark', 'crustacean', 'illumination'
    pair_related_oughta_contain 'food', 'dark', 'hydration', 'illumination'
    pair_related_oughta_contain 'food', 'dark', 'metabolic', 'melancholic'
    pair_related_oughta_contain 'food', 'dark', 'ration', 'ashen'
    pair_related_oughta_contain 'food', 'dark', 'snack', 'black'
    pair_related_oughta_contain 'food', 'dark', 'cuisine', 'unseen'
    pair_related_oughta_contain 'food', 'dark', 'leek', 'bleak'
  end

  context 'sinister sister' do
    pair_related_oughta_contain 'sinister', 'sister', 'shady', 'lady'
  end

  context 'gay food' do
    pair_related_oughta_contain 'gay', 'food', 'bi', 'pie'
    pair_related_oughta_contain 'gay', 'food', 'pan', 'flan'
    pair_related_oughta_contain 'gay', 'food', 'trans', 'flans', not_working_reason: "it mistakes trans as the plural of tran instead of as short for transgender"
  end

  context 'fashion music' do
    pair_related_oughta_contain 'fashion', 'music', 'avant-garde', 'bard'
  end
end
