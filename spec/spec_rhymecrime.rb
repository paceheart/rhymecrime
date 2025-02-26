require_relative '../crime'

# set this to false to skip known failures
TEST_FOR_SURPRISING_SUCCESSES = false

NOT_WORKING = false; #don't edit this one

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
    oughta_be_rare 'ni', NOT_WORKING
    oughta_be_rare 'cctv'
  end

  context 'names' do
    oughta_be_rare 'ciardi', NOT_WORKING
    oughta_be_rare 'tuscaloosa', NOT_WORKING
    oughta_be_rare 'bors', NOT_WORKING
    oughta_be_rare 'matias'
    oughta_be_rare 'soweto', NOT_WORKING
    oughta_be_rare 'steinman', NOT_WORKING
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
    oughta_be_common 'shat', NOT_WORKING
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

  context 'rare' do
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
    oughta_be_rare 'sadat', NOT_WORKING
    oughta_be_rare 'spratt', NOT_WORKING
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
    oughta_be_rare 'junco', NOT_WORKING
    oughta_be_rare 'stylites', NOT_WORKING
    oughta_be_rare 'devine'
    oughta_be_rare 'pote'
    oughta_be_rare 'fifer'
  end
end


#
# rhymes
#

def oughta_rhyme(word1, word2, is_working=true)
  oughta_rhyme_one_way(word1, word2, is_working)
  oughta_rhyme_one_way(word2, word1, is_working)
end

def oughta_rhyme_one_way(word1, word2, is_working=true)
  if is_working
    lang = 'en'
    test_name = "'#{word1}' in #{lang} oughta have '#{word2}' in its list of rhymes"
    it test_name do
      expect(find_preferred_rhyming_words(word1, lang).include?(word2)).to eql(true), "'#{word1}' (#{debug_info(word1, lang)}) oughta include '#{word2}' ((#{debug_info(word2, lang)}) in its list of rhymes, but instead it only rhymes with #{find_preferred_rhyming_words(word1, lang)}"
    end
  else # NOT_WORKING
    if TEST_FOR_SURPRISING_SUCCESSES
      ought_not_rhyme_one_way(word1, word2, true)
    end
  end
end

def ought_not_rhyme(word1, word2, is_working=true)
  lang = 'en'
  ought_not_rhyme_one_way(word1, word2, is_working)
  ought_not_rhyme_one_way(word2, word1, is_working)
end

def ought_not_rhyme_one_way(word1, word2, is_working=true)
  if is_working
    lang = 'en'
    test_name = "'#{word1}' in #{lang} ought not have '#{word2}' in its list of rhymes"
    it test_name do
      expect(find_preferred_rhyming_words(word1, lang).include?(word2)).to eql(false), "'#{word1}' (#{debug_info(word1, lang)}) ought not include '#{word2}' (#{debug_info(word2, lang)}) as a rhyme, but it does, and it also rhymes with #{find_preferred_rhyming_words(word1, lang)}"
    end
  else # NOT_WORKING
    if TEST_FOR_SURPRISING_SUCCESSES
      oughta_rhyme_one_way(word1, word2, true)
    end
  end
end

describe 'RHYMES' do

  context 'basic' do
    ought_not_rhyme 'beer', 'wine'
    oughta_rhyme 'yum', 'plum'
    oughta_rhyme 'space', 'place'
    oughta_rhyme 'rhyme', 'crime'
    oughta_rhyme 'gay', 'hooray'
    oughta_rhyme 'tongue', 'strung'
    oughta_rhyme 'tomb', 'doom'
    oughta_rhyme 'entomb', 'doom'
  end
  
  context 'tricky' do
    oughta_rhyme "we're", 'queer'
    ought_not_rhyme 'crime', "yum"
    ought_not_rhyme 'crime', "'em"
    ought_not_rhyme 'rhyme', "'em"
    oughta_rhyme 'station', 'nation'
    oughta_rhyme 'station', 'education'
    ought_not_rhyme 'station', 'cation' # it's pronounced "CAT-EYE-ON"
    ought_not_rhyme 'education', 'cation'
    ought_not_rhyme 'anion', 'onion' # it's pronounced "ANN-EYE-ON"
    oughta_rhyme 'bore', 'score'
    oughta_rhyme 'bar', 'scar'
    ought_not_rhyme 'bar', 'score'
    ought_not_rhyme 'bars', 'scores'
    oughta_rhyme 'wank', 'bank'
    ought_not_rhyme 'wank', 'bonk'
    oughta_rhyme 'bong', 'song'
    oughta_rhyme 'bounty', 'county'
    oughta_rhyme 'does', 'fuzz'
    oughta_rhyme 'is', 'fizz'
    ought_not_rhyme 'fizz', 'fuzz'
    ought_not_rhyme 'is', 'fuzz'
    ought_not_rhyme 'does', 'fizz'
    ought_not_rhyme 'does', 'is'
    oughta_rhyme 'did', 'bid'
    ought_not_rhyme 'good', 'did'
    ought_not_rhyme 'good', 'bid'
    ought_not_rhyme 'it', 'but'
    ought_not_rhyme 'just', 'kissed' # not a perfect rhyme
    oughta_rhyme 'michael', 'cycle'
    oughta_rhyme 'heart', 'art' # take that, Alexander Bain!
    oughta_rhyme 'selfish', 'shellfish' # take that, J.C. Wells!
    oughta_rhyme 'world', 'unfurled'
    oughta_rhyme 'cold', 'paroled'
    ought_not_rhyme 'work', 'fork'
    ought_not_rhyme 'coed', 'abode'
    oughta_rhyme 'cajun', 'contagion'
  end

  context 'perfect rhymes must rhyme the last primary-stressed syllable, not just the last syllable' do
    ought_not_rhyme 'station', 'shun'
    ought_not_rhyme 'under', 'fur'
    ought_not_rhyme 'tea', 'bounty'
    ought_not_rhyme 'eyeball', 'mall'
    ought_not_rhyme 'eyeball', 'ball'
    oughta_rhyme 'eyeball', 'highball', NOT_WORKING # not in cmudict
    ought_not_rhyme 'painting', 'ring'
  end

  context 'no self-rhymes' do
    ought_not_rhyme 'red', 'red'
  end
  
  context "homophones ought not count as rhymes" do
    ought_not_rhyme 'side', 'sighed'
    ought_not_rhyme 'blue', 'blew'
    ought_not_rhyme_one_way 'base', 'bass', NOT_WORKING # gets confused by bass the fish
    ought_not_rhyme_one_way 'bass', 'base'
    ought_not_rhyme 'coral', 'choral'
    ought_not_rhyme 'leader', 'lieder'
    ought_not_rhyme 'lindsay', 'lindsey'
    ought_not_rhyme 'hanukkah', 'chanukah' # what if the initial sounds are different, though? Then how do we know to eliminate this?
  end
  context "'lay' ought not rhyme with 'lei'..." do
    ought_not_rhyme 'lay', 'lei'
  end
  context "...but 'bay' oughta rhyme with both of 'em" do
    oughta_rhyme 'bay', 'lay'
    oughta_rhyme 'bay', 'lei'
  end
  
  context 'identical rhymes' do
    ought_not_rhyme 'leave', 'believe'
    ought_not_rhyme 'troll', 'patrol'
    ought_not_rhyme 'troll', 'control'
    oughta_rhyme 'end', 'pend'
    oughta_rhyme 'upend', 'pend', NOT_WORKING # 'upend' isn't in cmudict, and if it were, we'd get an incorrect syllable boundary anyway
    ought_not_rhyme 'end', 'upend' # working for the wrong reasons: 'upend' isn't in cmudict, and if it were, we'd get an incorrect syllable boundary anyway
    ought_not_rhyme 'lied', 'relied'
    ought_not_rhyme 'confide', 'defied'
    ought_not_rhyme 'side', 'beside'
    ought_not_rhyme 'side', 'alongside'
    ought_not_rhyme 'beside', 'alongside'
    ought_not_rhyme 'applied', 'misapplied'
    ought_not_rhyme 'plied', 'applied'
    ought_not_rhyme 'complied', 'applied'
    ought_not_rhyme 'recorded', 'prerecorded'
    ought_not_rhyme 'corded', 'recorded'
    ought_not_rhyme 'illicit', 'solicit' # I'm sad that these are identical rhymes. illicit [IH2 L IH1 S AH0 T] solicit [S AH0 L IH1 S IH0 T]
    ought_not_rhyme 'spectre', 'inspector'
    ought_not_rhyme 'supplemented', 'fermented'
    oughta_rhyme 'poor', 'pure' # P vs. PY is different enough
    ought_not_rhyme 'jar', 'ajar'
  end
  
  context "you can't just add a prefix and call it a rhyme" do
    oughta_rhyme 'grape', 'ape' # gr- is not a prefix
    oughta_rhyme 'pot', 'spot' # s- is not a prefix
    oughta_rhyme 'under', 'plunder' # pl- is not a prefix
    ought_not_rhyme 'bone', 'trombone' # trom- is not a prefix, but this is an identical rhyme anyway
    
    ought_not_rhyme 'promising', 'unpromising'
    ought_not_rhyme 'diversity', 'biodiversity'
    ought_not_rhyme 'ion', 'cation'
    
    oughta_rhyme 'able', 'cable'
    oughta_rhyme 'unable', 'cable'
    ought_not_rhyme 'able', 'unable' # un- is a prefix
    ought_not_rhyme 'unable', 'disable' # dis- is a prefix
    oughta_rhyme 'able', 'sable' # s- is not a prefix
    oughta_rhyme 'sable', 'disable', NOT_WORKING # arguable
    ought_not_rhyme 'able', 'disable'

    oughta_rhyme 'action', 'traction'
    oughta_rhyme 'action', 'attraction'
    ought_not_rhyme 'traction', 'attraction' # arguable

    oughta_rhyme 'ice', 'dice'
    ought_not_rhyme 'ice', 'deice' # deice (de-ice) is not in cmudict, so this succeeds for the wrong reason

    oughta_rhyme 'stand', 'strand'
    oughta_rhyme 'understand', 'strand'
    ought_not_rhyme 'stand', 'understand'
    ought_not_rhyme 'organizing', 'reorganizing'
    ought_not_rhyme 'organizing', 'self-organizing'
    ought_not_rhyme 'urban', 'suburban'
    ought_not_rhyme 'urbanize', 'suburbanize'
    ought_not_rhyme 'america', 'midamerica'
    ought_not_rhyme 'america', 'microamerica'
    ought_not_rhyme 'pure', 'impure'
    ought_not_rhyme 'open', 'reopen'
    ought_not_rhyme 'opened', 'unopened'
    ought_not_rhyme 'mixed', 'unmixed'
    ought_not_rhyme 'mixed', 'intermixed'
    ought_not_rhyme 'unmixed', 'intermixed'
    ought_not_rhyme 'operate', 'interoperate'
    ought_not_rhyme 'operate', 'cooperate'
    ought_not_rhyme 'indicated', 'contraindicated'
    ought_not_rhyme 'emphasize', 'deemphasize'
    ought_not_rhyme 'closed', 'enclosed'
    ought_not_rhyme 'close', 'enclose' # this is trickier because 'close' can mean 'nearby' in which case it's pronounced differently
    ought_not_rhyme 'act', 'enact'
    ought_not_rhyme 'urb', 'exurb'
    ought_not_rhyme 'ordinary', 'extraordinary'
    ought_not_rhyme 'exempt', 'preempt' # arguable
    ought_not_rhyme 'subhuman', 'superhuman'
    ought_not_rhyme 'active', 'hyperactive'
    ought_not_rhyme 'inactive', 'hyperactive'
    ought_not_rhyme 'operate', 'teleoperate'
    ought_not_rhyme 'logical', 'teleological'
  end

  context "spelling variants ought not count as rhymes" do
    ought_not_rhyme 'adapter', 'adaptor'
    ought_not_rhyme 'impostor', 'imposter'
    oughta_rhyme_one_way 'honour', 'goner' # input honour, you oughta get goner
    oughta_rhyme 'goner', 'honor' # but input goner, and you oughta get honor...
    ought_not_rhyme_one_way 'goner', 'honour' # ...but not honour
    oughta_rhyme_one_way 'realisable', 'advisable' # input realisable, you oughta get advisable
    oughta_rhyme 'advisable', 'realizable' # but input advisable, and you oughta get realizable...
    ought_not_rhyme_one_way 'advisable', 'realisable', NOT_WORKING # ...but not realisable with an s
  end

  context 'profanity is allowed' do
    oughta_rhyme 'truck', 'fuck'
    oughta_rhyme 'bunt', 'cunt'
    oughta_rhyme 'wanker', 'banker'
  end
  
  context 'slurs are forbidden' do
    ought_not_rhyme 'tipsy', 'gypsy'
    ought_not_rhyme 'fop', 'wop'
    ought_not_rhyme 'fops', 'wops'
    ought_not_rhyme 'crannies', 'trannies'
  end

  context 'initialisms' do
    ought_not_rhyme 'eye', 'ni'
  end

  context 'schwas' do
    oughta_rhyme 'picked', 'tricked'
    oughta_rhyme 'chicked', 'tricked'
    oughta_rhyme 'chucked', 'trucked'
    ought_not_rhyme 'picked', 'trucked'
    ought_not_rhyme 'chicked', 'trucked'
    oughta_rhyme 'neediest', 'greediest'
    oughta_rhyme 'meatiest', 'greediest', NOT_WORKING # 'meatiest' is not in cmudict
    ought_not_rhyme 'can', 'done'
    oughta_rhyme 'supplemented', 'invented' # IH D oughta get dwimmed to AH D
  end
  
  context 'apostrophes' do
    oughta_rhyme "hits", "its"
    oughta_rhyme "hits", "it's"
    ought_not_rhyme "its", "it's"
    oughta_rhyme "f'd", "bereft"
    oughta_rhyme "you're", 'secure'
  end

  context 'hyphens' do
    oughta_rhyme 'flaws', 'in-laws' # it ought to rhyme with the preferred form...
    ought_not_rhyme 'flaws', 'inlaws', NOT_WORKING # ...but not with the dispreferred form.
    ought_not_rhyme 'inlaws', 'in-laws'
    ought_not_rhyme 'nonbuilding', 'non-building'
  end
  
  context 'Limerick Heist' do
    oughta_rhyme 'heist', 'sliced'
    oughta_rhyme 'heist', 'iced'
  end

  context 'consonant clusters' do
    oughta_rhyme 'lengths', 'strengths'
    oughta_rhyme 'famed', 'claimed'
    oughta_rhyme 'sized', 'surmised'
    oughta_rhyme 'wreck', 'shrek'
    oughta_rhyme 'melt', 'svelte'
    oughta_rhyme 'pet', 'nyet'
    oughta_rhyme 'doom', 'vroom'
    oughta_rhyme 'spider', 'schneider'
    oughta_rhyme 'car', 'tsar'
    oughta_rhyme 'car', 'czar'
    ought_not_rhyme 'czar', 'tsar'
    oughta_rhyme 'lad', 'vlad', NOT_WORKING # 'vlad' gets syllabified as V . L AE D
    oughta_rhyme 'withdraw', 'voila'
  end
  
  context 'imperfect rhymes that ought to be perfect' do
    oughta_rhyme 'ear', 'beer' # used to fail because ear is [IY1 R] and beer is [B IH1 R]
    oughta_rhyme 'faring', 'glaring' # used to fail because faring is [F EH1 R IY0 NG] and glaring is [G L EH1 R IH0 NG]
    oughta_rhyme 'foster', 'impostor' # foster [AA S T ER] imposter [AO S T ER]
    oughta_rhyme 'curry', 'hurry' # curry [K AH1 R IY0] hurry [HH ER1 IY0]
    oughta_rhyme 'errors', 'terrors' # errors [EH1 R ER0 Z] terrors [T EH1 R AH0 R Z]
    oughta_rhyme 'array', 'hurray', NOT_WORKING # array [ER0 EY1] hurray [HH AH0 R EY1]
    oughta_rhyme_one_way 'array', 'moray' # array [ER0 EY1] moray [M ER0 EY1]
    oughta_rhyme_one_way 'moray', 'array', NOT_WORKING
    oughta_rhyme "takin'", 'waken' # takin' [T EY1 K IH0 N], waken [W EY1 K AH0 N]
    oughta_rhyme 'tons', 'funds' # [T AH1 N Z] [F AH1 N D Z], N D Z gets collapsed to N Z
    oughta_rhyme 'dance', 'ants' # plosive epenthesis. Technically this ought to only be valid within syllables, e.g. 'inside' ought not rhyme with 'ants hide', because you can't manifest a [t] out of nothing with 'inside', but whatever, it's fine.
    oughta_rhyme 'dreamt', 'tempt' # who cares about that P anyway. there's practically an invisible P in dreampt
    oughta_rhyme 'blotch', 'watch'
    oughta_rhyme 'blotched', 'watched'
    oughta_rhyme 'poor', 'tour' # P UW R / T UH R
  end

  context 'imperfect rhymes' do
    oughta_rhyme 'mushroom', 'doom', NOT_WORKING # no pronunciation for 'mushroom', and its stress is off
    oughta_rhyme 'dodge', 'massage' # only in Texas, but we don't want dodge to get lonely in its empty lodge
    oughta_rhyme 'dodges', 'massages'
    oughta_rhyme 'dodger', 'massager'
    oughta_rhyme 'dodgers', 'massagers'
    oughta_rhyme 'dodged', 'massaged'
    oughta_rhyme 'dodging', 'massaging'
    oughta_rhyme 'fennel', 'sentimental' # it's OK to elide the final T in 'sentimental'
    oughta_rhyme 'greediest', 'devious', NOT_WORKING
    oughta_rhyme 'fence', 'wince', NOT_WORKING
    oughta_rhyme 'vintage', 'percentage', NOT_WORKING 
    oughta_rhyme 'girl', 'world', NOT_WORKING
    oughta_rhyme 'false', 'malts' # sure I guess? otherwise 'false' won't rhyme with anything at all
    oughta_rhyme 'else', 'melts' # sure I guess? otherwise 'else' won't rhyme with anything at all
    oughta_rhyme 'poor', 'core', NOT_WORKING # in some dialects, these rhyme
    oughta_rhyme 'cajun', 'occasion', NOT_WORKING
  end
  
  context 'rhymes too imperfect to live' do
    ought_not_rhyme 'fennel', 'mental' # don't elide the t in 'mental'
    ought_not_rhyme 'just', 'kissed' # this could work in dialect, but ought not be standard

  end
  
  context 'loan words' do
    oughta_rhyme 'amour', 'bonjour'
  end
end

#
# related
#

def oughta_be_related(word1, word2, is_working=true)
  lang = 'en'
  if(is_working)
    test_name = "'#{word1}' in #{lang} oughta be related to '#{word2}'"
    it test_name do
      expect(related?(word1, word2, false, lang)).to eql(true), "Related words for '#{word1}' oughta include '#{word2}', but instead we just get #{find_related_words(word1, false, lang)}"
    end
  else # NOT_WORKING
    if TEST_FOR_SURPRISING_SUCCESSES
      ought_not_be_related(word1, word2, true)
    end
  end
end
  
def ought_not_be_related(word1, word2, is_working=true)
  lang = 'en'
  if(is_working)
    test_name = "'#{word1}' in #{lang} ought not be related to '#{word2}'"
    it test_name do
      expect(related?(word1, word2, false, lang)).to eql(false), "Related words in #{lang} for '#{word1}' ought not include '#{word2}'"
    end
  else # NOT_WORKING
    if TEST_FOR_SURPRISING_SUCCESSES
      oughta_be_related(word1, word2, true)
    end
  end
end
  
describe 'RELATED' do
  
  context 'basic' do
    oughta_be_related 'meow', 'cat'
    oughta_be_related 'grave', 'death'
  end

  context 'reflexivity' do
    ought_not_be_related 'death', 'death'
  end

  context 'examples from the documentation' do
    oughta_be_related 'death', 'bled', NOT_WORKING
    oughta_be_related 'death', 'dead'
    oughta_be_related 'death', 'dread', NOT_WORKING
  end

  context 'slurs are forbidden' do
    ought_not_be_related 'gypsy', 'romanian'
    ought_not_be_related 'romanian', 'gypsy'
    ought_not_be_related 'gypsies', 'romanian'
    ought_not_be_related 'romanian', 'gypsies'
  end

  context 'trivial stop words ought not show up as related to anything' do
    ought_not_be_related 'food', 'the'
  end
  
  context 'pirate' do
    ought_not_be_related 'pirate', 'pew', NOT_WORKING
    oughta_be_related 'pirate', 'doubloons', NOT_WORKING
  end

  context 'halloween' do
    ought_not_be_related 'halloween', 'ira', NOT_WORKING
    ought_not_be_related 'halloween', 'lindsay'
    ought_not_be_related 'halloween', 'lindsey'
    ought_not_be_related 'halloween', 'nicki'
    ought_not_be_related 'halloween', 'nikki'
    ought_not_be_related 'halloween', 'pauline', NOT_WORKING
  end
  
end

#
# set_related
#

def set_related_contains?(input, output1, output2, lang)
  # Generate set_related rhymes for INPUT. Does one of them contain both OUTPUT1 and OUTPUT2?
  # e.g. 'pirate', 'handsome', 'ransom'
  for tuple in find_rhyming_tuples(input, lang) do
    if(tuple.include?(output1) and tuple.include?(output2))
      return true
    end
  end
  return false
end

def set_related_oughta_contain(input, output1, output2, is_working=true)
  lang = 'en'
  if(is_working)
    test_name = "set_related #{lang}: #{input} -> #{output1} / #{output2}"
    it test_name do
      expect(set_related_contains?(input, output1, output2, lang)).to eql(true), "Set-related rhymes in #{lang} for '#{input}' oughta include '#{output1}' (#{debug_info(output1, lang)}) / '#{output2}' (#{debug_info(output2, lang)}) / ..., but instead we just get #{find_rhyming_tuples(input, lang)}"
    end
  else # NOT_WORKING
    if TEST_FOR_SURPRISING_SUCCESSES
      set_related_ought_not_contain(input, output1, output2, true)
    end
  end
end

def set_related_ought_not_contain(input, output1, output2, is_working=true)
  lang = 'en'
  if(is_working)
    test_name = "set_related #{lang}: #{input} !-> #{output1} / #{output2}"
    it test_name do
      expect(set_related_contains?(input, output1, output2, lang)).to eql(false), "Set-related rhymes in #{lang} for '#{input}' ought not include '#{output1}' / '#{output2}' / ..."
    end
  else # NOT_WORKING
    if TEST_FOR_SURPRISING_SUCCESSES
      set_related_oughta_contain(input, output1, output2, true)
    end
  end
end

describe 'SET_RELATED' do

  context 'examples from the documentation' do
    set_related_oughta_contain 'death', 'bled', 'dread', NOT_WORKING
    set_related_oughta_contain 'death', 'bled', 'dead', NOT_WORKING
    set_related_oughta_contain 'death', 'dead', 'dread', NOT_WORKING
  end
  
  context 'pirate' do
    set_related_oughta_contain 'pirate', 'cache', 'lash'
    set_related_oughta_contain 'pirate', 'cove', 'trove'
    set_related_oughta_contain 'pirate', 'handsome', 'ransom', NOT_WORKING
    set_related_oughta_contain 'pirate', 'french', 'wench', NOT_WORKING
    set_related_oughta_contain 'pirate', 'gang', 'hang', NOT_WORKING
    set_related_oughta_contain 'pirate', 'bold', 'gold', NOT_WORKING
    set_related_oughta_contain 'pirate', 'peg', 'leg', NOT_WORKING
    set_related_oughta_contain 'pirate', 'daring', 'swearing', NOT_WORKING
    set_related_oughta_contain 'pirate', 'hacker', 'cracker' # a different kind of pirate
    set_related_oughta_contain 'pirate', 'sea', 'dvd' # two different kinds of pirate
    set_related_oughta_contain 'pirate', 'crew', 'tattoo'
    set_related_oughta_contain 'pirate', 'coast', 'ghost', NOT_WORKING
    set_related_oughta_contain 'pirate', 'loot', 'pursuit', NOT_WORKING
    set_related_oughta_contain 'pirate', 'buccaneer', 'commandeer'
    set_related_ought_not_contain 'pirate', 'eyes', 'seas' # via two pronunciations of 'reprise'
  end

  context 'halloween' do
    set_related_oughta_contain 'halloween', 'celebration', 'decoration', NOT_WORKING
    set_related_oughta_contain 'halloween', 'cider', 'spider'
    set_related_oughta_contain 'halloween', 'sheet', 'treat'
    set_related_oughta_contain 'halloween', 'bat', 'cat'
    set_related_oughta_contain 'halloween', 'fairy', 'scary', NOT_WORKING
    set_related_oughta_contain 'halloween', 'fright', 'night'
    set_related_ought_not_contain 'halloween', 'lindsay', 'lindsey'
    set_related_ought_not_contain 'halloween', 'cider', 'snyder'
    set_related_ought_not_contain 'halloween', 'day', 'ira'
  end

  context 'music' do
    set_related_oughta_contain 'music', 'baroque', 'folk', NOT_WORKING
    set_related_oughta_contain 'music', 'beat', 'sheet'
    set_related_oughta_contain 'music', 'cantata', 'sonata'
    set_related_oughta_contain 'music', 'enjoys', 'noise', NOT_WORKING
    set_related_oughta_contain 'music', 'funk', 'punk', NOT_WORKING
    set_related_oughta_contain 'music', 'sing', 'swing'
    set_related_ought_not_contain 'music', 'compositions', 'musicians' # exclude identical rhymes
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
    set_related_oughta_contain 'music', 'guitar', 'rock star', NOT_WORKING
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
    set_related_oughta_contain 'music', 'abbreviation', 'notation', NOT_WORKING # identical rhymes are OK if they're part of a tuples that contains non-identical rhymes such as the previous line
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

  context 'prefix' do
    set_related_ought_not_contain 'carbon', 'cycling', 'recycling'
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

def pair_related_contains?(lang, input1, input2, output1, output2)
  # Generate pair_related rhymes for INPUT1 / INPUT2. Is one of them "OUTPUT1 / OUTPUT2"?
  target_pair = [output1, output2]
  find_rhyming_pairs(input1, input2, lang).include? target_pair
end

def pair_related_oughta_contain(input1, input2, output1, output2, is_working=true)
  lang = "en"
  if(is_working)
    test_name = "pair_related #{lang}: #{input1} / #{input2} -> #{output1} / #{output2}"
    it test_name do
      expect(pair_related_contains?(lang, input1, input2, output1, output2)).to eql(true), "Pair-related rhymes in #{lang} for '#{input1}' / '#{input2}' oughta include '#{output1}' (#{debug_info(output1, lang)}) / '#{output2}' (#{debug_info(output2, lang)}), but instead we just get #{find_rhyming_pairs(input1, input2, lang)}"
    end
  else # NOT_WORKING
    if TEST_FOR_SURPRISING_SUCCESSES
      pair_related_ought_not_contain(input1, input2, output1, output2, true)
    end
  end
end

def pair_related_ought_not_contain(input1, input2, output1, output2, is_working=true)
  lang = "en"
  if(is_working)
    test_name = "pair_related #{lang}: #{input1} / #{input2} !-> #{output1} / #{output2}"
    it test_name do
      expect(pair_related_contains?(lang, input1, input2, output1, output2)).to eql(false), "Pair-related rhymes for '#{input1}' / '#{input2}' ought not include '#{output1}' / '#{output2}'"
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
    pair_related_ought_not_contain 'food', 'evil', 'sanitation', 'temptation'
    pair_related_ought_not_contain 'food', 'evil', 'healthy', 'unhealthy'
    pair_related_ought_not_contain 'food', 'evil', 'contamination', 'condemnation'
    pair_related_oughta_contain 'food', 'evil', 'savory', 'slavery', NOT_WORKING
    pair_related_ought_not_contain 'food', 'evil', 'savoury', 'slavery'
    pair_related_oughta_contain 'food', 'evil', 'crumb', 'scum'
    pair_related_oughta_contain 'food', 'evil', 'organic', 'satanic'
    pair_related_oughta_contain 'food', 'evil', 'starvation', 'abomination'
    pair_related_oughta_contain 'food', 'evil', 'wine', 'malign'
    pair_related_oughta_contain 'food', 'evil', 'dessert', 'hurt'
    pair_related_ought_not_contain 'food', 'evil', 'produce', 'abuse', NOT_WORKING # the food sense of 'produce' is pronounced PRO-duce, which ought not rhyme with 'abuse'
  end

  context 'food dark' do
    pair_related_oughta_contain 'food', 'dark', 'turkey', 'murky'
  end

end

#
# related_rhymes
#

def related_rhymes?(input_rhyme, input_related, output, lang)
  # Generate words that rhyme with input_related and are related to input_related.
  # Is OUTPUT one of them?
  # e.g. 'please', 'cats', 'siamese'
  find_related_rhymes(input_rhyme, input_related, lang).include?(output)
end

def related_rhymes_oughta_contain(input_rhyme, input_related, output, is_working=true)
  lang = 'en'
  if(is_working)
    test_name = "related_rhymes #{input_rhyme} + #{input_related} -> #{output}"
    it test_name do
      expect(related_rhymes?(input_rhyme, input_related, output, lang)).to eql(true), "'#{output}' (#{debug_info(output, lang)}) oughta be one of the words that rhyme with '#{input_rhyme}' (#{debug_info(input_rhyme, lang)}) and is related to '#{input_related}'"
    end
  else # NOT_WORKING
    if TEST_FOR_SURPRISING_SUCCESSES
      related_rhymes_ought_not_contain(input_rhyme, input_related, output, true)
    end
  end
end

def related_rhymes_ought_not_contain(input_rhyme, input_related, output, is_working=true)
  lang = 'en'
  if(is_working)
    test_name = "related_rhymes #{input_rhyme} + #{input_related} !-> #{output}"
    it test_name do
      expect(related_rhymes?(input_rhyme, input_related, output, lang)).to eql(true), "'#{output}' (#{debug_info(output, lang)}) ought not one of the words that rhyme with '#{input_rhyme}' (#{debug_info(input_rhyme, lang)}) and is related to '#{input_related}'"
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
