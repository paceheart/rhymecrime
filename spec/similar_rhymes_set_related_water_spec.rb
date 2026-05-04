#
# set_related — +water+ cue (20 examples). Split from +set_related_misc_spec.rb+
# alongside the other >=10-example cues so +parallel_rspec+ can fan them out.
# See +set_related_<cue>_spec.rb+ companions and +set_related_misc_spec.rb+.
#

require_relative "similar_rhymes_set_related_support"

describe 'SET_RELATED' do
  context 'water' do
    set_related_oughta_contain 'water', 'gush', 'flush'
    set_related_oughta_contain 'water', 'drink', 'sink'
    set_related_oughta_contain 'water', 'pee', 'sea'
    set_related_oughta_contain 'water', 'sky', 'supply'
    set_related_oughta_contain 'water', 'sprayed', 'wade'
    set_related_oughta_contain 'water', 'supplied', 'tide'
    set_related_oughta_contain 'water', 'dam', 'swam'
    set_related_oughta_contain 'water', 'slosh', 'wash'
    set_related_oughta_contain 'water', 'humidity', 'turbidity'
    set_related_oughta_contain 'water', 'bay', 'spray'
    set_related_oughta_contain 'water', 'steam', 'stream'
    set_related_oughta_contain 'water', 'eau', 'flow', not_working_reason: "eau rare"
    set_related_oughta_contain 'water', 'sweat', 'wet'
    set_related_oughta_contain 'water', 'cool', 'pool'
    set_related_oughta_contain 'water', 'drain', 'rain'
    set_related_ought_not_contain 'water', 'sea', 'cod'
    set_related_oughta_contain 'water', 'blood', 'flood'
    set_related_ought_not_contain 'water', 'marine', 'saline' # stress mismatch
    set_related_oughta_contain_base_form 'water', 'dip', 'sip'
    set_related_ought_not_contain 'water', 'flour', 'flower'
  end
end
