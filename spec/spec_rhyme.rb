#
# rhymes
#

def oughta_rhyme(word1, word2, is_working=true)
  oughta_rhyme_one_way(word1, word2, is_working)
  oughta_rhyme_one_way(word2, word1, is_working)
end

def oughta_rhyme_one_way(word1, word2, is_working=true)
  if is_working
    test_name = "'#{word1}' oughta have '#{word2}' in its list of rhymes"
    it test_name do
      expect(find_preferred_rhyming_words(word1).include?(word2)).to eql(true), "'#{word1}' (#{debug_info(word1)}) oughta include '#{word2}' ((#{debug_info(word2)}) in its list of rhymes, but instead it only rhymes with #{find_preferred_rhyming_words(word1)}"
    end
  else # NOT_WORKING
    if TEST_FOR_SURPRISING_SUCCESSES
      ought_not_rhyme_one_way(word1, word2, true)
    end
  end
end

def ought_not_rhyme(word1, word2, is_working=true)
  ought_not_rhyme_one_way(word1, word2, is_working)
  ought_not_rhyme_one_way(word2, word1, is_working)
end

def ought_not_rhyme_one_way(word1, word2, is_working=true)
  if is_working
    test_name = "'#{word1}' ought not have '#{word2}' in its list of rhymes"
    it test_name do
      expect(find_preferred_rhyming_words(word1).include?(word2)).to eql(false), "'#{word1}' (#{debug_info(word1)}) ought not include '#{word2}' (#{debug_info(word2)}) as a rhyme, but it does, and it also rhymes with #{find_preferred_rhyming_words(word1)}"
    end
  else # NOT_WORKING
    if TEST_FOR_SURPRISING_SUCCESSES
      oughta_rhyme_one_way(word1, word2, true)
    end
  end
end

def could_go_either_way(word1, word2, is_working=true)
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
    ought_not_rhyme 'axolotl', 'bottle' # stress mismatch, but I don't hate it
    ought_not_rhyme 'axolotls', 'bottles'  # stress mismatch, but I don't hate it
  end

  context 'perfect rhymes must rhyme the last primary-stressed syllable, not just the last syllable' do
    ought_not_rhyme 'station', 'shun'
    ought_not_rhyme 'under', 'fur'
    ought_not_rhyme 'tea', 'bounty'
    ought_not_rhyme 'eyeball', 'mall'
    ought_not_rhyme 'eyeball', 'ball'
    oughta_rhyme 'eyeball', 'highball', NOT_WORKING # wiktionary lacks a pronunciation for 'highball'
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
    oughta_rhyme 'upend', 'pend' # , NOT_WORKING # 'upend' isn't in cmudict, and if it were, we'd get an incorrect syllable boundary anyway
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
    oughta_rhyme 'table', 'disable'
    oughta_rhyme 'sable', 'disable' # , NOT_WORKING # arguable
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
    ought_not_rhyme_one_way 'advisable', 'realisable' # , NOT_WORKING # ...but not realisable with an s
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
    oughta_rhyme 'nato', 'tomato'
    oughta_rhyme 'tv', 'fee'
    oughta_rhyme 'high', 'ai'
  end

  context 'schwas' do
    oughta_rhyme 'picked', 'tricked'
    oughta_rhyme 'chicked', 'tricked'
    oughta_rhyme 'chucked', 'trucked'
    ought_not_rhyme 'picked', 'trucked'
    ought_not_rhyme 'chicked', 'trucked'
    ought_not_rhyme 'can', 'done'
    oughta_rhyme 'supplemented', 'invented' # IH D oughta get dwimmed to AH D
  end

  context 'd vs. t' do
    # Many pairs below expect NA intervocalic flapping (T~D) as alternate prons; triage NOT_WORKING until implemented.
    ought_not_rhyme 'need', 'meat'
    oughta_rhyme 'needy', 'meaty'
    oughta_rhyme 'neediest', 'greediest'
    oughta_rhyme 'meatiest', 'greediest'
    ought_not_rhyme 'panties', 'candies'
    ought_not_rhyme 'ants', 'hands'
    ought_not_rhyme 'kitten', 'hidden'
    oughta_rhyme 'kitten', 'smitten'
    ought_not_rhyme 'hidden', 'smitten'
    oughta_rhyme 'hidden', 'forbidden'
    ought_not_rhyme 'kitten', 'forbidden'
    oughta_rhyme 'little', 'riddle'
    oughta_rhyme 'litter', 'bidder' # arguable
    oughta_rhyme 'batter', 'madder'
    oughta_rhyme 'bottle', 'model'

    # --- Classic T/D minimal pairs (intervocalic; GA flap neutralization) ---
    context 'identical rhymes' do
      ought_not_rhyme 'metal', 'medal'
      ought_not_rhyme 'petal', 'peddle'
      ought_not_rhyme 'bitter', 'bidder'
      ought_not_rhyme 'batter', 'badder'
      ought_not_rhyme 'better', 'bedder'
      ought_not_rhyme 'writer', 'rider'
      ought_not_rhyme 'rated', 'raided'
      ought_not_rhyme 'waited', 'waded'
      ought_not_rhyme 'coated', 'coded'
      ought_not_rhyme 'cited', 'sided'
      ought_not_rhyme 'fated', 'faded'
      ought_not_rhyme 'shutter', 'shudder'
      ought_not_rhyme 'otter', 'odder'
      ought_not_rhyme 'plotter', 'plodder'
      ought_not_rhyme 'chatter', 'chadder'
      ought_not_rhyme 'scatter', 'scadder'
      ought_not_rhyme 'patter', 'padder'
      ought_not_rhyme 'liter', 'leader'
      ought_not_rhyme 'kitty', 'kiddie'
      ought_not_rhyme 'ditty', 'diddy'
    end

    # --- Classic T/D minimal pairs (intervocalic; GA flap neutralization) ---
    oughta_rhyme 'party', 'hardy' # R before T; flap often applies (party ~ hardy in songs)
    ought_not_rhyme 'water', 'wader'
    ought_not_rhyme 'totally', 'dally'
    ought_not_rhyme 'pitted', 'padded'
    oughta_rhyme 'ladder', 'clatter'

    # --- /nt/ cluster & syllabic -n (nasal flap, glottal, no merger) ---
    ought_not_rhyme 'winter', 'winner' # controversial: nasal flap merger for many US speakers
    ought_not_rhyme 'mint', 'mind'
    could_go_either_way 'bitten', 'forbidden' # minimal pair; often distinct (glottal vs D)
    could_go_either_way 'written', 'ridden'
    oughta_rhyme 'kitten', 'mitten'
    ought_not_rhyme 'button', 'bun' # glottal / nasal; not a perfect -uddle rhyme

    # --- Initial / cluster: no intervocalic flap ---
    oughta_rhyme 'train', 'drain'
    oughta_rhyme 'try', 'dry'
    oughta_rhyme 'tame', 'dame'
    oughta_rhyme 'tear', 'deer' # homophone set; tear(rip) vs tear(cry)
    ought_not_rhyme 'stunt', 'done'
    ought_not_rhyme 'step', 'depth'

    # --- Following syllable stressed: often no word-internal flap (review each) ---
    oughta_rhyme 'latex', 'paychecks'
    ought_not_rhyme 'latex', 'climax'
    oughta_rhyme 'potato', 'tomato' # iconic

    # --- -er agent nouns & similar ---
    ought_not_rhyme 'sitter', 'cedar' # wrong onset
    ought_not_rhyme 'fitter', 'fiddler'
    oughta_rhyme 'hitter', 'bidder'
    ought_not_rhyme 'jotter', 'gaudier'

    # --- Past -ed (T vs D allomorph) ---
    ought_not_rhyme 'faint', 'pained'
    oughta_rhyme 'fated', 'faded'
    ought_not_rhyme 'bated', 'bayed'
    oughta_rhyme 'matted', 'padded'
    ought_not_rhyme 'wanted', 'sanded'
    ought_not_rhyme 'wanted', 'absconded'
    ought_not_rhyme 'sorted', 'sordid' # identical rhyme
    oughta_rhyme 'carded', 'carted'

    # --- Long / morphological (Withgott-style: flap may fail) ---

    # --- Homophone / spelling-variant traps ---

    # --- More positive candidates (informal or regional spellings marked) ---
    oughta_rhyme 'latter', 'ladder'
    oughta_rhyme 'matter', 'madder'
    oughta_rhyme 'spotter', 'fodder'
    oughta_rhyme 'solder', 'fodder'
    oughta_rhyme 'totter', 'todder'
    ought_not_rhyme 'cotter', 'coddler'
    ought_not_rhyme 'brittle', 'bridle'
    oughta_rhyme 'kettle', 'medal'
    oughta_rhyme 'cattle', 'battle' # both T; control
    oughta_rhyme 'settled', 'meddled'
    ought_not_rhyme 'settled', 'saddled'
    oughta_rhyme 'titled', 'idled' # T AY T AH L D vs AY D AH L D — tricky
    oughta_rhyme 'tilted', 'jilted' # both T
    ought_not_rhyme 'jilted', 'gilded'
    oughta_rhyme 'belted', 'melted' # both T/D in melt — both have T
    oughta_rhyme 'party', 'tardy'

    # --- Liquids before T (flap often applies after R; L is dialectal) ---
    oughta_rhyme 'faulty', 'salty' # T vs L cluster — different
    ought_not_rhyme 'filter', 'builder' # F IH1 L T ER vs B IH1 L D ER — ought_not
    ought_not_rhyme 'falter', 'alder' # F AO1 L T ER vs AO1 L D ER
    ought_not_rhyme 'falter', 'folder'

    # --- -ity / -ety (T in middle) ---
    oughta_rhyme 'pity', 'biddy'

    # --- Misc edge ---
    oughta_rhyme 'fiddle', 'little'
    ought_not_rhyme 'throttle', 'waddle' # THR vs W
    oughta_rhyme 'bottle', 'wattle' # both flap-like env; wattle W AA1 T AH L vs B AA1 T AH L
    oughta_rhyme 'bottle', 'throttle'
    oughta_rhyme 'bottled', 'modeled'
    oughta_rhyme 'rattle', 'paddle' # R AE1 T AH L vs P AE1 D AH L
    oughta_rhyme 'cheetah', 'pita'
    ought_not_rhyme 'data', 'later' # don't elide final R in American English
    ought_not_rhyme 'beta', 'meta'
    oughta_rhyme 'beta', 'theta'
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
    ought_not_rhyme 'flaws', 'inlaws' #, NOT_WORKING # ...but not with the dispreferred form.
    ought_not_rhyme 'inlaws', 'in-laws'
    ought_not_rhyme 'nonbuilding', 'non-building'
    ought_not_rhyme 'cul-de-sac', 'back' # stress mismatch
    oughta_rhyme 'avant-garde', 'hard'
    oughta_rhyme 'topsy-turvy', 'scurvy'
    ought_not_rhyme 'ping-pong', 'wrong' # stress mismatch
    oughta_rhyme 'okey-dokey', 'hokey'
    ought_not_rhyme 'flim-flam', 'slam' # stress mismatch
    oughta_rhyme 'papier-mache', 'way'
    oughta_rhyme 'tutti-frutti', 'booty'
    oughta_rhyme 'willy-nilly', 'silly'
    oughta_rhyme 'roly-poly', 'holy'
    ought_not_rhyme 'roly-poly', 'poly'
    oughta_rhyme 'hara-kiri', 'weary'
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
    oughta_rhyme 'lad', 'vlad'# , NOT_WORKING # 'vlad' gets syllabified as V . L AE D
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
    ought_not_rhyme 'selfie', 'healthy' #F != TH
  end
  
  context 'loan words' do
    oughta_rhyme 'amour', 'bonjour'
    ought_not_rhyme 'bocce', 'mocha'
  end

  context 'modern words' do
    oughta_rhyme 'yeet', 'feet'
    oughta_rhyme 'yeets', 'feats'
    oughta_rhyme 'yeeted', 'defeated'
    oughta_rhyme 'yeeting', 'defeating'
    oughta_rhyme 'meme', 'team'
    oughta_rhyme 'memes', 'teams'
    oughta_rhyme 'blog', 'log'
    oughta_rhyme 'blogs', 'logs'
    oughta_rhyme 'blogged', 'logged'
    oughta_rhyme 'blogging', 'logging'
    oughta_rhyme 'couple', 'throuple'
    oughta_rhyme 'couples', 'throuples'
    oughta_rhyme 'url', 'hell'
    oughta_rhyme 'urls', 'smells'
    ought_not_rhyme 'url', 'curl'
  end

  context '-er' do
    ought_not_rhyme 'freer', 'beer'
    oughta_rhyme 'freer', 'seer'
    ought_not_rhyme 'seer', 'beer'
  end

  context 'common_words.txt' do
    ought_not_rhyme 'log', 'catalog'
    oughta_rhyme 'knight', 'fight'
    oughta_rhyme 'knighting', 'fighting'
    oughta_rhyme 'nighter', 'fighter'
    oughta_rhyme 'handout', 'standout'
    oughta_rhyme 'locker', 'clocker'
    ought_not_rhyme 'fails', 'entrails' # 'entrails' stress is on the first syllable
    oughta_rhyme 'guess', 'finesse'
    oughta_rhyme 'nest', 'finessed', NOT_WORKING # it's an identical rhyme. I'd like to include it but I don't know how without including unwanted identical rhymes
    oughta_rhyme 'keto', 'mosquito'
    oughta_rhyme 'bold', 'oversold'
    oughta_rhyme 'vibe', 'unsubscribe'
    oughta_rhyme 'vibes', 'unsubscribes'
    oughta_rhyme 'vibed', 'unsubscribed'
    ought_not_rhyme 'vibe', 'unsubscribed'
    ought_not_rhyme 'vibe', 'unsubscribes'
    ought_not_rhyme 'vibed', 'unsubscribe'
    ought_not_rhyme 'vibes', 'unsubscribe'
    ought_not_rhyme 'vibed', 'unsubscribes'
    oughta_rhyme 'vibing', 'unsubscribing'
  end

    # TODO: rezoned (and thus these specs) want a pron from re- + zoned: prepend e.g. R IH0 or R IY0
    # plus a syllable boundary before zoned's CMU string. General prefix morphology is overkill for this alone.
  context 'prefix morphology' do
    oughta_rhyme 'owned', 'zoned'
    oughta_rhyme 'unowned', 'zoned', NOT_WORKING
    oughta_rhyme 'owned', 'rezoned', NOT_WORKING
    oughta_rhyme 'unowned', 'rezoned', NOT_WORKING
  end
end
