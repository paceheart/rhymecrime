#
# rare?
# 

def oughta_be_common(word, is_working=true)
  if(is_working)
    test_name = "'#{word}' oughta be common"
    it test_name do
      expect(rare?(word)).to eql(false), "'#{word}' oughta be common, but is rare, with frequency #{frequency(word)}"
    end
  else # NOT_WORKING
    if TEST_FOR_SURPRISING_SUCCESSES
      oughta_be_rare(word, true)
    end
  end
end

# borderline - it's okay if these are either common or rare
def oughta_be_uncommon(word, is_working=true)
  # intentional no-op
end

def oughta_be_rare(word, is_working=true)
  if(is_working)
    test_name = "'#{word}' oughta be rare"
    it test_name do
      expect(rare?(word)).to eql(true), "'#{word}' oughta be rare, but is common, with frequency #{frequency(word)}"
    end
  else # NOT_WORKING
    if TEST_FOR_SURPRISING_SUCCESSES
      oughta_be_common(word, true)
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

  context 'timely' do
    oughta_be_common 'blog'
  end

  context 'initialisms' do
    oughta_be_rare 'ni'
    oughta_be_rare 'cctv'
  end

  context 'names' do
    oughta_be_rare 'ciardi'
    oughta_be_rare 'tuscaloosa'
    oughta_be_rare 'bors', NOT_WORKING
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
    oughta_be_common 'face-to-face'
    oughta_be_common 'gasoline'
    oughta_be_common 'holy'
    oughta_be_common 'paroled'
    oughta_be_common 'saffron'
    oughta_be_common 'slacker'
    oughta_be_common 'trillion'
    oughta_be_common 'vanes'
    oughta_be_common 'chicanery'
    oughta_be_common 'combatants'
    oughta_be_common 'noncombatants'
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
    oughta_be_common 'bruisers'
    oughta_be_common 'bruising'
    oughta_be_common 'unbruised'
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
    oughta_be_common 'kerfuffle'
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
    oughta_be_common 'skulduggery'
    oughta_be_common 'flabbergasted'
  end

  context 'modern words (post-2009)' do
    oughta_be_common 'selfie'
    oughta_be_common 'hashtag'
    oughta_be_common 'emoji'
    oughta_be_common 'meme'
    oughta_be_common 'malware'
    oughta_be_common 'trans'
    oughta_be_common 'bi'
    oughta_be_common 'poly'
    oughta_be_common 'polyam'
    oughta_be_common 'polyamory'
    oughta_be_common 'polyamorous'
    oughta_be_common 'throuple'
    oughta_be_common 'throuples'
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
    oughta_be_common 'defenestrate'
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
    oughta_be_common 'palimpsest'
    oughta_be_common 'quincunx'
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
    oughta_be_rare 'eschatology'
    oughta_be_rare 'homiletics'
    oughta_be_rare 'hagiography'
    oughta_be_common 'isomorphic'
    oughta_be_common 'isomorphism'
    oughta_be_rare 'hermeneutics'
    oughta_be_rare 'eigenvalue'
    oughta_be_rare 'chromatography'
    oughta_be_rare 'electrophoresis'
    oughta_be_rare 'spectrometer'
    oughta_be_common 'reagent'
    oughta_be_rare 'adiabatic'
  end

  context 'obscure animals' do
    oughta_be_common 'axolotl'
    oughta_be_uncommon 'cassowary'
    oughta_be_uncommon 'dugong'
    oughta_be_common 'echidna'
    oughta_be_rare 'gharial'
    oughta_be_uncommon 'pangolin'
    oughta_be_common 'tapir'
    oughta_be_rare 'numbat'
  end

  context 'archaic vocabulary' do
    oughta_be_common 'forsooth'
    oughta_be_uncommon 'hauberk'
    oughta_be_rare 'varlet'
    oughta_be_uncommon 'seneschal'
    oughta_be_rare 'pottage'
    oughta_be_uncommon 'prithee'
    oughta_be_rare 'diapason'
    oughta_be_rare 'cynosure'
    oughta_be_uncommon 'panegyric'
    oughta_be_common 'synecdoche'
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
    oughta_be_rare 'spoonerism'
    oughta_be_rare 'malapropism'
    oughta_be_rare 'kafkaesque'
    oughta_be_rare 'cupola'
    oughta_be_rare 'balustrade'
    oughta_be_rare 'evanescent'
    oughta_be_rare 'velleity'
    oughta_be_rare 'zugzwang'
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
    oughta_be_rare 'nam'
    oughta_be_rare 'pam'
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
end
