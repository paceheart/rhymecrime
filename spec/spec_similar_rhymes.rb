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

def set_related_oughta_contain(input, output1, output2, is_working=true)
  if(is_working)
    test_name = "set_related: #{input} -> #{output1} / #{output2}"
    it test_name do
      expect(set_related_contains?(input, output1, output2)).to eql(true), "Set-related rhymes for '#{input}' oughta include '#{output1}' (#{debug_info(output1)}) / '#{output2}' (#{debug_info(output2)}) / ..., but instead we just get #{find_rhyming_tuples(input)}"
    end
  else # NOT_WORKING
    if TEST_FOR_SURPRISING_SUCCESSES
      set_related_ought_not_contain(input, output1, output2, true)
    end
  end
end

def set_related_ought_not_contain(input, output1, output2, is_working=true)
  if(is_working)
    test_name = "set_related: #{input} !-> #{output1} / #{output2}"
    it test_name do
      expect(set_related_contains?(input, output1, output2)).to eql(false), "Set-related rhymes for '#{input}' ought not include '#{output1}' / '#{output2}' / ..."
    end
  else # NOT_WORKING
    if TEST_FOR_SURPRISING_SUCCESSES
      set_related_oughta_contain(input, output1, output2, true)
    end
  end
end

describe 'SET_RELATED' do

  context 'set_related works at all' do
    set_related_works 'death'
  end
  
  context 'examples from the documentation' do
    set_related_oughta_contain 'death', 'bled', 'dread', NOT_WORKING
    set_related_oughta_contain 'death', 'bled', 'dead', NOT_WORKING
    set_related_oughta_contain 'death', 'dead', 'dread', NOT_WORKING
  end
  
  context 'pirate' do
    set_related_oughta_contain 'pirate', 'cache', 'lash', NOT_WORKING
    set_related_oughta_contain 'pirate', 'cove', 'trove', NOT_WORKING
    set_related_oughta_contain 'pirate', 'handsome', 'ransom', NOT_WORKING
    set_related_oughta_contain 'pirate', 'french', 'wench', NOT_WORKING
    set_related_oughta_contain 'pirate', 'gang', 'hang', NOT_WORKING
    set_related_oughta_contain 'pirate', 'bold', 'gold', NOT_WORKING
    set_related_oughta_contain 'pirate', 'peg', 'leg', NOT_WORKING
    set_related_oughta_contain 'pirate', 'daring', 'swearing', NOT_WORKING
    set_related_oughta_contain 'pirate', 'hacker', 'cracker', NOT_WORKING # a different kind of pirate
    set_related_oughta_contain 'pirate', 'sea', 'dvd', NOT_WORKING # two different kinds of pirate
    set_related_oughta_contain 'pirate', 'buccaneer', 'peer-to-peer' # two different kinds of pirate
    set_related_oughta_contain 'pirate', 'buccaneer', 'commandeer', NOT_WORKING
    set_related_oughta_contain 'pirate', 'crew', 'tattoo', NOT_WORKING
    set_related_oughta_contain 'pirate', 'reef', 'thief'
    set_related_oughta_contain 'pirate', 'coast', 'ghost'
    set_related_oughta_contain 'pirate', 'loot', 'pursuit', NOT_WORKING
    set_related_ought_not_contain 'pirate', 'eyes', 'seas' # via two pronunciations of 'reprise'
  end

  context 'halloween' do
    set_related_oughta_contain 'halloween', 'celebration', 'decoration', NOT_WORKING
    set_related_oughta_contain 'halloween', 'cider', 'spider', NOT_WORKING
    set_related_oughta_contain 'halloween', 'sheet', 'treat', NOT_WORKING
    set_related_oughta_contain 'halloween', 'bat', 'cat', NOT_WORKING
    set_related_oughta_contain 'halloween', 'fairy', 'scary', NOT_WORKING
    set_related_oughta_contain 'halloween', 'fright', 'night', NOT_WORKING
    set_related_ought_not_contain 'halloween', 'lindsay', 'lindsey'
    set_related_ought_not_contain 'halloween', 'cider', 'snyder'
    set_related_ought_not_contain 'halloween', 'day', 'ira'
  end

  context 'music' do
    set_related_oughta_contain 'music', 'baroque', 'folk', NOT_WORKING
    set_related_oughta_contain 'music', 'beat', 'sheet', NOT_WORKING
    set_related_oughta_contain 'music', 'cantata', 'sonata'
    set_related_oughta_contain 'music', 'enjoys', 'noise', NOT_WORKING
    set_related_oughta_contain 'music', 'funk', 'punk', NOT_WORKING
    set_related_oughta_contain 'music', 'sing', 'swing', NOT_WORKING
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
    set_related_ought_not_contain 'music', 'compositions', 'musicians', NOT_WORKING # this identical rhymes gets a pass because it's in a set with a bunch of other non-identical rhymes
    set_related_ought_not_contain 'music', 'composition', 'musician', NOT_WORKING # this identical rhyme gets a pass because it's in a set with 'partition', which really probably oughtn't be related to music
    set_related_oughta_contain 'music', 'clarinet', 'minuet', NOT_WORKING
    set_related_oughta_contain 'music', 'accidental', 'instrumental', NOT_WORKING
    set_related_oughta_contain 'music', 'sings', 'strings', NOT_WORKING
    set_related_oughta_contain 'music', 'glissando', 'ritardando', NOT_WORKING
    set_related_oughta_contain 'music', 'viola', 'hemiola', NOT_WORKING
    set_related_oughta_contain 'music', 'overtone', 'xylophone', NOT_WORKING
    set_related_oughta_contain 'music', 'wave', 'rave', NOT_WORKING
    set_related_oughta_contain 'music', 'beat', 'repeat', NOT_WORKING
    set_related_oughta_contain 'music', 'flow', 'bow', NOT_WORKING
    set_related_oughta_contain 'music', 'jingle', 'single', NOT_WORKING # as in a hit single
    set_related_oughta_contain 'music', 'bar', 'repertoire', NOT_WORKING
    set_related_ought_not_contain 'music', 'bars', 'scores'
    set_related_ought_not_contain 'music', 'bass', 'base'
    set_related_oughta_contain 'music', 'harp', 'sharp', NOT_WORKING
    set_related_oughta_contain 'music', 'show', 'arpeggio', NOT_WORKING # if we squish the stress
    set_related_oughta_contain 'music', 'mix', 'drumsticks', NOT_WORKING # if we squish the stress
    set_related_oughta_contain 'music', 'violin', 'mandolin', NOT_WORKING
    set_related_oughta_contain 'music', 'rest', 'expressed', NOT_WORKING
    set_related_oughta_contain 'music', 'lute', 'flute', NOT_WORKING
    set_related_oughta_contain 'music', 'fortissimo', 'pianissimo', NOT_WORKING
    set_related_ought_not_contain 'music', 'cello', 'solo'
    set_related_ought_not_contain 'music', 'cello', 'concerto'
    set_related_ought_not_contain 'music', 'solo', 'concerto'
    set_related_oughta_contain 'music', 'gong', 'song', NOT_WORKING # reverse relatedness would fix
    set_related_oughta_contain 'music', 'duet', 'quartet', NOT_WORKING
    set_related_oughta_contain 'music', 'duet', 'quintet', NOT_WORKING
    set_related_ought_not_contain 'music', 'coral', 'choral' # exclude homophones 
    set_related_ought_not_contain 'music', 'recorded', 'prerecorded' # exclude identical rhymes
    set_related_ought_not_contain 'music', 'percussion', 'repercussion'
    set_related_ought_not_contain 'music', 'tonal', 'atonal' # exclude identical rhymes
    set_related_oughta_contain 'music', 'abbreviation', 'notation', NOT_WORKING # identical rhymes are OK if they're part of a tuple that contains non-identical rhymes such as the previous line
    set_related_ought_not_contain 'music', 'tv', 'vision'
    set_related_ought_not_contain 'music', 'bass', 'brass' # the fish is not related to the tuba
    it 'no proper subsets: we should get bone / intone / trombone, and not also get bone / intone' do
      bone_intone = ['bone', 'intone']
      bone_intone_trombone = ['bone', 'intone', 'trombone']
      tuples = find_rhyming_tuples('music', 'en')
      # NOT_WORKING: expect(tuples.include?(bone_intone_trombone)).to eql(true)
      expect(tuples.include?(bone_intone)).to eql(false)
    end
  end

  context 'water' do
    set_related_oughta_contain 'water', 'gush', 'flush', NOT_WORKING
    set_related_oughta_contain 'water', 'drink', 'sink', NOT_WORKING
    set_related_oughta_contain 'water', 'pee', 'sea'
    set_related_oughta_contain 'water', 'sky', 'supply', NOT_WORKING
    set_related_oughta_contain 'water', 'sprayed', 'wade', NOT_WORKING
    set_related_oughta_contain 'water', 'supplied', 'tide', NOT_WORKING
    set_related_oughta_contain 'water', 'dam', 'swam', NOT_WORKING
    set_related_oughta_contain 'water', 'slosh', 'wash'
    set_related_oughta_contain 'water', 'humidity', 'turbidity'
    set_related_oughta_contain 'water', 'bay', 'spray'
    set_related_oughta_contain 'water', 'steam', 'stream'
    set_related_oughta_contain 'water', 'eau', 'flow'
    set_related_oughta_contain 'water', 'sweat', 'wet'
    set_related_oughta_contain 'water', 'cool', 'pool'
    set_related_oughta_contain 'water', 'drain', 'rain'
    set_related_ought_not_contain 'water', 'sea', 'cod', NOT_WORKING
    set_related_oughta_contain 'water', 'blood', 'flood', NOT_WORKING
    set_related_oughta_contain 'water', 'marine', 'saline', NOT_WORKING
    set_related_oughta_contain 'water', 'dip', 'sip', NOT_WORKING
    set_related_ought_not_contain 'water', 'flour', 'flower'
  end

  context 'clumsy' do
    set_related_oughta_contain 'clumsy', 'bumbling', 'fumbling'
    set_related_oughta_contain 'clumsy', 'bumbling', 'stumbling'
    set_related_oughta_contain 'clumsy', 'excuse', 'shoes', NOT_WORKING
    set_related_oughta_contain 'clumsy', 'drop', 'flop', NOT_WORKING
  end

  context 'invoke' do
    set_related_oughta_contain 'invoke', 'dares', 'prayers', NOT_WORKING
    set_related_oughta_contain 'invoke', 'declare', 'prayer'
  end

  context 'prayers' do
    set_related_oughta_contain 'prayers', 'addressed', 'blessed', NOT_WORKING
    set_related_oughta_contain 'prayers', 'blessed', 'request', NOT_WORKING
    set_related_oughta_contain 'prayers', 'appeal', 'kneel', NOT_WORKING
    set_related_oughta_contain 'prayers', 'recites', 'rites'
    set_related_oughta_contain 'prayers', 'exhortations', 'meditations'
    set_related_oughta_contain 'prayers', 'humble', 'mumble', NOT_WORKING
    set_related_oughta_contain 'prayers', 'jew', 'pew', NOT_WORKING
    set_related_oughta_contain 'prayers', 'knee', 'plea', NOT_WORKING
    set_related_oughta_contain 'prayers', 'heal', 'kneel', NOT_WORKING
    set_related_oughta_contain 'prayers', 'healing', 'kneeling', NOT_WORKING
    set_related_oughta_contain 'prayers', 'feast', 'priest', NOT_WORKING
    set_related_oughta_contain 'prayers', 'feasts', 'priests', NOT_WORKING
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
  
  context 'prefix' do
    set_related_ought_not_contain 'carbon', 'cycling', 'recycling' # ought to filter out identical rhymes
    set_related_oughta_contain 'carbon', 'ester', 'sequester', NOT_WORKING
  end

  context 'root lemmas' do
    set_related_oughta_contain 'carbon', 'extract', 'react', NOT_WORKING
    set_related_ought_not_contain 'carbon', 'extracted', 'reacted'
  end
  
  context 'imperfect' do
    # relax the stress:
    set_related_oughta_contain 'halloween', 'broom', 'costume', NOT_WORKING
    set_related_oughta_contain 'music', 'oboe', 'piano', NOT_WORKING
    set_related_oughta_contain 'music', 'cello', 'solo', NOT_WORKING
    set_related_oughta_contain 'music', 'cello', 'concerto', NOT_WORKING
    set_related_oughta_contain 'music', 'solo', 'concerto', NOT_WORKING
    # dwim a non-final consonant
    set_related_oughta_contain 'music', 'symphony', 'timpani', NOT_WORKING
  end

  context 'no spelling variants' do
    set_related_ought_not_contain 'agree', 'harmonize', 'harmonise'
    set_related_ought_not_contain 'ace', 'honor', 'honour'
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

def pair_related_oughta_contain(input1, input2, output1, output2, is_working=true)
  if(is_working)
    test_name = "pair_related: #{input1} / #{input2} -> #{output1} / #{output2}"
    it test_name do
      expect(pair_related_contains?(input1, input2, output1, output2)).to eql(true), "Pair-related rhymes for '#{input1}' / '#{input2}' oughta include '#{output1}' (#{debug_info(output1)}) / '#{output2}' (#{debug_info(output2)}), but instead we just get #{find_rhyming_pairs(input1, input2)}"
    end
  else # NOT_WORKING
    if TEST_FOR_SURPRISING_SUCCESSES
      pair_related_ought_not_contain(input1, input2, output1, output2, true)
    end
  end
end

def pair_related_ought_not_contain(input1, input2, output1, output2, is_working=true)
  if(is_working)
    test_name = "pair_related: #{input1} / #{input2} !-> #{output1} / #{output2}"
    it test_name do
      expect(pair_related_contains?(input1, input2, output1, output2)).to eql(false), "Pair-related rhymes for '#{input1}' / '#{input2}' ought not include '#{output1}' / '#{output2}'"
    end
  else # NOT_WORKING
    if TEST_FOR_SURPRISING_SUCCESSES
      pair_related_oughta_contain(input1, input2, output1, output2, true)
    end
  end
end

describe 'PAIR_RELATED' do
  
  context 'examples from the old documentation' do
    pair_related_oughta_contain 'crime', 'heaven', 'confessed', 'blessed', NOT_WORKING # @todo update documentation
  end
  
  context 'examples from the documentation' do
    pair_related_oughta_contain 'crime', 'heaven', 'fraud', 'god' # @todo update documentation
  end
  
  context 'interactive fiction' do
    pair_related_oughta_contain 'interactive', 'fiction', 'exciting', 'writing', NOT_WORKING
  end

  context 'food evil' do
    pair_related_oughta_contain 'food', 'evil', 'chewed', 'rude', NOT_WORKING
    pair_related_oughta_contain 'food', 'evil', 'cuisine', 'mean'
    pair_related_oughta_contain 'food', 'evil', 'feed', 'greed', NOT_WORKING
    pair_related_oughta_contain 'food', 'evil', 'grain', 'pain'
    pair_related_oughta_contain 'food', 'evil', 'grain', 'bane'
    pair_related_oughta_contain 'food', 'evil', 'rice', 'vice'
    pair_related_ought_not_contain 'food', 'evil', 'vegetarian', 'totalitarian' # it's a damn shame that this is an identical rhyme
    pair_related_oughta_contain 'food', 'evil', 'dinner', 'sinner'
    pair_related_oughta_contain 'food', 'evil', 'cake', 'rake', NOT_WORKING
    pair_related_oughta_contain 'food', 'evil', 'mushroom', 'doom', NOT_WORKING
    pair_related_oughta_contain 'food', 'evil', 'chips', 'apocalypse', NOT_WORKING
    pair_related_oughta_contain 'food', 'evil', 'seder', 'darth vader', NOT_WORKING
    pair_related_oughta_contain 'food', 'evil', 'sachertort', 'voldemort', NOT_WORKING
    pair_related_oughta_contain 'food', 'evil', 'bread', 'undead', NOT_WORKING
    pair_related_oughta_contain 'food', 'evil', 'heinz', 'maligns', NOT_WORKING
    pair_related_oughta_contain 'food', 'evil', 'served', 'undeserved', NOT_WORKING # this is not quite an identical rhyme becauze the s in undeserved is pronounced like a z
    pair_related_ought_not_contain 'food', 'evil', 'sanitation', 'temptation' # identical rhyme
    pair_related_ought_not_contain 'food', 'evil', 'healthy', 'unhealthy'
    pair_related_ought_not_contain 'food', 'evil', 'contamination', 'condemnation'
    pair_related_oughta_contain 'food', 'evil', 'savory', 'slavery', NOT_WORKING
    pair_related_ought_not_contain 'food', 'evil', 'savoury', 'slavery'
    pair_related_oughta_contain 'food', 'evil', 'crumb', 'scum'
    pair_related_oughta_contain 'food', 'evil', 'organic', 'satanic'
    pair_related_oughta_contain 'food', 'evil', 'starvation', 'abomination'
    pair_related_oughta_contain 'food', 'evil', 'wine', 'malign'
    pair_related_oughta_contain 'food', 'evil', 'waiter', 'traitor'
    pair_related_oughta_contain 'food', 'evil', 'wheat', 'deceit'
    pair_related_oughta_contain 'food', 'evil', 'dessert', 'hurt'
    pair_related_ought_not_contain 'food', 'evil', 'produce', 'abuse', NOT_WORKING # the food sense of 'produce' is pronounced PRO-duce, which ought not rhyme with 'abuse'
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
  end

end

#
# related_rhymes
#

def related_rhymes?(input_rhyme, input_related, output)
  # Generate words that rhyme with input_related and are related to input_related.
  # Is OUTPUT one of them?
  # e.g. 'please', 'cats', 'siamese'
  find_related_rhymes(input_rhyme, input_related).include?(output)
end

def related_rhymes_oughta_contain(input_rhyme, input_related, output, is_working=true)
  if(is_working)
    test_name = "related_rhymes #{input_rhyme} + #{input_related} -> #{output}"
    it test_name do
      expect(related_rhymes?(input_rhyme, input_related, output)).to eql(true), "'#{output}' (#{debug_info(output)}) oughta be one of the words that rhyme with '#{input_rhyme}' (#{debug_info(input_rhyme)}) and is related to '#{input_related}'"
    end
  else # NOT_WORKING
    if TEST_FOR_SURPRISING_SUCCESSES
      related_rhymes_ought_not_contain(input_rhyme, input_related, output, true)
    end
  end
end

def related_rhymes_ought_not_contain(input_rhyme, input_related, output, is_working=true)
  if(is_working)
    test_name = "related_rhymes #{input_rhyme} + #{input_related} !-> #{output}"
    it test_name do
      expect(related_rhymes?(input_rhyme, input_related, output)).to eql(true), "'#{output}' (#{debug_info(output)}) ought not one of the words that rhyme with '#{input_rhyme}' (#{debug_info(input_rhyme)}) and is related to '#{input_related}'"
    end
  else # NOT_WORKING
    if TEST_FOR_SURPRISING_SUCCESSES
      related_rhymes_oughta_contain(input_rhyme, input_related, output, true)
    end
  end
end

describe 'RELATED_RHYMES' do

  context 'examples from the documentation' do
    related_rhymes_oughta_contain 'please', 'cats', 'siamese'
  end

end
