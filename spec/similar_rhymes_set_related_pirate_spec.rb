#
# set_related — +pirate+ cue (56 examples; the single biggest bucket in the
# original +set_related+ describe). Split from +set_related_misc_spec.rb+
# (formerly +similar_rhymes_set_related_spec.rb+) so +parallel_rspec+ can run
# this cue on its own worker rather than serializing it behind the rest.
#
# Cues with <10 examples are bundled into +set_related_misc_spec.rb+; the
# >=10-case clubhouse is +pirate+ / +music+ / +water+ / +crime+ / +cat+, each
# in its own +set_related_<cue>_spec.rb+.
#

require_relative "similar_rhymes_set_related_support"

describe 'SET_RELATED' do
  context 'pirate' do
    set_related_oughta_contain 'pirate', 'cache', 'lash'
    set_related_oughta_contain 'pirate', 'cove', 'trove'
    set_related_oughta_contain 'pirate', 'handsome', 'ransom'
    set_related_oughta_contain 'pirate', 'french', 'wench'
    set_related_oughta_contain 'pirate', 'gang', 'hang'
    set_related_oughta_contain 'pirate', 'bold', 'gold'
    set_related_oughta_contain 'pirate', 'peg', 'leg'
    set_related_oughta_contain 'pirate', 'daring', 'swearing'
    set_related_oughta_contain 'pirate', 'hacker', 'cracker' # a different kind of pirate
    set_related_oughta_contain 'pirate', 'sea', 'dvd', not_working_reason: "dvd rare" # two different kinds of pirate
    set_related_oughta_contain 'pirate', 'buccaneer', 'peer-to-peer' # two different kinds of pirate
    set_related_oughta_contain 'pirate', 'buccaneer', 'commandeer'
    set_related_oughta_contain 'pirate', 'buccaneer', 'mutineer'
    set_related_oughta_contain 'pirate', 'crew', 'tattoo'
    set_related_oughta_contain 'pirate', 'reef', 'thief'
    set_related_oughta_contain 'pirate', 'coast', 'ghost'
    set_related_oughta_contain 'pirate', 'loot', 'pursuit'
    set_related_ought_not_contain 'pirate', 'eyes', 'seas' # via two pronunciations of 'reprise'
    set_related_oughta_contain 'pirate', 'marauding', 'plotting'
    set_related_oughta_contain 'pirate', 'seagull', 'illegal'
    set_related_oughta_contain 'pirate', 'shore', 'tor', not_working_reason: "predictor gap: similarity=0; 'tor' (rocky peak) is too rare for the embeddings (see related_spec prereq)"
    set_related_oughta_contain 'pirate', 'attitude', 'latitude'
    set_related_oughta_contain 'pirate', 'crude', 'pursued', not_working_reason: "predictor now relates pirate/crude and pirate/pursued (related_spec prereqs pass), but set_related doesn't surface this tuple"
    set_related_oughta_contain 'pirate', 'buggery', 'thuggery'
    set_related_oughta_contain 'pirate', 'crews', 'tattoos'
    set_related_oughta_contain 'pirate', 'commandeering', 'profiteering'
    set_related_oughta_contain 'pirate', 'deck', 'wreck'
    set_related_oughta_contain 'pirate', 'dagger', 'swagger'
    set_related_oughta_contain 'pirate', 'diabolic', 'alcoholic'
    set_related_ought_not_contain 'pirate', 'diabolic', 'non-alcoholic'
    set_related_oughta_contain 'pirate', 'drunken', 'sunken'
    set_related_oughta_contain 'pirate', 'fursona', 'jonah'
    set_related_oughta_contain 'pirate', 'gallows', 'shallows'
    set_related_oughta_contain 'pirate', 'harbored', 'starboard'
    set_related_oughta_contain 'pirate', 'haunted', 'undaunted'
    set_related_oughta_contain 'pirate', 'hull', 'skull'
    set_related_oughta_contain 'pirate', 'loot', 'pursuit'
    set_related_oughta_contain 'pirate', 'lobster', 'mobster'
    set_related_oughta_contain 'pirate', 'leisure', 'seizure'
    set_related_oughta_contain 'pirate', 'leisure', 'treasure'
    set_related_oughta_contain 'pirate', 'manatee', 'profanity'
    set_related_oughta_contain 'pirate', 'rowboat', 'showboat'
    set_related_oughta_contain 'pirate', 'shanty', 'vigilante'
    set_related_oughta_contain 'pirate', 'sleeves', 'thieves'
    set_related_oughta_contain 'pirate', 'fiends', 'submarines'
    set_related_oughta_contain 'pirate', 'crypto', 'tiptoe'
    set_related_oughta_contain 'pirate', 'flaunted', 'haunted'
    set_related_oughta_contain 'pirate', 'flaunted', 'undaunted'
    set_related_oughta_contain 'pirate', 'anchored', 'tankard'
    set_related_oughta_contain 'pirate', 'blackguard', 'swaggered'
    set_related_oughta_contain 'pirate', 'drunken', 'sunken'
    set_related_oughta_contain 'pirate', 'hull', 'skull'
    set_related_ought_not_contain 'pirate', 'barreled', 'barrelled'
    set_related_ought_not_contain 'pirate', 'barreling', 'barrelling'
    set_related_ought_not_contain 'pirate', 'facie', 'racy' # I don't like "facie" without "prima", and even with "prima" I'm not sure it should be related to "pirate"
    set_related_ought_not_contain 'pirate', 'provings', 'removings' # oughta be redundant with proving / removing
  end
end
