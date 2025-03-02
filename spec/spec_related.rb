#
# related
#

def oughta_be_related(word1, word2, is_working=true)
  if(is_working)
    test_name = "'#{word1}' oughta be related to '#{word2}'"
    it test_name do
      expect(related?(word1, word2, false)).to eql(true), "'#{word1}' is #{percent_similarity(word1, word2)} related to '#{word2}', which is under the similarity threshold of #{percent_similarity_threshold()}"
    end
  else # NOT_WORKING
    if TEST_FOR_SURPRISING_SUCCESSES
      ought_not_be_related(word1, word2, true)
    end
  end
end
  
def ought_not_be_related(word1, word2, is_working=true)
  if(is_working)
    test_name = "'#{word1}' ought not be related to '#{word2}'"
    it test_name do
      expect(related?(word1, word2, false)).to eql(false), "'#{word1}' is #{percent_similarity(word1, word2)} related to '#{word2}', which meets the similarity threshold of #{percent_similarity_threshold()}"
    end
  else # NOT_WORKING
    if TEST_FOR_SURPRISING_SUCCESSES
      oughta_be_related(word1, word2, true)
    end
  end
end

def related_words_ought_not_include(word1, word2, is_working=true)
  if(is_working)
    test_name = "'Words related to #{word1}' ought not include '#{word2}'"
    related_words = find_related_words(word1, false)
    it test_name do
      expect(related_words.include?(word2)).to eql(false), "Words related to '#{word1}' ought not include '#{word2}', but they do: #{related_words}"
    end
  else # NOT_WORKING
    if TEST_FOR_SURPRISING_SUCCESSES
      expect(related_words.include?(word2)).to eql(true), "Words related to '#{word1}' oughta include '#{word2}', but they do not: #{related_words}"
    end
  end
end

describe 'RELATED' do
  
  context 'basic' do
    oughta_be_related 'grave', 'death'
    oughta_be_related 'tree', 'leaf'
    oughta_be_related 'tree', 'forest'
    oughta_be_related 'mow', 'lawn'
  end

  context 'reflexivity' do
    related_words_ought_not_include 'death', 'death'
  end

  context 'examples from the documentation' do
    oughta_be_related 'death', 'bled', NOT_WORKING
    oughta_be_related 'death', 'dead'
    oughta_be_related 'death', 'dread', NOT_WORKING
  end

  context 'slurs are forbidden' do
    related_words_ought_not_include 'gypsy', 'romanian'
    related_words_ought_not_include 'romanian', 'gypsy'
    related_words_ought_not_include 'gypsies', 'romanian'
    related_words_ought_not_include 'romanian', 'gypsies'
  end

  context 'trivial stop words ought not show up as related to anything' do
    ought_not_be_related 'food', 'the'
  end
  
  context 'morphological variants oughta be related, but not words that are merely orthographically similar' do
    oughta_be_related 'mow', 'mows'
    oughta_be_related 'mow', 'mowed'
    oughta_be_related 'mow', 'mower'
    oughta_be_related 'mow', 'mowing'
    ought_not_be_related 'mow', 'moll'
    ought_not_be_related 'mow', 'mosh'
    oughta_be_related 'tree', 'trees'
    oughta_be_related 'tree', 'treetop'
    oughta_be_related 'tree', 'treetops'
    ought_not_be_related 'tree', 'treece'
    ought_not_be_related 'tree', 'treese'
    ought_not_be_related 'tree', 'treesh'
  end

  context 'pirate' do
    oughta_be_related 'pirate', 'ship'
    oughta_be_related 'pirate', 'cache'
    oughta_be_related 'pirate', 'lash'
    oughta_be_related 'pirate', 'cove'
    oughta_be_related 'pirate', 'trove'
    oughta_be_related 'pirate', 'handsome'
    oughta_be_related 'pirate', 'ransom'
    oughta_be_related 'pirate', 'wench'
    oughta_be_related 'pirate', 'gang'
    oughta_be_related 'pirate', 'hang'
    oughta_be_related 'pirate', 'plank'
    oughta_be_related 'pirate', 'peg'
    oughta_be_related 'pirate', 'leg'
    oughta_be_related 'pirate', 'daring'
    oughta_be_related 'pirate', 'swearing'
    oughta_be_related 'pirate', 'hacker'
    oughta_be_related 'pirate', 'cracker'
    oughta_be_related 'pirate', 'sea'
    oughta_be_related 'pirate', 'dvd'
    oughta_be_related 'pirate', 'gold'
    oughta_be_related 'pirate', 'bold'
    oughta_be_related 'pirate', 'buccaneer'
    oughta_be_related 'pirate', 'peer-to-peer'
    oughta_be_related 'pirate', 'commandeer'
    oughta_be_related 'pirate', 'crew'
    oughta_be_related 'pirate', 'tattoo'
    oughta_be_related 'pirate', 'reef'
    oughta_be_related 'pirate', 'thief'
    oughta_be_related 'pirate', 'coast'
    oughta_be_related 'pirate', 'ghost'
    oughta_be_related 'pirate', 'loot'
    oughta_be_related 'pirate', 'pursuit'
    oughta_be_related 'pirate', 'rum'
    oughta_be_related 'pirate', 'saber'
    oughta_be_related 'pirate', 'scurvy'
    ought_not_be_related 'pirate', 'pew', NOT_WORKING
    oughta_be_related 'pirate', 'doubloons', NOT_WORKING
    ought_not_be_related 'pirate', 'roc'
    ought_not_be_related 'pirate', 'miko'
    ought_not_be_related 'pirate', 'mrs.'
    ought_not_be_related 'pirate', 'needlework'
    ought_not_be_related 'pirate', 'popcorn'
    ought_not_be_related 'pirate', 'galaxy'
    ought_not_be_related 'pirate', 'ebony'
    ought_not_be_related 'pirate', 'ballerina'
    ought_not_be_related 'pirate', 'bungee'
    ought_not_be_related 'pirate', 'homemade'
    ought_not_be_related 'pirate', 'pimping'
    ought_not_be_related 'pirate', 'prehistoric'
    ought_not_be_related 'pirate', 'reindeer'
    ought_not_be_related 'pirate', 'adipose'
    ought_not_be_related 'pirate', 'asexual'
    ought_not_be_related 'pirate', 'doodle'
    ought_not_be_related 'pirate', 'frisbee'
    ought_not_be_related 'pirate', 'isaac'
    ought_not_be_related 'pirate', 'laser'
    ought_not_be_related 'pirate', 'homophobic'
    ought_not_be_related 'pirate', 'pedantic'
  end

  context 'halloween' do
    oughta_be_related 'halloween', 'pumpkin'
    oughta_be_related 'halloween', 'bat'
    oughta_be_related 'halloween', 'cat'
    oughta_be_related 'halloween', 'fairy'
    oughta_be_related 'halloween', 'scary'
    oughta_be_related 'halloween', 'fright'
    oughta_be_related 'halloween', 'night'
    oughta_be_related 'halloween', 'cider'
    oughta_be_related 'halloween', 'spider'
    oughta_be_related 'halloween', 'decoration'
    oughta_be_related 'halloween', 'costume'
    ought_not_be_related 'halloween', 'ira', NOT_WORKING
    ought_not_be_related 'halloween', 'lindsay'
    ought_not_be_related 'halloween', 'lindsey'
    ought_not_be_related 'halloween', 'nicki'
    ought_not_be_related 'halloween', 'pauline', NOT_WORKING
  end

  context 'cat' do
    oughta_be_related 'cat', 'kitty'
    oughta_be_related 'cat', 'kitten'
    oughta_be_related 'cat', 'meow'
    oughta_be_related 'cat', 'dog'
    oughta_be_related 'cat', 'whisker'
    oughta_be_related 'cat', 'whiskers'
    oughta_be_related 'cat', 'cats'
    oughta_be_related 'cat', 'pet'
    oughta_be_related 'cat', 'purr'
    oughta_be_related 'cat', 'feline'
    oughta_be_related 'cat', 'tuxedo'
    oughta_be_related 'cat', 'skin' # there's more than one way
    oughta_be_related 'cat', 'neutered'
    oughta_be_related 'cat', 'spay'
    oughta_be_related 'cat', 'lynx'
    oughta_be_related 'cat', 'bobcat'
    oughta_be_related 'cat', 'lion'
    oughta_be_related 'cat', 'tiger'
    oughta_be_related 'cat', 'cougar'
    oughta_be_related 'cat', 'jaguar'
    oughta_be_related 'cat', 'wildcat'
    oughta_be_related 'cat', 'fur'
    oughta_be_related 'cat', 'cute'
    oughta_be_related 'cat', 'litter'
    oughta_be_related 'cat', 'tail'
    oughta_be_related 'cat', 'fancier'
    oughta_be_related 'cat', 'fanciers'
    oughta_be_related 'cat', 'eye'
    oughta_be_related 'cat', 'fleas'
    oughta_be_related 'cat', 'bite'
    oughta_be_related 'cat', 'stray'
    oughta_be_related 'cat', 'biscuit'
    oughta_be_related 'cat', 'paw'
    oughta_be_related 'cat', 'ear'
    oughta_be_related 'cat', 'ears'
    oughta_be_related 'cat', 'tree'
    oughta_be_related 'cat', 'puss'
    oughta_be_related 'cat', 'pussy'
    ought_not_be_related 'cat', 'object'
    ought_not_be_related 'cat', 'objects'
    ought_not_be_related 'cat', 'item'
    ought_not_be_related 'cat', 'items'
    ought_not_be_related 'cat', 'thing'
    ought_not_be_related 'cat', 'things'
    ought_not_be_related 'cat', 'verb'
    ought_not_be_related 'cat', 'justice'
    ought_not_be_related 'cat', 'hunker'
    ought_not_be_related 'cat', 'chunk'
    ought_not_be_related 'cat', 'knack'
    ought_not_be_related 'cat', 'zucchini'
    ought_not_be_related 'cat', 'astronomy'
    ought_not_be_related 'cat', 'undertow'
    ought_not_be_related 'cat', 'tool'
  end

  context 'crime' do
    oughta_be_related 'crime', 'heist'
    oughta_be_related 'crime', 'organized'
    oughta_be_related 'crime', 'burglar'
    oughta_be_related 'crime', 'burglary'
    oughta_be_related 'crime', 'rob'
    oughta_be_related 'crime', 'robber'
    oughta_be_related 'crime', 'robbery'
    oughta_be_related 'crime', 'felon'
    oughta_be_related 'crime', 'felony'
    oughta_be_related 'crime', 'loot'
    oughta_be_related 'crime', 'fight'
    oughta_be_related 'crime', 'jail'
    oughta_be_related 'crime', 'bank'
    oughta_be_related 'crime', 'murder'
    oughta_be_related 'crime', 'thief'
    oughta_be_related 'crime', 'theft'
    oughta_be_related 'crime', 'blackmail'
    oughta_be_related 'crime', 'gun'
    oughta_be_related 'crime', 'homicide'
    oughta_be_related 'crime', 'trespassing'
    oughta_be_related 'crime', 'vice'
    oughta_be_related 'crime', 'justice'
    oughta_be_related 'crime', 'acquit'
    oughta_be_related 'crime', 'acquitted'
    oughta_be_related 'crime', 'commit'
    oughta_be_related 'crime', 'committed'
    oughta_be_related 'crime', 'arrest'
    oughta_be_related 'crime', 'confessed'
    oughta_be_related 'crime', 'sleuth'
    oughta_be_related 'crime', 'truth'
    oughta_be_related 'crime', 'drugs'
    oughta_be_related 'crime', 'thugs'
    oughta_be_related 'crime', 'denial'
    oughta_be_related 'crime', 'trial'
    oughta_be_related 'crime', 'job'
    oughta_be_related 'crime', 'mob'
    oughta_be_related 'crime', 'sentence'
    oughta_be_related 'crime', 'repentance'
    oughta_be_related 'crime', 'skulduggery'
    oughta_be_related 'crime', 'thuggery'
    oughta_be_related 'crime', 'dishonesty'
    ought_not_be_related 'crime', 'person'
    ought_not_be_related 'crime', 'fungus'
    ought_not_be_related 'crime', 'soybean'
    ought_not_be_related 'crime', 'legume'
    ought_not_be_related 'crime', 'scallion'
    ought_not_be_related 'crime', 'grain'
    ought_not_be_related 'crime', 'pasta'
    ought_not_be_related 'crime', 'animation'
    ought_not_be_related 'crime', 'bank'
    ought_not_be_related 'crime', 'baseball'
    ought_not_be_related 'crime', 'chassis'
    ought_not_be_related 'crime', 'poodle'
    ought_not_be_related 'crime', 'etymology'
    ought_not_be_related 'crime', 'intonation'
    ought_not_be_related 'crime', 'meningitis'
    ought_not_be_related 'crime', 'ontology'
    ought_not_be_related 'crime', 'penicillin'
    ought_not_be_related 'crime', 'thing'
    ought_not_be_related 'crime', 'object'
    ought_not_be_related 'crime', 'transistors'
    ought_not_be_related 'crime', 'sky'
    ought_not_be_related 'crime', 'gas'
    ought_not_be_related 'crime', 'mass'
    ought_not_be_related 'crime', 'lake'
    ought_not_be_related 'crime', 'quake'
    ought_not_be_related 'crime', 'sci-fi'
    ought_not_be_related 'crime', 'word'
    ought_not_be_related 'crime', ''
    ought_not_be_related 'crime', ''
    ought_not_be_related 'crime', ''
    ought_not_be_related 'crime', ''
  end
  
  context 'pasta' do
    oughta_be_related 'pasta', 'champagne'
    oughta_be_related 'pasta', 'grain'
    oughta_be_related 'pasta', 'italian'
    oughta_be_related 'pasta', 'scallion'
    ought_not_be_related 'pasta', 'animation'
    ought_not_be_related 'pasta', 'bank'
    ought_not_be_related 'pasta', 'baseball'
    ought_not_be_related 'pasta', 'chassis'
    ought_not_be_related 'pasta', 'dog'
    ought_not_be_related 'pasta', 'poodle'
    ought_not_be_related 'pasta', 'etymology'
    ought_not_be_related 'pasta', 'intonation'
    ought_not_be_related 'pasta', 'intuition'
    ought_not_be_related 'pasta', 'meningitis'
    ought_not_be_related 'pasta', 'ontology'
    ought_not_be_related 'pasta', 'penicillin'
    ought_not_be_related 'pasta', 'stocks'
    ought_not_be_related 'pasta', 'thing'
    ought_not_be_related 'pasta', 'object'
    ought_not_be_related 'pasta', 'transistors'
  end

  context 'star' do
    oughta_be_related 'star', 'sun'
    oughta_be_related 'star', 'galaxy'
    oughta_be_related 'star', 'celebrity'
    oughta_be_related 'star', 'guest'
    oughta_be_related 'star', 'solar'
    oughta_be_related 'star', 'planet'
    oughta_be_related 'star', 'stellar'
    oughta_be_related 'star', 'constellation'
    oughta_be_related 'star', 'twinkle'
    oughta_be_related 'star', 'sparkle'
    oughta_be_related 'star', 'asterisk'
    oughta_be_related 'star', 'gold'
    oughta_be_related 'star', 'light'
    oughta_be_related 'star', 'lord' # Peter Quill
    oughta_be_related 'star', 'astronomy'
    oughta_be_related 'star', 'astronomer'
    oughta_be_related 'star', 'astrophysics'
    ought_not_be_related 'star', 'duck'
    ought_not_be_related 'star', 'rhombus'
    ought_not_be_related 'star', 'fandango'
    ought_not_be_related 'star', 'rancid'
    ought_not_be_related 'star', 'justice'
    ought_not_be_related 'star', 'melancholy'
    ought_not_be_related 'star', 'frolic'
    ought_not_be_related 'star', 'woe'
    ought_not_be_related 'star', 'malice'
    ought_not_be_related 'star', 'sever'
  end

  context 'music' do
    oughta_be_related 'music', 'baroque'
    oughta_be_related 'music', 'folk'
    oughta_be_related 'music', 'beat'
    oughta_be_related 'music', 'sheet'
    oughta_be_related 'music', 'cantata'
    oughta_be_related 'music', 'sonata'
    oughta_be_related 'music', 'noise'
    oughta_be_related 'music', 'funk'
    oughta_be_related 'music', 'punk'
    oughta_be_related 'music', 'sing'
    oughta_be_related 'music', 'swing'
    oughta_be_related 'music', 'orchestration'
    oughta_be_related 'music', 'vibration'
    oughta_be_related 'music', 'sonic'
    oughta_be_related 'music', 'harmonic'
    oughta_be_related 'music', 'piece'
    oughta_be_related 'music', 'release'
    oughta_be_related 'music', 'recital'
    oughta_be_related 'music', 'title'
    oughta_be_related 'music', 'piano'
    oughta_be_related 'music', 'soprano'
    oughta_be_related 'music', 'violins'
    oughta_be_related 'music', 'winds'
    oughta_be_related 'music', 'flute'
    oughta_be_related 'music', 'lute'
    oughta_be_related 'music', 'tango'
    oughta_be_related 'music', 'session'
    oughta_be_related 'music', 'progression'
    oughta_be_related 'music', 'croon'
    oughta_be_related 'music', 'tune'
    oughta_be_related 'music', 'crooner'
    oughta_be_related 'music', 'tuner'
    oughta_be_related 'music', 'ears'
    oughta_be_related 'music', 'spheres'
    oughta_be_related 'music', 'bridal'
    oughta_be_related 'music', 'idol'
    oughta_be_related 'music', 'audition'
    oughta_be_related 'music', 'composition'
    oughta_be_related 'music', 'chord'
    oughta_be_related 'music', 'record'
    oughta_be_related 'music', 'clarinet'
    oughta_be_related 'music', 'minuet'
    oughta_be_related 'music', 'accidental'
    oughta_be_related 'music', 'instrumental'
    oughta_be_related 'music', 'sings'
    oughta_be_related 'music', 'strings'
    oughta_be_related 'music', 'glissando'
    oughta_be_related 'music', 'ritardando'
    oughta_be_related 'music', 'viola'
    oughta_be_related 'music', 'hemiola'
    oughta_be_related 'music', 'overtone'
    oughta_be_related 'music', 'xylophone'
    oughta_be_related 'music', 'wave'
    oughta_be_related 'music', 'rave'
    oughta_be_related 'music', 'repeat'
    oughta_be_related 'music', 'jingle'
    oughta_be_related 'music', 'single'
    oughta_be_related 'music', 'bar'
    oughta_be_related 'music', 'repertoire'
    oughta_be_related 'music', 'bars'
    oughta_be_related 'music', 'score'
    oughta_be_related 'music', 'scores'
    oughta_be_related 'music', 'bass'
    ought_not_be_related 'music', 'base'
    oughta_be_related 'music', 'harp'
    oughta_be_related 'music', 'sharp'
    oughta_be_related 'music', 'flat'
    oughta_be_related 'music', 'show'
    oughta_be_related 'music', 'arpeggio'
    oughta_be_related 'music', 'mix'
    oughta_be_related 'music', 'drumsticks'
    oughta_be_related 'music', 'mandolin'
    oughta_be_related 'music', 'cello'
    oughta_be_related 'music', 'rest'
    oughta_be_related 'music', 'expressed'
    oughta_be_related 'music', 'fortissimo'
    oughta_be_related 'music', 'pianissimo'
    oughta_be_related 'music', 'gong'
    oughta_be_related 'music', 'song'
    oughta_be_related 'music', 'duet'
    oughta_be_related 'music', 'quartet'
    oughta_be_related 'music', 'quintet'
    oughta_be_related 'music', 'choral'
    ought_not_be_related 'music', 'coral'
    oughta_be_related 'music', 'tonal'
    oughta_be_related 'music', 'recorded'
    oughta_be_related 'music', 'prerecorded'
    oughta_be_related 'music', 'notation'
    oughta_be_related 'music', 'brass'
    oughta_be_related 'music', 'trombone'
  end
  
  context 'water' do
    oughta_be_related 'water', 'gush'
    oughta_be_related 'water', 'flush'
    oughta_be_related 'water', 'drink'
    oughta_be_related 'water', 'sink'
    oughta_be_related 'water', 'pee'
    oughta_be_related 'water', 'sea'
    oughta_be_related 'water', 'supply'
    oughta_be_related 'water', 'wade'
    oughta_be_related 'water', 'tide'
    oughta_be_related 'water', 'dam'
    oughta_be_related 'water', 'swam'
    oughta_be_related 'water', 'bay'
    oughta_be_related 'water', 'spray'
    oughta_be_related 'water', 'steam'
    oughta_be_related 'water', 'stream'
    oughta_be_related 'water', 'eau'
    oughta_be_related 'water', 'flow'
    oughta_be_related 'water', 'sweat'
    oughta_be_related 'water', 'wet'
    oughta_be_related 'water', 'cool'
    oughta_be_related 'water', 'pool'
    oughta_be_related 'water', 'drain'
    oughta_be_related 'water', 'rain'
    oughta_be_related 'water', 'drain'
    oughta_be_related 'water', 'rain'
    oughta_be_related 'water', 'marine'
    oughta_be_related 'water', 'saline'
    oughta_be_related 'water', 'dip'
    oughta_be_related 'water', 'sip'
    oughta_be_related 'water', 'ice'
  end
  
  context 'prayers' do
    oughta_be_related 'prayers', 'blessed'
    oughta_be_related 'prayers', 'request'
    oughta_be_related 'prayers', 'appeal'
    oughta_be_related 'prayers', 'kneel'
    oughta_be_related 'prayers', 'exhortations'
    oughta_be_related 'prayers', 'meditations'
    oughta_be_related 'prayers', 'pew'
    oughta_be_related 'prayers', 'plea'
    oughta_be_related 'prayers', 'healing'
    oughta_be_related 'prayers', 'kneeling'
    oughta_be_related 'prayers', 'priest'
  end
  
  context 'bread' do
    oughta_be_related 'bread', 'yeast'
  end
  
  context 'thing' do
    oughta_be_related 'thing', 'object'
    oughta_be_related 'thing', 'item'
    ought_not_be_related 'thing', 'cat'
    ought_not_be_related 'thing', 'pasta'
    ought_not_be_related 'thing', 'crime'
  end
  
end
