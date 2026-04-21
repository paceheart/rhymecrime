#
# set_related
# pair_related
# related_rhymes
#

def set_related_contains?(input, output1, output2)
  # Generate set_related rhymes for INPUT. Does one of them contain both OUTPUT1 and OUTPUT2?
  # e.g. 'pirate', 'handsome', 'ransom'
  for tuple in find_rhyming_tuples(input) do
    if(tuple.include?(output1) and tuple.include?(output2))
      return true
    end
  end
  return false
end

def set_related_works(input)
  test_name = "set_related works: #{input}"
  it test_name do
    expect(find_rhyming_tuples(input).length).not_to eql(0), "Set-related rhymes for '#{input}' oughta be non-empty"
  end
end

def set_related_oughta_contain(input, output1, output2, not_working_message: nil)
  test_name = "set_related: #{input} -> #{output1} / #{output2}"
  it test_name do
    skip_if_not_working(not_working_message)
    expect(set_related_contains?(input, output1, output2)).to eql(true), "Set-related rhymes for '#{input}' oughta include '#{output1}' (#{debug_info(output1)}) / '#{output2}' (#{debug_info(output2)}) / ..., but instead we just get #{find_rhyming_tuples(input)}"
  end
end

def set_related_ought_not_contain(input, output1, output2, not_working_message: nil)
  test_name = "set_related: #{input} !-> #{output1} / #{output2}"
  it test_name do
    skip_if_not_working(not_working_message)
    expect(set_related_contains?(input, output1, output2)).to eql(false), "Set-related rhymes for '#{input}' ought not include '#{output1}' / '#{output2}' / ..."
  end
end

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
    set_related_oughta_contain 'pirate', 'sea', 'dvd' # two different kinds of pirate
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
    set_related_oughta_contain 'pirate', 'shore', 'tor'
    set_related_oughta_contain 'pirate', 'attitude', 'latitude'
    set_related_oughta_contain 'pirate', 'crude', 'pursued'
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
    set_related_ought_not_contain 'pirate', 'barreled', 'barrelled'
    set_related_ought_not_contain 'pirate', 'barreling', 'barrelling'
    set_related_ought_not_contain 'pirate', 'facie', 'racy' # I don't like "facie" without "prima", and even with "prima" I'm not sure it should be related to "pirate"
    set_related_ought_not_contain 'pirate', 'provings', 'removings' # oughta be redundant with proving / removing
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

  context 'music' do
    set_related_oughta_contain 'music', 'baroque', 'folk'
    set_related_oughta_contain 'music', 'beat', 'sheet'
    set_related_oughta_contain 'music', 'cantata', 'sonata'
    set_related_oughta_contain 'music', 'enjoys', 'noise'
    set_related_oughta_contain 'music', 'funk', 'punk'
    set_related_oughta_contain 'music', 'sing', 'swing'
    set_related_oughta_contain 'music', 'orchestration', 'vibration'
    set_related_oughta_contain 'music', 'sonic', 'harmonic'
    set_related_oughta_contain 'music', 'piece', 'release'
    set_related_oughta_contain 'music', 'recital', 'title'
    set_related_oughta_contain 'music', 'piano', 'soprano'
    set_related_oughta_contain 'music', 'violins', 'winds'
    set_related_oughta_contain 'music', 'flute', 'lute'
    set_related_oughta_contain 'music', 'fandango', 'tango'
    set_related_oughta_contain 'music', 'session', 'progression'
    set_related_oughta_contain 'music', 'croon', 'tune'
    set_related_oughta_contain 'music', 'crooner', 'tuner'
    set_related_oughta_contain 'music', 'ears', 'spheres'
    set_related_oughta_contain 'music', 'bridal', 'idol'
    set_related_oughta_contain 'music', 'audition', 'composition'
    set_related_oughta_contain 'music', 'chord', 'record'
    set_related_ought_not_contain 'music', 'compositions', 'musicians'
    set_related_ought_not_contain 'music', 'composition', 'musician'
    set_related_oughta_contain 'music', 'clarinet', 'minuet'
    set_related_oughta_contain 'music', 'accidental', 'instrumental'
    set_related_oughta_contain 'music', 'sings', 'strings'
    set_related_oughta_contain 'music', 'glissando', 'ritardando', not_working_message: "ritardando OOV"
    set_related_oughta_contain 'music', 'viola', 'hemiola'
    set_related_ought_not_contain 'music', 'overtone', 'xylophone'
    set_related_oughta_contain 'music', 'wave', 'rave'
    set_related_oughta_contain 'music', 'beat', 'repeat'
    set_related_oughta_contain 'music', 'flow', 'bow'
    set_related_oughta_contain 'music', 'jingle', 'single' # as in a hit single
    set_related_oughta_contain 'music', 'harp', 'sharp'
    set_related_oughta_contain 'music', 'show', 'arpeggio' # , not_working_message: "stress mismatch"
    set_related_oughta_contain 'music', 'mix', 'drumsticks' #, not_working_message: "stress mismatch"
    set_related_oughta_contain 'music', 'violin', 'mandolin'
    set_related_oughta_contain 'music', 'rest', 'expressed'
    set_related_oughta_contain 'music', 'lute', 'flute'
    set_related_oughta_contain 'music', 'fortissimo', 'pianissimo'
    set_related_oughta_contain 'music', 'gong', 'song'
    set_related_oughta_contain 'music', 'duet', 'quartet'
    set_related_oughta_contain 'music', 'duet', 'quintet'
    set_related_ought_not_contain 'music', 'coral', 'choral' # exclude homophones 
    set_related_ought_not_contain 'music', 'recorded', 'prerecorded' # exclude identical rhymes
    set_related_oughta_contain 'music', 'percussion', 'repercussion' # looks like an identical rhyme but it's not
    set_related_ought_not_contain 'music', 'tonal', 'atonal' # exclude identical rhymes
    set_related_oughta_contain 'music', 'abbreviation', 'notation'
    set_related_ought_not_contain 'music', 'tv', 'vision'
    set_related_ought_not_contain 'music', 'bass', 'brass' # the fish is not related to the tuba
    it 'set_related music: bone / intone / trombone tuple' do
      skip_if_not_working(true)
      bone_intone_trombone = %w[bone intone trombone]
      tuples = find_rhyming_tuples('music', 'en')
      expect(tuples.include?(bone_intone_trombone)).to eql(true)
    end

    it 'no proper subsets: music ought not return bone / intone alone' do
      bone_intone = %w[bone intone]
      tuples = find_rhyming_tuples('music', 'en')
      expect(tuples.include?(bone_intone)).to eql(false)
    end
  end

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
    set_related_oughta_contain 'water', 'eau', 'flow'
    set_related_oughta_contain 'water', 'sweat', 'wet'
    set_related_oughta_contain 'water', 'cool', 'pool'
    set_related_oughta_contain 'water', 'drain', 'rain'
    set_related_ought_not_contain 'water', 'sea', 'cod'
    set_related_oughta_contain 'water', 'blood', 'flood'
    set_related_oughta_contain 'water', 'marine', 'saline'
    set_related_oughta_contain 'water', 'dip', 'sip'
    set_related_ought_not_contain 'water', 'flour', 'flower'
  end

  context 'clumsy' do
    set_related_oughta_contain 'clumsy', 'bumbling', 'fumbling'
    set_related_oughta_contain 'clumsy', 'bumbling', 'stumbling'
    set_related_oughta_contain 'clumsy', 'excuse', 'shoes'
    set_related_oughta_contain 'clumsy', 'drop', 'flop'
  end

  context 'invoke' do
    set_related_oughta_contain 'invoke', 'dares', 'prayers'
    set_related_oughta_contain 'invoke', 'declare', 'prayer'
  end

  context 'prayers' do
    set_related_oughta_contain 'prayers', 'addressed', 'blessed'
    set_related_oughta_contain 'prayers', 'blessed', 'request'
    set_related_oughta_contain 'prayers', 'appeal', 'kneel'
    set_related_oughta_contain 'prayers', 'recites', 'rites'
    set_related_oughta_contain 'prayers', 'exhortations', 'meditations'
    set_related_oughta_contain 'prayers', 'humble', 'mumble'
    set_related_oughta_contain 'prayers', 'jew', 'pew'
    set_related_oughta_contain 'prayers', 'knee', 'plea'
    set_related_oughta_contain 'prayers', 'heal', 'kneel'
    set_related_oughta_contain 'prayers', 'healing', 'kneeling'
    set_related_oughta_contain 'prayers', 'feast', 'priest'
    set_related_oughta_contain 'prayers', 'feasts', 'priests'
  end

  context 'carbon' do
    set_related_oughta_contain 'carbon', 'sink', 'zinc'
  end

  context 'bread' do
    set_related_oughta_contain 'bread', 'feast', 'yeast'
  end
  
  context 'pasta' do
    set_related_oughta_contain 'pasta', 'champagne', 'grain'
    set_related_oughta_contain 'pasta', 'clam', 'ham'
    set_related_oughta_contain 'pasta', 'dish', 'fish'
    set_related_oughta_contain 'pasta', 'fork', 'pork'
    set_related_oughta_contain 'pasta', 'italian', 'scallion'
    set_related_oughta_contain 'pasta', 'paste', 'taste'
  end 

  context 'crime' do
    set_related_oughta_contain 'crime', 'acquit', 'commit'
    set_related_oughta_contain 'crime', 'acquitted', 'committed'
    set_related_oughta_contain 'crime', 'arrest', 'confessed'
    set_related_oughta_contain 'crime', 'sleuth', 'truth'
    set_related_oughta_contain 'crime', 'drugs', 'thugs'
    set_related_oughta_contain 'crime', 'denial', 'trial'
    set_related_oughta_contain 'crime', 'job', 'mob'
    set_related_oughta_contain 'crime', 'sentence', 'repentance'
    set_related_oughta_contain 'crime', 'skulduggery', 'thuggery'
    set_related_ought_not_contain 'crime', 'dishonesty', 'honesty'
    set_related_ought_not_contain 'crime', 'dog', 'smog'
    set_related_ought_not_contain 'crime', 'gas', 'mass'
    set_related_ought_not_contain 'crime', 'lake', 'quake'
    set_related_ought_not_contain 'crime', 'nerd', 'word'
    set_related_ought_not_contain 'crime', 'sky', 'sci-fi'
  end

  context 'magic' do
    set_related_oughta_contain 'magic', 'chants', 'trance'
    set_related_ought_not_contain 'magic', 'enchanted', 'disenchanted' # identical rhyme
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
    set_related_oughta_contain 'exploration', 'knapsack', 'backtrack', not_working_message: "non-binary"
    set_related_oughta_contain 'exploration', 'pack', 'track'
  end
  
  context 'prefix' do
    set_related_ought_not_contain 'carbon', 'cycling', 'recycling' # ought to filter out identical rhymes
    set_related_oughta_contain 'carbon', 'ester', 'sequester'
  end

  context 'root lemmas' do
    set_related_oughta_contain 'carbon', 'extract', 'react'
    set_related_ought_not_contain 'carbon', 'extracted', 'reacted'
  end
  
  context 'imperfect' do
    # relax the stress:
    set_related_oughta_contain 'halloween', 'broom', 'costume', not_working_message: true
    set_related_oughta_contain 'music', 'oboe', 'piano', not_working_message: true
    set_related_oughta_contain 'music', 'cello', 'solo', not_working_message: true
    set_related_oughta_contain 'music', 'cello', 'concerto', not_working_message: true
    set_related_oughta_contain 'music', 'solo', 'concerto', not_working_message: true
    set_related_oughta_contain 'music', 'symphony', 'timpani', not_working_message: "this would only work if we dwim a non-final consonant"
  end

  context 'no spelling variants' do
    set_related_ought_not_contain 'funeral', 'eulogize', 'eulogise'
    set_related_ought_not_contain 'courtroom', 'honor', 'honour'
  end

end

#
# pair_related
#

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

def pair_related_oughta_contain(input1, input2, output1, output2, not_working_message: nil)
  test_name = "pair_related: #{input1} / #{input2} -> #{output1} / #{output2}"
  it test_name do
    skip_if_not_working(not_working_message)
    expect(pair_related_contains?(input1, input2, output1, output2)).to eql(true), "Pair-related rhymes for '#{input1}' / '#{input2}' oughta include '#{output1}' (#{debug_info(output1)}) / '#{output2}' (#{debug_info(output2)}), but instead we just get #{find_rhyming_pairs(input1, input2)}"
  end
end

def pair_related_ought_not_contain(input1, input2, output1, output2, not_working_message: nil)
  test_name = "pair_related: #{input1} / #{input2} !-> #{output1} / #{output2}"
  it test_name do
    skip_if_not_working(not_working_message)
    expect(pair_related_contains?(input1, input2, output1, output2)).to eql(false), "Pair-related rhymes for '#{input1}' / '#{input2}' ought not include '#{output1}' / '#{output2}'"
  end
end

describe 'PAIR_RELATED' do
  
  context 'examples from the old documentation' do
    pair_related_oughta_contain 'crime', 'heaven', 'confessed', 'blessed' # @todo update documentation
  end
  
  context 'examples from the documentation' do
    pair_related_oughta_contain 'crime', 'heaven', 'fraud', 'god' # @todo update documentation
  end
  
  context 'interactive fiction' do
    pair_related_oughta_contain 'interactive', 'fiction', 'exciting', 'writing'
  end

  context 'food evil' do
    pair_related_oughta_contain 'food', 'evil', 'chewed', 'rude'
    pair_related_oughta_contain 'food', 'evil', 'cuisine', 'mean'
    pair_related_oughta_contain 'food', 'evil', 'feed', 'greed'
    pair_related_oughta_contain 'food', 'evil', 'grain', 'pain'
    pair_related_oughta_contain 'food', 'evil', 'grain', 'bane'
    pair_related_oughta_contain 'food', 'evil', 'rice', 'vice'
    pair_related_ought_not_contain 'food', 'evil', 'vegetarian', 'totalitarian' # it's a damn shame that this is an identical rhyme
    pair_related_oughta_contain 'food', 'evil', 'dinner', 'sinner'
    pair_related_oughta_contain 'food', 'evil', 'cake', 'rake'
    pair_related_oughta_contain 'food', 'evil', 'mushroom', 'doom', not_working_message: "stress mismatch"
    pair_related_oughta_contain 'food', 'evil', 'chips', 'apocalypse', not_working_message: "stress mismatch"
    pair_related_oughta_contain 'food', 'evil', 'seder', 'invader'
    pair_related_oughta_contain 'food', 'evil', 'sachertorte', 'voldemort', not_working_message: "would be cool, but a big stretch"
    pair_related_oughta_contain 'food', 'evil', 'bread', 'undead'
    pair_related_oughta_contain 'food', 'evil', 'heinz', 'maligns'
    pair_related_oughta_contain 'food', 'evil', 'served', 'undeserved' # this is not quite an identical rhyme becauze the s in undeserved is pronounced like a z
    pair_related_ought_not_contain 'food', 'evil', 'sanitation', 'temptation' # identical rhyme
    pair_related_ought_not_contain 'food', 'evil', 'healthy', 'unhealthy'
    pair_related_ought_not_contain 'food', 'evil', 'contamination', 'condemnation'
    pair_related_oughta_contain 'food', 'evil', 'savory', 'slavery'
    pair_related_ought_not_contain 'food', 'evil', 'savoury', 'slavery'
    pair_related_oughta_contain 'food', 'evil', 'crumb', 'scum'
    pair_related_oughta_contain 'food', 'evil', 'organic', 'satanic'
    pair_related_oughta_contain 'food', 'evil', 'starvation', 'abomination'
    pair_related_oughta_contain 'food', 'evil', 'wine', 'malign'
    pair_related_oughta_contain 'food', 'evil', 'waiter', 'traitor'
    pair_related_oughta_contain 'food', 'evil', 'wheat', 'deceit'
    pair_related_oughta_contain 'food', 'evil', 'dessert', 'hurt'
    pair_related_ought_not_contain 'food', 'evil', 'produce', 'abuse' # the food sense of 'produce' is pronounced PRO-duce, which ought not rhyme with 'abuse'
  end

  context 'food dark' do
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
    pair_related_oughta_contain 'gay', 'food', 'trans', 'flans'
  end

  context 'fashion music' do
    pair_related_oughta_contain 'fashion', 'music', 'avant-garde', 'bard'
  end
end

#
# related_rhymes
#

def related_rhymes?(input_rhyme, input_related, output)
  # Words that rhyme with input_rhyme and are related to input_related — is OUTPUT one of them?
  # e.g. 'please', 'cats', 'siamese'
  find_related_rhymes(input_rhyme, input_related).include?(output)
end

def related_rhymes_oughta_contain(input_rhyme, input_related, output, not_working_message: nil)
  test_name = "related_rhymes #{input_rhyme} + #{input_related} -> #{output}"
  it test_name do
    skip_if_not_working(not_working_message)
    expect(related_rhymes?(input_rhyme, input_related, output)).to eql(true), "'#{output}' (#{debug_info(output)}) oughta be one of the words that rhyme with '#{input_rhyme}' (#{debug_info(input_rhyme)}) and is related to '#{input_related}'"
  end
end

def related_rhymes_ought_not_contain(input_rhyme, input_related, output, not_working_message: nil)
  test_name = "related_rhymes #{input_rhyme} + #{input_related} !-> #{output}"
  it test_name do
    skip_if_not_working(not_working_message)
    expect(related_rhymes?(input_rhyme, input_related, output)).to eql(true), "'#{output}' (#{debug_info(output)}) ought not one of the words that rhyme with '#{input_rhyme}' (#{debug_info(input_rhyme)}) and is related to '#{input_related}'"
  end
end

describe 'RELATED_RHYMES' do

  context 'examples from the documentation' do
    related_rhymes_oughta_contain 'please', 'cats', 'siamese'
  end

end
