# Rarity test performance as of 2026-04-05
# 95.7% success overall
# 98.3% success on the examples we care most about

#
# rare?
# 

def oughta_be_common(word, is_working=true, important=true)
  if(is_working)
    test_name = "'#{word}' oughta be common"
    it test_name do
      msg = "'#{word}' oughta be common, but is rare, with frequency #{frequency(word)}"
      msg += " (but it's not that big a deal)" unless important
      expect(rare?(word)).to eql(false), msg
    end
  else # NOT_WORKING
    if TEST_FOR_SURPRISING_SUCCESSES
      oughta_be_rare(word, true, important)
    end
  end
end

# Lower priority than oughta_be_common / oughta_be_rare: tagged :rarity_ish so you can
# focus on stricter examples first, e.g.  rspec spec/rarity_spec.rb --tag ~rarity_ish
def oughta_be_common_ish(word, is_working=true)
  if(is_working)
    it "'#{word}' oughta be common (ish)", :rarity_ish do
      msg = "'#{word}' oughta be common, but is rare, with frequency #{frequency(word)} (but it's not that big a deal)"
      expect(rare?(word)).to eql(false), msg
    end
  else # NOT_WORKING
    if TEST_FOR_SURPRISING_SUCCESSES
      oughta_be_rare_ish(word, true)
    end
  end
end

# Rhymeless words are filtered out early, so we can't test their rarity,
# but we can still verify that they have no rhymes
def oughta_be_common_but_has_no_rhymes(word, is_working=true)
  ought_not_have_rhymes(word, is_working)
end

def ought_not_have_rhymes(word, is_working=true)
  if(is_working)
    test_name = "'#{word}' oughta have no rhymes"
    it test_name do
      expect(find_preferred_rhyming_words(word)).to be_empty, "'#{word}' ought not have any rhymes, but it does: #{find_preferred_rhyming_words(word)}"
    end
  else # NOT_WORKING
    if TEST_FOR_SURPRISING_SUCCESSES
      oughta_have_rhymes(word, true)
    end
  end
end

def oughta_have_rhymes(word, is_working=true)
  if(is_working)
    test_name = "'#{word}' oughta have rhymes"
    it test_name do
      expect(find_preferred_rhyming_words(word)).not_to be_empty, "'#{word}' oughta have rhymes, but it doesn't."
    end
  else # NOT_WORKING
    if TEST_FOR_SURPRISING_SUCCESSES
      oughta_have_rhymes(word, true)
    end
  end
end

# borderline - it's okay if these are either common or rare
def oughta_be_uncommon(word, is_working=true)
  # intentional no-op
end

def oughta_be_rare(word, is_working=true, important=true)
  if(is_working)
    test_name = "'#{word}' oughta be rare"
    it test_name do
      msg = "'#{word}' oughta be rare, but is common, with frequency #{frequency(word)}"
      msg += " (but it's not that big a deal)" unless important
      expect(rare?(word)).to eql(true), msg
    end
  else # NOT_WORKING
    if TEST_FOR_SURPRISING_SUCCESSES
      oughta_be_common(word, true, important)
    end
  end
end

def oughta_be_rare_ish(word, is_working=true)
  if(is_working)
    it "'#{word}' oughta be rare (ish)", :rarity_ish do
      msg = "'#{word}' oughta be rare, but is common, with frequency #{frequency(word)} (but it's not that big a deal)"
      expect(rare?(word)).to eql(true), msg
    end
  else # NOT_WORKING
    if TEST_FOR_SURPRISING_SUCCESSES
      oughta_be_common_ish(word, true)
    end
  end
end

# Rhymeless words are filtered out early, so we can't test their rarity,
# but we can still verify that they have no rhymes
def oughta_be_rare_but_has_no_rhymes(word, is_working=true)
  ought_not_have_rhymes(word, is_working)
end

def allowed?(word)
  !explicitly_forbidden?(word) && word_dict.key?(word)
end

def oughta_be_forbidden(word, is_working=true)
  if(is_working)
    test_name = "'#{word}' oughta be forbidden"
    it test_name do
      expect(allowed?(word)).to eql(false), "'#{word}' oughta be forbidden, but is allowed."
    end
  end
end

describe 'RARITY' do
  context 'stop words' do
    oughta_be_common 'a'
    oughta_be_common 'be'
    oughta_be_common 'in'
    oughta_be_common 'it'
    oughta_be_common 'me'
    oughta_be_common 'i'
    oughta_be_common 'you'
    oughta_be_common 'to'
    oughta_be_common 'of'
    oughta_be_common 'at'
    oughta_be_common 'he'
    oughta_be_common 'she'
    oughta_be_common 'they'
    oughta_be_common 'their'
    oughta_be_common 'theirs'
    oughta_be_common 'his'
    oughta_be_common 'hers'
    oughta_be_common 'yours'
    oughta_be_common 'my'
    oughta_be_common 'about'
    oughta_be_common 'because'
    oughta_be_common 'and'
  end

  context 'obvious' do
    oughta_be_common 'up'
    oughta_be_common 'away'
    oughta_be_common 'cat'
    oughta_be_common 'alive'
    oughta_be_common "i've"
    oughta_be_common 'next'
    oughta_be_common 'around'
    oughta_be_common 'flight'
    oughta_be_common 'yeah'
    oughta_be_common 'whatever'
    oughta_be_common 'anymore'
    oughta_be_common 'pray'
    oughta_be_common 'obey'
    oughta_be_common 'divine'
    oughta_be_common 'adore'
    oughta_be_common 'wicker'
  end

  context 'initialisms' do
    oughta_be_common_ish 'tv'
    oughta_be_rare 'cctv'
    oughta_be_rare 'ok'
    oughta_be_common 'okay'
    # FP-2 class: wordfreq is high for these letter-strings, but they are not ordinary dictionary words
    oughta_be_common_ish 'ai'
    oughta_be_rare 'aol'
    oughta_be_rare 'al'
    oughta_be_rare_ish 'api'
    oughta_be_rare_ish 'atm'
    oughta_be_rare 'ba'
    oughta_be_rare 'bbc'
    oughta_be_rare 'ca'
    oughta_be_rare 'cbs'
    oughta_be_rare 'cnn'
    oughta_be_rare 'cu'
    oughta_be_rare 'dnc'
    oughta_be_rare 'ds'
    oughta_be_rare_ish 'dvd'
    oughta_be_rare 'er'
    oughta_be_rare_ish 'et'
    oughta_be_common 'ex'
    oughta_be_rare 'fe'
    oughta_be_rare 'fm'
    oughta_be_rare 'fyi'
    oughta_be_rare 'nba'
    oughta_be_rare 'nbc'
    oughta_be_rare 'nfl'
    oughta_be_rare 'ni'
    oughta_be_rare 'npr'
    oughta_be_rare 'pdf'
    oughta_be_rare 'pga'
    oughta_be_rare 'pm'
    oughta_be_rare 'sms'
    oughta_be_rare 'uae'
    oughta_be_rare 'usb'    
    oughta_be_rare 'vs'
    oughta_be_common 'versus'

    # Longer letter-strings: same FP-2 issue as 2-3 char (wordfreq/Wiktionary), not spoken as lemmas.
    context 'four- and five-letter initialisms' do
      oughta_be_common_ish 'nato', NOT_WORKING
      oughta_be_rare 'hdtv'
      oughta_be_rare 'nasa'
      oughta_be_rare 'wifi'
      oughta_be_rare 'wi-fi'
      oughta_be_rare 'nafta'
      oughta_be_rare_ish 'ascii'
      oughta_be_rare 'scsi'
      oughta_be_rare_ish 'http'
      oughta_be_rare 'asean'
      oughta_be_rare_ish 'aarp'
      oughta_be_rare_ish 'naacp'
      oughta_be_uncommon 'imax'
      oughta_be_uncommon 'mips'
      oughta_be_uncommon 'oled'
      oughta_be_rare 'fifo'
      oughta_be_rare 'lifo'
      oughta_be_common_ish 'unix', NOT_WORKING
      oughta_be_rare_ish 'apis'
      oughta_be_rare 'sram'
      oughta_be_rare 'perl'
      oughta_be_rare 'noaa'
      oughta_be_rare 'umass'
      oughta_be_rare 'unhcr'
      oughta_be_rare 'scada'
    end
  end

  context 'names' do
    oughta_be_rare 'ciardi'
    oughta_be_rare 'tuscaloosa'
    oughta_be_rare 'bors'
    oughta_be_rare 'matias'
    oughta_be_rare 'soweto'
    oughta_be_rare 'steinman'
    oughta_be_rare 'vicker'
    oughta_be_rare 'timmins'
    oughta_be_rare 'phileas'
    oughta_be_rare 'schwantes'
  end
  
  context 'uncommon but not rare' do
    oughta_be_common 'astray'
    oughta_be_common 'everyday'
    oughta_be_common 'faraway'
    oughta_be_common 'halfway'
    oughta_be_common 'risque'
    oughta_be_common 'underway'
    oughta_be_common 'renowned'
    oughta_be_common 'newfound'
    oughta_be_common 'shat'
    oughta_be_common 'bra'
    oughta_be_common 'daft'
    oughta_be_common 'evict'
    oughta_be_common 'flighty'
    oughta_be_common 'canned'
    oughta_be_common 'convex'
    oughta_be_common 'gasoline'
    oughta_be_common 'holy'
    oughta_be_common 'paroled'
    oughta_be_common 'saffron'
    oughta_be_common 'slacker'
    oughta_be_common 'trillion'
    oughta_be_common 'vanes'
    oughta_be_common 'chicanery'
    oughta_be_common 'combatants'
    oughta_be_common_ish 'noncombatants', NOT_WORKING
    oughta_be_common 'rapt'
    oughta_be_common 'sparkly'
    oughta_be_common 'splashy'
    oughta_be_common 'straightforward'
    oughta_be_common 'suicidal'
    oughta_be_common 'surgical'
    oughta_be_common 'tenuous'
    oughta_be_common 'tearful'
    oughta_be_common 'teary'
    oughta_be_common 'tasteless'
    oughta_be_common 'uncut'
    oughta_be_common 'viral'
    oughta_be_common 'wholehearted'
    oughta_be_common 'aground'
    oughta_be_common 'inbound'
  end

  context 'colloquial and slang' do
    oughta_be_common 'dude'
    oughta_be_common 'gonna'
    oughta_be_common 'wanna'
    oughta_be_common 'gotta'
    oughta_be_common 'awesome'
    oughta_be_common 'bummer'
    oughta_be_common 'chill'
    oughta_be_common 'sketchy'
    oughta_be_common 'crappy'
    oughta_be_common 'goofy'
    oughta_be_common 'nerdy'
    oughta_be_common 'snarky'
    oughta_be_common 'quirky'
    oughta_be_common 'freaky'
    oughta_be_common 'cheesy'
    oughta_be_common 'trashy'
    oughta_be_common 'grumpy'
    oughta_be_common 'feisty'
    oughta_be_common 'badass'
    oughta_be_common 'cranky'
  end

  context 'food and drink' do
    oughta_be_common 'pizza'
    oughta_be_common 'sushi'
    oughta_be_common 'taco'
    oughta_be_common 'burrito'
    oughta_be_common 'burger'
    oughta_be_common 'pasta'
    oughta_be_common 'whiskey'
    oughta_be_common 'vanilla'
    oughta_be_common 'cinnamon'
    oughta_be_common 'garlic'
    oughta_be_common 'avocado'
    oughta_be_common 'chocolate'
  end

  context 'common animals' do
    oughta_be_common 'alligator'
    oughta_be_common 'cheetah'
    oughta_be_common 'dolphin'
    oughta_be_common 'flamingo'
    oughta_be_common 'gator'
    oughta_be_common 'gorilla'
    oughta_be_common 'hedgehog'
    oughta_be_common 'jellyfish'
    oughta_be_common 'kangaroo'
    oughta_be_common 'octopus'
    oughta_be_common 'penguin'
    oughta_be_common 'raccoon'
    oughta_be_common 'porcupine'
  end

  context 'emotions and personality' do
    oughta_be_common 'anxious'
    oughta_be_common 'cynical'
    oughta_be_common 'desperate'
    oughta_be_common 'eccentric'
    oughta_be_common 'furious'
    oughta_be_common 'gullible'
    oughta_be_common 'jealous'
    oughta_be_common 'paranoid'
    oughta_be_common 'nostalgic'
    oughta_be_common 'skeptical'
    oughta_be_common 'arrogant'
    oughta_be_common 'ecstatic'
  end

  context 'performing arts' do
    oughta_be_common 'acoustic'
    oughta_be_common 'ballad'
    oughta_be_common 'encore'
    oughta_be_common 'graffiti'
    oughta_be_common 'karaoke'
    oughta_be_common 'lullaby'
    oughta_be_common 'symphony'
  end

  context 'common science knowledge' do
    oughta_be_common 'algorithm'
    oughta_be_common 'satellite'
    oughta_be_common 'telescope'
    oughta_be_common 'molecule'
    oughta_be_common 'oxygen'
    oughta_be_common 'gravity'
    oughta_be_common 'bacteria'
  end

  context 'crime and law' do
    oughta_be_common 'alibi'
    oughta_be_common 'contraband'
    oughta_be_common 'extortion'
    oughta_be_common 'felony'
    oughta_be_common 'arson'
    oughta_be_common 'blackmail'
    oughta_be_common 'treason'
  end

  context 'medical terms everyone knows' do
    oughta_be_common 'allergic'
    oughta_be_common 'bruise'
    oughta_be_common 'bruised'
    oughta_be_common 'bruiser'
    oughta_be_common_ish 'bruisers'
    oughta_be_common 'bruising'
    oughta_be_uncommon 'unbruised'
    oughta_be_common 'dizzy'
    oughta_be_common 'insomnia'
    oughta_be_common 'migraine'
    oughta_be_common 'concussion'
    oughta_be_common 'pneumonia'
  end

  context 'sophisticated but widely known' do
    oughta_be_common 'absurd'
    oughta_be_common 'clandestine'
    oughta_be_common 'eloquent'
    oughta_be_common 'flamboyant'
    oughta_be_common 'grotesque'
    oughta_be_common 'hypocrite'
    oughta_be_common 'infamous'
    oughta_be_common 'macabre'
    oughta_be_common 'mediocre'
    oughta_be_common 'outrageous'
    oughta_be_common 'preposterous'
    oughta_be_common 'sinister'
    oughta_be_common 'treacherous'
  end

  context 'profanity and insults' do
    oughta_be_common 'damn'
    oughta_be_common 'crap'
    oughta_be_common 'moron'
    oughta_be_common 'idiot'
    oughta_be_common 'bastard'
  end

  context 'body parts and household objects' do
    oughta_be_common 'elbow'
    oughta_be_common 'armpit'
    oughta_be_common 'nostril'
    oughta_be_common 'eyebrow'
    oughta_be_common 'doorknob'
    oughta_be_common 'dishwasher'
    oughta_be_common 'microwave'
    oughta_be_common 'toothbrush'
  end

  context 'weather and natural disasters' do
    oughta_be_common 'avalanche'
    oughta_be_common 'blizzard'
    oughta_be_common 'drought'
    oughta_be_common 'tornado'
    oughta_be_common 'tsunami'
    oughta_be_common 'hurricane'
  end

  context 'sounds and textures' do
    oughta_be_common 'screech'
    oughta_be_common 'rumble'
    oughta_be_common 'sizzle'
    oughta_be_common 'crackle'
    oughta_be_common 'velvet'
    oughta_be_common 'velvety'
    oughta_be_common 'grit'
    oughta_be_common 'gritty'
    oughta_be_common 'slime'
    oughta_be_common 'slimy'
    oughta_be_common 'crunch'
    oughta_be_common 'crunchy'
  end

  context 'french loanwords naturalized in english' do
    oughta_be_common 'rendezvous'
    oughta_be_common 'chauffeur'
    oughta_be_common 'silhouette'
    oughta_be_common 'sabotage'
    oughta_be_common 'camouflage'
  end

  context 'japanese loanwords naturalized in english' do
    oughta_be_common 'origami'
    oughta_be_common 'samurai'
    oughta_be_common 'karate'
    oughta_be_common 'judo'
  end

  context 'clothing and fabric' do
    oughta_be_common 'tux'
    oughta_be_common 'tuxedo'
    oughta_be_common 'flannel'
    oughta_be_common 'corduroy'
    oughta_be_common 'denim'
  end

  context 'words that sound rare but are widely known' do
    oughta_be_common 'cantankerous'
    oughta_be_common 'curmudgeon'
    oughta_be_common 'serendipity'
    oughta_be_common 'brouhaha'
    oughta_be_common 'kerfuffle', NOT_WORKING
    oughta_be_common 'hullabaloo'
    oughta_be_common 'shenanigans'
    oughta_be_rare 'shenanigan'
    oughta_be_common 'bamboozle'
    oughta_be_common 'bamboozled'
  end

  context 'common words seldom used in writing' do
    oughta_be_common 'sycophant'
    oughta_be_common 'obsequious'
    oughta_be_common 'nefarious'
    oughta_be_common 'insidious'
    oughta_be_common 'malarkey'
    oughta_be_common 'tomfoolery'
    oughta_be_common 'skulduggery', NOT_WORKING
    oughta_be_common 'flabbergasted'
  end

  context 'modern words (post-2009)' do
    oughta_be_common 'blog'    
    oughta_be_common 'blogs'
    oughta_be_common 'blogged'
    oughta_be_common 'blogger'
    oughta_be_common 'bloggers'
    oughta_be_common 'blogging'
    oughta_be_common_ish 'vlog'
    oughta_be_common_ish 'vlogs'
    oughta_be_common_ish 'vlogged'
    oughta_be_common_ish 'vlogging'
    oughta_be_common_ish 'vlogger', NOT_WORKING
    oughta_be_common_ish 'vloggers', NOT_WORKING
    oughta_be_common 'selfie'
    oughta_be_common 'hashtag'
    oughta_be_common 'emoji'
    oughta_be_common 'meme'
    oughta_be_common_but_has_no_rhymes 'malware'
    oughta_be_common 'trans'
    oughta_be_common 'bi'
    oughta_be_common 'poly'
    oughta_be_common_but_has_no_rhymes 'polyam'
    oughta_be_common 'polyamory'
    oughta_be_common 'polyamorous'
    oughta_be_common 'throuple', NOT_WORKING
    oughta_be_common 'throuples', NOT_WORKING
    oughta_be_rare 'thruple'
    oughta_be_rare 'thrupple'
    oughta_be_common 'yeet'
    oughta_be_common 'yeets'
    oughta_be_common 'yeeted'
    oughta_be_common 'yeeting'
    oughta_be_uncommon 'yote' # past tense of 'yeet'
    oughta_be_common 'twerk'
    oughta_be_common 'twerks'
    oughta_be_common 'twerked'
    oughta_be_common 'twerking'
    oughta_be_common_ish 'url', NOT_WORKING
    oughta_be_common_ish 'urls'
    oughta_be_rare 'urled'
    oughta_be_rare 'urling'
  end

  context 'surnames in cmudict' do
    oughta_be_rare 'attaway'
    oughta_be_rare 'beaupre'
    oughta_be_rare 'bergstrom'
    oughta_be_rare 'carstens'
    oughta_be_rare 'colborn'
    oughta_be_rare 'drinkwater'
    oughta_be_rare 'gruenhagen'
    oughta_be_rare 'hanauer'
    oughta_be_rare 'kirkbride'
    oughta_be_rare 'kreimer'
    oughta_be_rare 'lamarque'
    oughta_be_rare 'massingill'
    oughta_be_rare 'nordlund'
    oughta_be_rare 'pfleger'
    oughta_be_rare 'schnabel'
    oughta_be_rare 'stankiewicz'
    oughta_be_rare 'tewksbury'
    oughta_be_rare 'vandermeer'
    oughta_be_rare 'mcnaughton'
    oughta_be_rare 'brumfield'
  end

  context 'more surnames' do
    oughta_be_rare 'abernethy'
    oughta_be_rare 'baumgardner'
    oughta_be_rare 'crenwelge'
    oughta_be_rare 'dettweiler'
    oughta_be_rare 'eckstrom'
    oughta_be_rare 'fitzgibbons'
    oughta_be_rare 'grzelak'
    oughta_be_rare 'humpherys'
    oughta_be_rare 'iannaccone'
    oughta_be_rare 'kriegshauser'
    oughta_be_rare 'muehlberger'
    oughta_be_rare 'oesterling'
    oughta_be_rare 'przybylski'
    oughta_be_rare 'rheinhardt'
    oughta_be_rare 'thistlethwaite'
  end

  context 'obscure place names' do
    oughta_be_uncommon 'djibouti'
    oughta_be_rare 'kinshasa'
    oughta_be_rare 'liechtenstein'
    oughta_be_rare 'suriname'
    oughta_be_rare 'vladivostok'
    oughta_be_uncommon 'mogadishu'
    oughta_be_rare 'ouagadougou'
    oughta_be_rare 'turkmenistan'
    oughta_be_rare 'kyrgyzstan'
    oughta_be_rare 'tajikistan'
  end

  context 'obscure english words' do
    oughta_be_rare 'anfractuous'
    oughta_be_rare 'borborygmus'
    oughta_be_rare 'clerihew'
    oughta_be_rare 'colophon'
    oughta_be_common_but_has_no_rhymes 'defenestrate'
    oughta_be_rare 'escritoire'
    oughta_be_rare 'fylfot'
    oughta_be_rare 'gallimaufry'
    oughta_be_rare 'gegenschein'
    oughta_be_rare 'haruspex'
    oughta_be_rare 'inspissate'
    oughta_be_rare 'jeremiad'
    oughta_be_rare 'louche'
    oughta_be_rare 'maffick'
    oughta_be_rare 'narthex'
    oughta_be_rare 'oppugn'
    oughta_be_rare 'quahog'
    oughta_be_rare 'rebarbative'
    oughta_be_rare 'tatterdemalion'
    oughta_be_rare 'widdershins'
  end

  context 'literary and rhetorical terms' do
    oughta_be_common 'palimpsest', NOT_WORKING
    oughta_be_common_but_has_no_rhymes 'quincunx'
    oughta_be_rare 'tmesis'
    oughta_be_rare 'hendiadys'
    oughta_be_rare 'litotes'
    oughta_be_rare 'zeugma'
    oughta_be_rare 'chiasmus'
  end

  context 'academic and scientific jargon' do
    oughta_be_rare 'anisotropic'
    oughta_be_rare 'stoichiometry'
    oughta_be_rare 'titration'
    oughta_be_uncommon 'eschaton'
    oughta_be_rare 'eschatology'
    oughta_be_rare 'homiletics'
    oughta_be_rare 'hagiography'
    oughta_be_uncommon 'isomorphic'
    oughta_be_uncommon 'isomorphism'
    oughta_be_rare 'hermeneutics'
    oughta_be_rare 'eigenvalue'
    oughta_be_rare_ish 'chromatography', NOT_WORKING
    oughta_be_rare 'electrophoresis', NOT_WORKING
    oughta_be_rare_ish 'spectrometer', NOT_WORKING
    oughta_be_common 'reagent'
    oughta_be_rare 'adiabatic'
  end

  context 'obscure animals' do
    oughta_be_common 'axolotl'
    oughta_be_uncommon 'cassowary'
    oughta_be_uncommon 'dugong'
    oughta_be_common_ish 'echidna'
    oughta_be_rare 'gharial'
    oughta_be_uncommon 'pangolin'
    oughta_be_common 'tapir'
    oughta_be_rare 'numbat'
  end

  context 'archaic vocabulary' do
    oughta_be_common_ish 'forsooth', NOT_WORKING
    oughta_be_uncommon 'hauberk'
    oughta_be_rare 'varlet'
    oughta_be_uncommon 'seneschal'
    oughta_be_rare 'pottage'
    oughta_be_uncommon 'prithee'
    oughta_be_rare 'diapason'
    oughta_be_rare 'cynosure'
    oughta_be_uncommon 'panegyric'
    oughta_be_common_ish 'synecdoche', NOT_WORKING
    oughta_be_rare 'schenectady'
  end

  context 'astronomy' do
    oughta_be_uncommon 'umbra'
    oughta_be_uncommon 'penumbra'
    oughta_be_uncommon 'parallax'
    oughta_be_rare 'aphelion'
    oughta_be_rare 'perihelion'
  end

  context 'miscellaneous rare' do
    oughta_be_uncommon 'petrichor'
    oughta_be_rare_ish 'spoonerism'
    oughta_be_rare_ish 'malapropism'
    oughta_be_rare_ish 'kafkaesque'
    oughta_be_rare_ish 'cupola'
    oughta_be_rare_ish 'balustrade'
    oughta_be_rare_ish 'evanescent'
    oughta_be_rare 'velleity'
    oughta_be_rare_ish 'zugzwang'
    oughta_be_rare 'ephemeron'
  end

  context 'rare (original)' do
    oughta_be_rare 'alam'
    oughta_be_rare 'bahm'
    oughta_be_rare 'beacham'
    oughta_be_rare 'bram'
    oughta_be_rare 'burcham'
    oughta_be_rare 'camm'
    oughta_be_rare 'cham'
    oughta_be_rare 'dahm'
    oughta_be_rare 'damm'
    oughta_be_rare 'dirlam'
    oughta_be_rare 'flam'
    oughta_be_rare 'flamm'
    oughta_be_rare 'frahm'
    oughta_be_rare 'gahm'
    oughta_be_rare 'gamm'
    oughta_be_rare 'graeme'
    oughta_be_rare 'gramm'
    oughta_be_rare 'hahm'
    oughta_be_rare 'hamm'
    oughta_be_rare 'hamme'
    oughta_be_rare 'kam'
    oughta_be_rare 'kamm'
    oughta_be_rare 'klamm'
    oughta_be_rare 'kram'
    oughta_be_rare 'kramm'
    oughta_be_rare 'kramme'
    oughta_be_rare 'kvam'
    oughta_be_rare 'kvamme'
    oughta_be_rare 'laflam'
    oughta_be_rare 'laflamme'
    oughta_be_rare 'lahm'
    oughta_be_rare 'lambe'
    oughta_be_rare 'lamm'
    oughta_be_rare 'lamme'
    oughta_be_rare 'mcclam'
    oughta_be_rare 'mcham'
    oughta_be_rare 'mclamb'
    oughta_be_rare 'nahm'
    oughta_be_rare_ish 'nam'
    oughta_be_uncommon 'pam'
    oughta_be_rare 'panam'
    oughta_be_rare 'pham'
    oughta_be_rare 'plam'
    oughta_be_rare 'quamme'
    oughta_be_rare 'rahm'
    oughta_be_rare 'ramm'
    oughta_be_rare 'sahm'
    oughta_be_rare 'schram'
    oughta_be_rare 'schramm'
    oughta_be_rare 'stam'
    oughta_be_rare 'stamm'
    oughta_be_rare 'stram'
    oughta_be_rare 't-lam'
    oughta_be_rare 'tham'
    oughta_be_rare 'vandam'
    oughta_be_rare 'vandamme'
    oughta_be_rare 'zahm'
    oughta_be_rare 'sadat'
    oughta_be_rare 'spratt'
    oughta_be_rare 'arnatt'
    oughta_be_rare 'balyeat'
    oughta_be_rare 'batte'
    oughta_be_rare 'bhatt'
    oughta_be_rare 'biernat'
    oughta_be_rare 'blatt'
    oughta_be_rare 'bratt'
    oughta_be_rare 'catt'
    oughta_be_rare 'delatte'
    oughta_be_rare 'deslatte'
    oughta_be_rare 'elat'
    oughta_be_rare 'flatt'
    oughta_be_rare 'glatt'
    oughta_be_rare 'hatt'
    oughta_be_rare 'hnat'
    oughta_be_rare 'inmarsat'
    oughta_be_rare 'jagt'
    oughta_be_rare 'katt'
    oughta_be_rare 'klatt'
    oughta_be_rare 'krat'
    oughta_be_rare 'kratt'
    oughta_be_rare 'labatt'
    oughta_be_rare 'landsat'
    oughta_be_rare 'mcnatt'
    oughta_be_rare 'patt'
    oughta_be_rare 'platt'
    oughta_be_rare 'pratte'
    oughta_be_rare 'prevatt'
    oughta_be_rare 'prevatte'
    oughta_be_rare 'ratte'
    oughta_be_rare 'sarratt'
    oughta_be_rare 'schadt'
    oughta_be_rare 'shatt'
    oughta_be_rare 'slaght'
    oughta_be_rare 'tvsat'
    oughta_be_rare 'junco'
    oughta_be_rare 'stylites'
    oughta_be_rare 'devine'
    oughta_be_rare 'pote'
    oughta_be_rare 'fifer'
  end

  # Some of these ought to be nonexistent rather than rare. TODO create oughta_be_nonexistent and refactor this context
  context 'rare word forms' do
    oughta_be_rare 'rebruised'
    oughta_be_rare 'rebruiser'
    oughta_be_rare 'rebruisers'
    oughta_be_rare 'rebruising'
    oughta_be_rare 'bruisedness'
    oughta_be_rare 'bruisednesses'
    oughta_be_rare 'bruisingly'
    oughta_be_rare 'unbruise'
    oughta_be_rare 'unbruising'
    oughta_be_rare 'unrebruised'
    oughta_be_rare 'unrebruising'
    oughta_be_rare 'unrebruisedness'
    oughta_be_rare 'unrebruisednesses'
    oughta_be_rare 'unrebruisingly'
    oughta_be_rare 'unrebruisingness'
    oughta_be_rare 'unrebruisingnesses'
    oughta_be_rare 'unrebruisingly'
    oughta_be_rare 'rerebruised'
  end

  context 'inflections' do
    oughta_be_common "sky"
    oughta_be_common "skies"
    oughta_be_rare "skys"
    oughta_be_rare "skying", NOT_WORKING
    oughta_be_common "goose"
    oughta_be_common "geese"
    oughta_be_common "gooses", NOT_WORKING
    oughta_be_common "mouse"
    oughta_be_common "mice"
    oughta_be_uncommon "mouses"
    oughta_be_uncommon "mousing"
    oughta_be_uncommon "moused"
    oughta_be_rare "mousingly"
    oughta_be_common_ish "mousiness", NOT_WORKING
    oughta_be_rare "mousinesses"
    oughta_be_rare "mousinessly"
    oughta_be_common_ish "mouser"
    oughta_be_common_ish "mousers"
    oughta_be_common "fox"
    oughta_be_common "foxes"
    oughta_be_rare "foxs"
    oughta_be_rare "foxed"
    oughta_be_rare "foxing"
    oughta_be_rare "foxly"
    oughta_be_common "foxy"
    oughta_be_rare "foxyness"
    oughta_be_common_ish "foxily", NOT_WORKING
    oughta_be_rare "foxyly"
    oughta_be_common_ish "foxiness", NOT_WORKING
    oughta_be_rare "foxinesses"
    oughta_be_common "foxier"
    oughta_be_common "foxiest"
    oughta_be_rare "foxyer"
    oughta_be_rare "foxyest"
    oughta_be_rare "foxynesses"
    oughta_be_common "crotch"
    oughta_be_common "crotches"
    oughta_be_rare "crotchs"
    oughta_be_rare "crotched"
    oughta_be_rare "crotching"
    oughta_be_common "tulip"
    oughta_be_common "tulips"
    oughta_be_rare "tulipes"
    oughta_be_rare "tulipped"
    oughta_be_rare "tulipping"
    oughta_be_common "free"
    oughta_be_common "frees"
    oughta_be_common "freed"
    oughta_be_common "freer"
    oughta_be_common "freest"
    oughta_be_common "freeing"
    oughta_be_common "ghost"
    oughta_be_common "ghosts"
    oughta_be_common "ghosted"
    oughta_be_common "ghosting"
    oughta_be_common "ghostly"
    oughta_be_rare "campal" # spurious *al* from *campus* if *us→*al-style rules ever return
    oughta_be_rare 'mochaed'
    oughta_be_rare 'mochaer'
    oughta_be_rare 'mochaest'
    oughta_be_rare 'mochaing'
    oughta_be_common 'white'
    oughta_be_common 'whiter'
    oughta_be_common 'whitest'
    oughta_be_common 'magenta'
    oughta_be_rare 'magentaed'
    oughta_be_rare 'magentaer'
    oughta_be_rare 'magentaest'
    oughta_be_rare 'magentad'
    oughta_be_rare 'magentar'
    oughta_be_rare 'magentast'
    oughta_be_common 'recherche'
    oughta_be_rare 'rechercher'
    oughta_be_rare 'rechercheer'
    oughta_be_rare 'recherched'
    oughta_be_rare 'rechercheed'
    oughta_be_rare 'recherchest'
    oughta_be_rare 'rechercheest'
    oughta_be_common 'khaki'
    oughta_be_common 'khakis'
    oughta_be_rare 'khakied'
    oughta_be_rare 'khakier'
    oughta_be_rare 'khakiest'
    oughta_be_common 'jumbo'
    oughta_be_rare 'jumboed'
    oughta_be_rare 'jumboer'
    oughta_be_rare 'jumboest'
    oughta_be_common 'taboo'
    oughta_be_common 'taboos'
    oughta_be_rare 'tabood'
    oughta_be_rare 'tabooed'
    oughta_be_rare 'tabooer'
    oughta_be_rare 'tabooest'
    oughta_be_common 'impromptu'
    oughta_be_rare 'impromptus'
    oughta_be_rare 'impromptud'
    oughta_be_rare 'impromptued'
    oughta_be_rare 'impromptuer'
    oughta_be_rare 'impromptuest'
    oughta_be_common 'happy'
    oughta_be_rare 'happyer'
    oughta_be_common 'happier'
    oughta_be_rare 'happyest'
    oughta_be_common 'happiest'
    oughta_be_common 'ant'
    oughta_be_common 'ants'
    oughta_be_rare 'anting'
  end

  # FP-4: morphological junk (-ing) gets the same frequency as its base because Phase 8
  # inherits whenever the inflected form has no wordfreq row; real usage is vanishing.
  # (Same failure mode as "crotching" inheriting "crotch" while "crotched" is skipped
  # because wordfreq lists it.) See analysis discussion of spurious inheritance.
  context 'spurious inherited frequency (FP-4)' do
    oughta_be_rare 'kitchening'
    oughta_be_rare 'cousining'
    oughta_be_rare 'jealousing'
    oughta_be_rare 'beautying'
    oughta_be_rare 'opinioning'
    oughta_be_rare 'attorneying'
    oughta_be_rare 'televisioning'
    oughta_be_rare 'permissioning'
    oughta_be_rare 'secretarying'
    oughta_be_rare 'missioning'
    oughta_be_rare 'conversationing'
  end

  context 'hyphenated words' do
    context 'without existing final words' do
      oughta_be_common 'avant-garde'
      oughta_be_common 'cul-de-sac'
      oughta_be_uncommon 'culs-de-sac'
      oughta_be_common 'cul-de-sacs'
      oughta_be_rare 'culdesac'
      oughta_be_rare 'culdesacs'
      oughta_be_common_ish 'hoity-toity'
      oughta_be_rare 'hoity-toitys'
      oughta_be_rare 'hoity-toities'
      oughta_be_common_ish 'namby-pamby'
      oughta_be_rare 'namby-pambys'
      oughta_be_rare 'namby-pambies'
      oughta_be_rare_ish 'coco-de-mer'
      oughta_be_rare_ish 'sans-culotte'
      oughta_be_rare_ish 'sans-culottes'
      oughta_be_rare 'dinky-di'
      oughta_be_common_ish 'topsy-turvy'
      oughta_be_rare 'topsy-turvies'
      oughta_be_rare 'topsy-turvys'
      oughta_be_rare 'topsy-turvying'
      oughta_be_rare_ish 'topsy-turvier'
      oughta_be_rare_ish 'topsy-turviest'
      oughta_be_common_ish 'boogie-woogie'
      oughta_be_common_ish 'hanky-panky'
      oughta_be_rare 'heebie-jeebie'
      oughta_be_common_ish 'heebie-jeebies'
      oughta_be_common_ish 'hara-kiri'
      oughta_be_common_ish 'itsy-bitsy'
      oughta_be_rare_ish 'hurdy-gurdy', NOT_WORKING
      oughta_be_common_ish 'okey-dokey', NOT_WORKING
      oughta_be_common_ish 'tutti-frutti'
      oughta_be_common_ish 'willy-nilly'
      oughta_be_uncommon 'pell-mell'
      oughta_be_common_ish 'flim-flam'
      oughta_be_common_ish 'savoir-faire', NOT_WORKING
      oughta_be_common_ish 'papier-mache'
      oughta_be_rare_ish 'pince-nez', NOT_WORKING
      oughta_be_common_ish 'cock-a-doodle-doo', NOT_WORKING
      oughta_be_common_ish 'roly-poly'
    end

    context 'with existing final words' do
      oughta_be_common_ish 'ping-pong', NOT_WORKING
      oughta_be_common 'yo-yo'
      oughta_be_rare 'yoyo'
      oughta_be_rare 'about-face'
      oughta_be_rare 'face-to-face'
      oughta_be_rare 'good-looking'
      oughta_be_rare 'eye-catching'
      oughta_be_rare 'long-term'
      oughta_be_rare 'record-breaking'
      oughta_be_rare 'laid-back'
      oughta_be_rare 'one-sided', NOT_WORKING
      oughta_be_rare 'non-stop'
      oughta_be_rare 'one-way'
      oughta_be_rare 'two-way'
      oughta_be_rare 'well-known'
      oughta_be_rare 'well-being'
      oughta_be_rare 'old-fashioned'
      oughta_be_rare 'left-handed'
      oughta_be_rare 'mother-in-law'
      oughta_be_rare 'nitty-gritty'
      oughta_be_rare_ish 'helter-skelter'
      oughta_be_rare 'self-defense'
      oughta_be_rare 'up-to-date'
      oughta_be_rare 'ding-dong'
      oughta_be_rare_ish 'boo-boo'
      oughta_be_rare 'aye-aye'
      oughta_be_rare 'ha-ha'
      oughta_be_rare 'so-so'
    end
  end

  context 'explicitly forbidden' do
    oughta_be_forbidden 'gypsy'
    oughta_be_forbidden 'gypsys'
    oughta_be_forbidden 'gypsies'
    oughta_be_forbidden 'gypsyism'
    oughta_be_forbidden 'gypsyisms'
    oughta_be_forbidden 'gypsying'
    oughta_be_forbidden 'gyp'
    oughta_be_forbidden 'gypped'
    oughta_be_forbidden 'gypping'
    oughta_be_forbidden 'tranny'
    oughta_be_forbidden 'trannys'
    oughta_be_forbidden 'trannies'
    oughta_be_forbidden 'trannies'
    oughta_be_forbidden 'trannying'
    oughta_be_forbidden 'faggot'
    oughta_be_common 'fag' # this is fine I guess
    oughta_be_forbidden 'spic'
    oughta_be_forbidden 'spics'
    oughta_be_common 'spice' # naive prefix matching is too broad
  end

  context 'common_words.txt' do
    oughta_be_uncommon 'bluejeans'
    oughta_be_uncommon 'fedex'
    oughta_be_common 'flyby'
    oughta_be_common 'golly'
    oughta_be_common 'gotcha'
    oughta_be_common 'horsey'
    oughta_be_common 'jacuzzi'
    oughta_be_common 'oversell'
    oughta_be_common 'oversold'
    oughta_be_common 'something'
    oughta_be_common 'tootsie'
    oughta_be_rare_ish 'tremens'
    oughta_be_common 'waterbed'
    oughta_be_common 'waterbeds'
    oughta_be_uncommon 'willie'
    oughta_be_common 'accelerant'
    oughta_be_common 'accelerants'
    oughta_be_rare 'acceleranted'
    oughta_be_common 'annualize'
    oughta_be_common 'annualizes'
    oughta_be_common 'annualized'
    oughta_be_rare 'annualizee'
    oughta_be_rare 'annualizees'
    oughta_be_uncommon 'antidrug'
    oughta_be_uncommon 'antismoking'
    oughta_be_common 'audiophile'
    oughta_be_common 'audiophiles'
    oughta_be_uncommon 'bankshare'
    oughta_be_uncommon 'bankshares'
    oughta_be_common_ish 'carjack'
    oughta_be_common_ish 'carjacker'
    oughta_be_common_ish 'carjackers'
    oughta_be_rare 'cataloging'
    oughta_be_common 'catalogging'
    oughta_be_common 'clocker'
    oughta_be_common 'clockers'
    oughta_be_common 'departmentalize'
    oughta_be_common 'departmentalized'
    oughta_be_common 'departmentalizes'
    oughta_be_common 'deregulate'
    oughta_be_common 'deregulated'
    oughta_be_common 'deregulates'
    oughta_be_common 'deregulation'
    oughta_be_common_ish 'deregulator'
    oughta_be_common_ish 'deregulators'
    oughta_be_rare_ish 'dewire'
    oughta_be_common 'doomsayer'
    oughta_be_common 'doomsayers'
    oughta_be_common 'endeavored'
    oughta_be_common 'entrail'
    oughta_be_common 'entrails'
    oughta_be_uncommon 'ethnomusicologist'
    oughta_be_uncommon 'ferromagnet'
    oughta_be_common_ish 'glock'
    oughta_be_common 'gramophone'
    oughta_be_rare 'gramophons'
    oughta_be_common 'gramophones'
    oughta_be_rare 'gramaphone'
    oughta_be_rare 'gramaphones'
    oughta_be_common_ish 'grandbabies'
    oughta_be_common_ish 'grandbaby'
    oughta_be_common 'gussied'
    oughta_be_common 'gussy'
    oughta_be_common_ish 'herniate'
    oughta_be_rare 'homosapiens'
    oughta_be_uncommon 'longspur'
    oughta_be_uncommon 'longspurs'
    oughta_be_uncommon 'mindboggling'
    oughta_be_uncommon 'multiline'
    oughta_be_common 'nighter'
    oughta_be_common 'nighters'
    oughta_be_rare 'nighting'
    oughta_be_common 'knighting'
    oughta_be_rare 'norlander'
    oughta_be_rare 'norlanders'
    oughta_be_rare 'oldfashioned'
    oughta_be_uncommon 'overbuild'
    oughta_be_uncommon 'overbuilding'
    oughta_be_common 'pompom'
    oughta_be_common 'pompoms'
    oughta_be_uncommon 'reallowance'
    oughta_be_common 'rebook'
    oughta_be_common 'rebooked'
    oughta_be_common 'rebooks'
    oughta_be_common 'rebooking'
    oughta_be_rare 'recapitalization'
    oughta_be_rare 'recapitalizations'
    oughta_be_rare 'recordkeeping'
    oughta_be_common 'refile'
    oughta_be_common 'refiled'
    oughta_be_common 'refiles'
    oughta_be_rare 'renationalize'
    oughta_be_rare 'renationalized'
    oughta_be_common_ish 'rezoning'
    oughta_be_common_ish 'servicer'
    oughta_be_common_ish 'sharecrop'
    oughta_be_common_ish 'slusher'
    oughta_be_rare_ish 'smartcard'
    oughta_be_common 'stockbroker'
    oughta_be_uncommon 'stockbroking'
    oughta_be_common 'subtype'
    oughta_be_common 'subtyping'
    oughta_be_common 'supercenter'
    oughta_be_common_ish 'tavernier'
    oughta_be_uncommon 'wiseguy'
    oughta_be_common 'yikes'
    oughta_be_uncommon 'blowdry'
    oughta_be_common 'chilies'
    oughta_be_common 'cush'
    oughta_be_common 'gangbuster'
    oughta_be_common_ish 'glassmaker', NOT_WORKING
    oughta_be_common_ish 'glassmaking'
    oughta_be_rare 'glassmake'
    oughta_be_rare 'glassmakes'
    oughta_be_rare 'glassmade'
    oughta_be_common 'grandkids'
    oughta_be_common 'grinch'
    oughta_be_common 'humored'
    oughta_be_common 'humoring'
    oughta_be_uncommon 'institutionalist'
    oughta_be_common 'outpour'
    oughta_be_common 'outpoured'
    oughta_be_common 'outpouring'
    oughta_be_common 'recon'
    oughta_be_uncommon 'redistricting'
    oughta_be_common 'regionalize'
    oughta_be_common 'regionalized'
    oughta_be_common 'regionalizes'
    oughta_be_common 'regionalizing'
    oughta_be_common 'scientologist'
    oughta_be_common 'scientologists'
    oughta_be_common 'scoping'
    oughta_be_common 'sensationalize'
    oughta_be_common 'sensationalized'
    oughta_be_common 'sensationalizes'
    oughta_be_common 'sensationalizing'
    oughta_be_rare 'shant'
    oughta_be_common "shan't"
    oughta_be_common 'shader'
    oughta_be_common 'shortchange'
    oughta_be_common 'shortchanged'
    oughta_be_common 'superhero'
    oughta_be_rare 'superheros'
    oughta_be_common 'superheroes'
    oughta_be_common 'unsubscribe'
    oughta_be_common 'upsize'
    oughta_be_common 'upsizing'
    oughta_be_common 'finessed'
    oughta_be_common 'getter'
    oughta_be_common 'getters'
    oughta_be_common 'hardwired'
    oughta_be_common_ish 'imagineer'
    oughta_be_common_ish 'imagineering'
    oughta_be_common 'incant'
    oughta_be_common 'keto'
    oughta_be_common 'miscommunication'
    oughta_be_common 'ripoff'
    oughta_be_common 'tipoff'
    oughta_be_common 'standout'
    oughta_be_common 'standouts'
    oughta_be_common 'even'
  end

  context 'rare_words.txt' do
    oughta_be_rare 'abidjan'
    oughta_be_rare 'ane'
    oughta_be_rare 'bataan'
    oughta_be_rare 'bhutan'
    oughta_be_rare 'bis'
    oughta_be_rare 'burry'
    oughta_be_rare 'dhahran'
    oughta_be_rare 'fide'
    oughta_be_rare 'gibran'
    oughta_be_rare 'golan'
    oughta_be_rare 'hahn'
    oughta_be_rare 'kahn'
    oughta_be_rare 'lausanne'
    oughta_be_rare 'maran'
    oughta_be_rare 'maron'
    oughta_be_rare 'moldovan'
    oughta_be_rare 'mon'
    oughta_be_rare 'oran'
    oughta_be_rare 'pon'
    oughta_be_rare 'sonne'
    oughta_be_rare 'sorbonne'
    oughta_be_rare 'subacute'
    oughta_be_rare 'urey'
    oughta_be_rare 'xian'
    oughta_be_rare 'zon'
  end
end
