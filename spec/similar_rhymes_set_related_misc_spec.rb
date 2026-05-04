#
# set_related — leftover bucket for cues with <10 examples and the cross-cue
# +context+s (stop words / prefix / root lemmas / stress mismatch / no spelling
# variants / non-binary). The five hottest cues live in their own files
# (+set_related_<pirate|music|water|crime|cat>_spec.rb+) so +parallel_rspec+
# can fan them out; this file is everything else under +describe 'SET_RELATED'+.
#
# Renamed from +similar_rhymes_set_related_spec.rb+ when the per-cue split
# happened (see +similar_rhymes_set_related_support.rb+ for the shared
# +set_related_oughta_contain+ DSL + helpers).
#

require_relative "similar_rhymes_set_related_support"

describe 'SET_RELATED' do

  context 'set_related works at all' do
    set_related_works 'death'
  end

  context 'examples from the documentation' do
    set_related_oughta_contain 'death', 'bled', 'dread'
    set_related_oughta_contain 'death', 'bled', 'dead'
    set_related_oughta_contain 'death', 'dead', 'dread'
  end

  context 'stop words' do
    # we don't want tuples with _only_ stop words, but it's okay if there are also go-words. set_related_ought_not_contain 'pirate', 'of', 'above'
    set_related_ought_not_contain 'pirate', 'other', 'another'
  end

  context 'halloween' do
    set_related_oughta_contain 'halloween', 'celebration', 'decoration'
    set_related_oughta_contain 'halloween', 'cider', 'spider'
    set_related_oughta_contain 'halloween', 'sheet', 'treat'
    set_related_oughta_contain 'halloween', 'bat', 'cat'
    set_related_oughta_contain 'halloween', 'fairy', 'scary'
    set_related_oughta_contain 'halloween', 'fright', 'night'
    set_related_ought_not_contain 'halloween', 'lindsay', 'lindsey'
    set_related_ought_not_contain 'halloween', 'cider', 'snyder'
    set_related_ought_not_contain 'halloween', 'day', 'ira'
  end

  context 'clumsy' do
    set_related_oughta_contain_base_form 'clumsy', 'bumble', 'fumble'
    set_related_oughta_contain 'clumsy', 'drop', 'flop'
  end

  context 'invoke' do
    set_related_oughta_contain 'invoke', 'dares', 'prayers', not_working_reason: "TODO: investigate"
    set_related_oughta_contain 'invoke', 'declare', 'prayer'
  end

  context 'prayers' do
    set_related_oughta_contain 'prayers', 'addressed', 'blessed', not_working_reason: "predictor gap: similarity=0 for prayers/addressed (see related_spec prereq)"
    set_related_oughta_contain 'prayers', 'blessed', 'request'
    set_related_oughta_contain 'prayers', 'appeal', 'kneel'
    set_related_oughta_contain_base_form 'prayers', 'recite', 'rite', not_working_reason: "predictor now relates prayers/rite (related_spec prereq passes), but set_related doesn't surface this tuple"
    set_related_oughta_contain 'prayers', 'exhortations', 'meditations'
    set_related_oughta_contain 'prayers', 'humble', 'mumble'
    set_related_oughta_contain 'prayers', 'jew', 'pew'
    set_related_oughta_contain 'prayers', 'knee', 'plea'
    set_related_oughta_contain_base_form 'prayers', 'heal', 'kneel'
  end

  context 'carbon' do
    set_related_oughta_contain 'carbon', 'sink', 'zinc'
    set_related_ought_not_contain 'carbon', 'cycling', 'recycling' # filter out rich rhymes
    set_related_oughta_contain 'carbon', 'polyester', 'sequester' # or 'ester' instead of 'polyester'
    set_related_oughta_contain 'carbon', 'extract', 'react'
  end

  context 'bread' do
    set_related_oughta_contain 'bread', 'feast', 'yeast'
  end

  context 'pasta' do
    set_related_oughta_contain 'pasta', 'clam', 'ham'
    set_related_oughta_contain 'pasta', 'dish', 'fish'
    set_related_oughta_contain 'pasta', 'fork', 'pork'
    set_related_oughta_contain 'pasta', 'italian', 'scallion'
    set_related_oughta_contain 'pasta', 'paste', 'taste'
  end

  context 'magic' do
    set_related_oughta_contain 'magic', 'chants', 'trance'
    set_related_ought_not_contain 'magic', 'enchanted', 'disenchanted' # rich rhyme
  end

  context 'medical' do
    set_related_oughta_contain 'medical', 'disease', 'expertise'
    set_related_oughta_contain 'medical', 'fees', 'ccs'
    set_related_oughta_contain 'medicine', 'disease', 'expertise'
    set_related_oughta_contain 'medicine', 'fees', 'ccs'
  end

  context 'football' do
    set_related_oughta_contain 'football', 'yeet', 'incomplete'
  end

  context 'exploration' do
    set_related_oughta_contain 'exploration', 'knapsack', 'backtrack', not_working_reason: "predictor gap: similarity=0 for exploration/knapsack (see related_spec prereq)"
    set_related_oughta_contain 'exploration', 'pack', 'track'
  end

  context 'stress mismatch' do
    # relax the stress:
    set_related_ought_not_contain 'halloween', 'broom', 'costume'
    set_related_ought_not_contain 'music', 'oboe', 'piano'
    set_related_ought_not_contain 'music', 'cello', 'solo'
    set_related_ought_not_contain 'music', 'solo', 'concerto'
  end

  context 'math' do
    set_related_oughta_contain 'math', 'inferred', 'nerd'
  end

  context 'no spelling variants' do
    set_related_ought_not_contain 'funeral', 'eulogize', 'eulogise'
    set_related_ought_not_contain 'courtroom', 'honor', 'honour'
  end

  context 'non-binary' do
    set_related_oughta_contain 'music', 'cello', 'concerto', not_working_reason: "genderfluid"
    set_related_oughta_contain 'music', 'symphony', 'timpani', not_working_reason: "genderfluid"
  end
end
