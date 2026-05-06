#
# set_related — cat cue (12 examples). Smallest of the >=10-case per-cue
# splits; lives in its own file so parallel_rspec can fan it out alongside
# pirate / music / water / crime. See companions set_related_<cue>_spec.rb
# and set_related_misc_spec.rb.
#

require_relative "similar_rhymes_set_related_support"

describe 'SET_RELATED' do
  context 'cat' do
    set_related_oughta_contain 'cat', 'kitten', 'bitten'
    set_related_oughta_contain 'cat', 'kitten', 'mitten'
    set_related_oughta_contain 'cat', 'barn', 'yarn'
    set_related_oughta_contain 'cat', 'pet', 'vet'
    set_related_oughta_contain 'cat', 'hiss', 'piss'
    set_related_oughta_contain 'cat', 'muzzle', 'nuzzle'
    set_related_oughta_contain 'cat', 'fur', 'purr'
    set_related_oughta_contain 'cat', 'neighbor', 'saber'
    set_related_oughta_contain 'cat', 'meow', 'now'
    set_related_oughta_contain 'cat', 'arboreal', 'territorial'
    set_related_oughta_contain 'cat', 'beagle', 'seagull'
    set_related_oughta_contain 'cat', 'bird', 'purred'
  end
end
