#
# related_rhymes — describes "for cue X (rhyme axis) and cue Y (related-to axis),
# return words that rhyme with X and are topically related to Y". Smallest of the
# three similar_rhymes_* describe blocks (1 example currently); split into its
# own file from similar_rhymes_spec.rb for symmetry with the SET_RELATED /
# PAIR_RELATED splits and to give parallel_rspec a third schedulable unit.
#

require_relative "similar_rhymes_support"

def related_rhymes?(input_rhyme, input_related, output)
  # Words that rhyme with input_rhyme and are related to input_related — is OUTPUT one of them?
  # e.g. 'please', 'cats', 'siamese'
  find_related_rhymes(input_rhyme, input_related).include?(output)
end

def related_rhymes_oughta_contain(input_rhyme, input_related, output, not_working_reason: nil)
  test_name = "related_rhymes #{input_rhyme} + #{input_related} -> #{output}"
  it test_name do
    skip_if_not_working(not_working_reason)
    expect(related_rhymes?(input_rhyme, input_related, output)).to eql(true), "'#{output}' (#{debug_info(output)}) oughta be one of the words that rhyme with '#{input_rhyme}' (#{debug_info(input_rhyme)}) and is related to '#{input_related}'"
  end
end

def related_rhymes_ought_not_contain(input_rhyme, input_related, output, not_working_reason: nil)
  test_name = "related_rhymes #{input_rhyme} + #{input_related} !-> #{output}"
  it test_name do
    skip_if_not_working(not_working_reason)
    expect(related_rhymes?(input_rhyme, input_related, output)).to eql(true), "'#{output}' (#{debug_info(output)}) ought not one of the words that rhyme with '#{input_rhyme}' (#{debug_info(input_rhyme)}) and is related to '#{input_related}'"
  end
end

describe 'RELATED_RHYMES' do

  context 'examples from the documentation' do
    related_rhymes_oughta_contain 'please', 'cats', 'siamese'
  end

end
