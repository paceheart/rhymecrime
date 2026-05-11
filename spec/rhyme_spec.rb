#
# rhymes
#

def oughta_rhyme(word1, word2, not_working_reason: nil)
  oughta_rhyme_one_way(word1, word2, not_working_reason: not_working_reason)
  oughta_rhyme_one_way(word2, word1, not_working_reason: not_working_reason)
end

def oughta_rhyme_one_way(word1, word2, not_working_reason: nil)
  test_name = "'#{word1}' oughta have '#{word2}' in its list of rhymes"
  it test_name do
    skip_if_not_working(not_working_reason)
    rhymes = find_preferred_rhyming_words(word1)
    # Accept any spelling variant of word2: the rhyme list only contains preferred forms,
    # so if the spec names a dispreferred variant (spectre vs specter, cord vs chord)
    # we still want the positive test to pass. The negative matcher stays literal so tests
    # like ought_not_rhyme_one_way 'goner', 'honour' (which specifically assert the
    # dispreferred form is filtered) still do what they say.
    word2_forms = all_forms(word2)
    matched = (rhymes & word2_forms).any?
    expect(matched).to eql(true), "'#{word1}' (#{debug_info(word1)}) oughta include '#{word2}' ((#{debug_info(word2)}) in its list of rhymes, but instead it only rhymes with #{rhymes}"
  end
end

def ought_not_rhyme(word1, word2, not_working_reason: nil)
  ought_not_rhyme_one_way(word1, word2, not_working_reason: not_working_reason)
  ought_not_rhyme_one_way(word2, word1, not_working_reason: not_working_reason)
end

def ought_not_rhyme_one_way(word1, word2, not_working_reason: nil)
  test_name = "'#{word1}' ought not have '#{word2}' in its list of rhymes"
  it test_name do
    skip_if_not_working(not_working_reason)
    expect(find_preferred_rhyming_words(word1).include?(word2)).to eql(false), "'#{word1}' (#{debug_info(word1)}) ought not include '#{word2}' (#{debug_info(word2)}) as a rhyme, but it does, and it also rhymes with #{find_preferred_rhyming_words(word1)}"
  end
end

def could_go_either_way(word1, word2, not_working_reason: nil)
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
    oughta_rhyme "sphere", 'queer'
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
    oughta_rhyme 'spiral', 'viral'
    ought_not_rhyme 'eyes', 'sees' # this was a bug due to two pronunciations of 'reprise'
    ought_not_rhyme 'biopic', 'myopic'
    oughta_rhyme 'poor', 'pure' # P vs. PY is different enough
  end

  context 'perfect rhymes must rhyme the last primary-stressed syllable, not just the last syllable' do
    ought_not_rhyme 'station', 'shun'
    ought_not_rhyme 'under', 'fur'
    ought_not_rhyme 'tea', 'bounty'
    ought_not_rhyme 'eyeball', 'mall'
    ought_not_rhyme 'eyeball', 'ball'
    oughta_rhyme 'eyeball', 'highball'
    ought_not_rhyme 'painting', 'ring'
  end

  context 'no self-rhymes' do
    ought_not_rhyme 'red', 'red'
  end
  
  context "homophones ought not count as rhymes" do
    ought_not_rhyme 'principle', 'principal'
    ought_not_rhyme 'side', 'sighed'
    ought_not_rhyme 'blue', 'blew'
    ought_not_rhyme 'base', 'bass'
    ought_not_rhyme 'coral', 'choral'
    ought_not_rhyme 'leader', 'lieder'
    ought_not_rhyme 'lindsay', 'lindsey'
    ought_not_rhyme 'hanukkah', 'chanukah' # what if the initial sounds are different, though? Then how do we know to eliminate this?
    ought_not_rhyme 'adherence', 'adherents', not_working_reason: "these aren't true homophones, but we forget that when we elide the T"
    ought_not_rhyme 'moray', 'more'
    ought_not_rhyme 'morays', 'mores'
    ought_not_rhyme 'trustee', 'trusty'
    ought_not_rhyme 'sundae', 'sunday'
    ought_not_rhyme 'marquee', 'marquis'
    ought_not_rhyme 'in', 'inn'
    ought_not_rhyme 'been', 'bin'
    context "'lay' ought not rhyme with 'lei'..." do
      ought_not_rhyme 'lay', 'lei'
    end
    context "...but 'bay' oughta rhyme with both of 'em" do
      oughta_rhyme 'bay', 'lay'
      oughta_rhyme 'bay', 'lei'
    end
  end
  
  context "you can't just add a prefix and call it a rhyme" do
    ought_not_rhyme 'activate', 'deactivate'
    ought_not_rhyme 'activating', 'deactivating'
    ought_not_rhyme 'sea', 'undersea'
    ought_not_rhyme 'arctic', 'antarctic'
    ought_not_rhyme 'appropriate', 'misappropriate'
    ought_not_rhyme 'racial', 'biracial'
    ought_not_rhyme 'erotic', 'homoerotic'
    ought_not_rhyme 'sexual', 'homosexual'
    ought_not_rhyme 'sexing', 'unsexing'
    ought_not_rhyme 'sex', 'same-sex'
    ought_not_rhyme 'orient', 'reorient'
    ought_not_rhyme 'orient', 'disorient'
    ought_not_rhyme 'reorient', 'disorient'
    ought_not_rhyme 'orienting', 'reorienting'
    ought_not_rhyme 'orienting', 'disorienting'
    ought_not_rhyme 'reorienting', 'disorienting'
    oughta_rhyme 'grape', 'ape' # gr- is not a prefix
    oughta_rhyme 'pot', 'spot' # s- is not a prefix
    oughta_rhyme 'under', 'plunder' # pl- is not a prefix
    ought_not_rhyme 'promising', 'unpromising'
    ought_not_rhyme 'diversity', 'biodiversity'
    ought_not_rhyme 'ion', 'anion' # an- is a chemistry prefix
    ought_not_rhyme 'ion', 'cation' # cat- is a chemisty prefix
    oughta_rhyme 'able', 'cable' # control
    oughta_rhyme 'unable', 'cable' # control
    ought_not_rhyme 'able', 'unable' # un- is a prefix
    oughta_rhyme 'cable', 'disable' # control
    ought_not_rhyme 'able', 'disable' # dis- is a prefix
    ought_not_rhyme 'unable', 'disable' # two prefixes
    oughta_rhyme 'able', 'sable' # s- is not a prefix
    oughta_rhyme 'table', 'disable'
    ought_not_rhyme 'enchant', 'disenchant'
    ought_not_rhyme 'enchanted', 'disenchanted'
    oughta_rhyme 'ice', 'dice'
    ought_not_rhyme 'ice', 'deice' # de- is a prefix, but deice (de-ice) is not in cmudict, so this succeeds for the wrong reason
    oughta_rhyme 'stand', 'strand' # control
    oughta_rhyme 'understand', 'strand' # control
    ought_not_rhyme 'organizing', 'reorganizing' # re-
    ought_not_rhyme 'organizing', 'self-organizing' # self-
    ought_not_rhyme 'urban', 'suburban' # sub-
    ought_not_rhyme 'urbanize', 'suburbanize' # sub-
    ought_not_rhyme 'america', 'midamerica' # mid-
    ought_not_rhyme 'america', 'microamerica' # micro-
    ought_not_rhyme 'pure', 'impure' # im-
    ought_not_rhyme 'print', 'imprint' # im-
    ought_not_rhyme 'prison', 'imprison' # im-
    ought_not_rhyme 'open', 'reopen' # re-
    ought_not_rhyme 'opened', 'unopened' # un-
    ought_not_rhyme 'mixed', 'unmixed' # un-
    ought_not_rhyme 'mixed', 'intermixed' # inter-
    ought_not_rhyme 'unmixed', 'intermixed' # inter-
    ought_not_rhyme 'operate', 'interoperate' # inter-
    oughta_rhyme 'operate', 'cooperate' # arguable
    ought_not_rhyme 'indicated', 'contraindicated' # contra-
    ought_not_rhyme 'emphasize', 'deemphasize' # de-
    ought_not_rhyme 'closed', 'enclosed' # en-
    ought_not_rhyme 'close', 'enclose' # en-, but trickier because 'close' can mean 'nearby' in which case it's pronounced differently
    ought_not_rhyme 'act', 'enact' # en-
    ought_not_rhyme 'urb', 'exurb' # ex-
    ought_not_rhyme 'ordinary', 'extraordinary' # extra-
    ought_not_rhyme 'exempt', 'preempt' # arguable
    ought_not_rhyme 'human', 'subhuman' # sub-
    ought_not_rhyme 'human', 'superhuman' # super-
    ought_not_rhyme 'subhuman', 'superhuman' # sub- + super-
    ought_not_rhyme 'active', 'hyperactive' # hyper-
    ought_not_rhyme 'inactive', 'hyperactive' # in- + hyper-
    ought_not_rhyme 'operate', 'teleoperate' # tele-
    ought_not_rhyme 'logical', 'teleological' # teleo-
    ought_not_rhyme 'enemy', 'archenemy' # arch-
    ought_not_rhyme 'enemies', 'archenemies' # arch-
    ought_not_rhyme 'villain', 'archvillain' # arch-
    ought_not_rhyme 'villains', 'archvillains' # arch-
    ought_not_rhyme 'distribution', 'redistribution' # re-
    ought_not_rhyme 'loading', 'unloading' # un-
    ought_not_rhyme 'loading', 'reloading' # re-
    ought_not_rhyme 'loading', 'offloading' # off-
    ought_not_rhyme 'fitted', 'refitted' # re-
    ought_not_rhyme 'join', 'enjoin' # en-
    ought_not_rhyme 'join', 'rejoin' # re-
    ought_not_rhyme 'wind', 'upwind' # up- + 
    ought_not_rhyme 'wind', 'downwind' # down-
    ought_not_rhyme 'upwind', 'downwind' # up- + down-
    # upwind has two cmudict prons (AH P W IH N D for the direction, AH P W AY N D for
    # the verb). The second shares a rime with find, so this only fails because both prons
    # are accepted. Fixing properly needs primary-pron selection or a morphological check
    # that upwind's root is wind (not find).
    ought_not_rhyme 'find', 'upwind'
    ought_not_rhyme 'game', 'pregame' # pre-
    ought_not_rhyme 'game', 'postgame' # post-
    ought_not_rhyme 'space', 'hyperspace' # hyper-
    ought_not_rhyme 'atlantic', 'transatlantic' # trans-
    ought_not_rhyme 'pacific', 'transpacific' # trans-
    ought_not_rhyme 'legal', 'illegal' # il-
    ought_not_rhyme 'alcoholic', 'non-alcoholic' # non-
    ought_not_rhyme 'subordinate', 'insubordinate' # in-
    ought_not_rhyme 'live', 'outlive' # out-
    ought_not_rhyme 'verbal', 'nonverbal' # non-
    ought_not_rhyme 'western', 'northwestern' # north-
    ought_not_rhyme 'western', 'southwestern' # south-
    ought_not_rhyme 'western', 'northwestern' # north-
    ought_not_rhyme 'western', 'midwestern' # mid-
    ought_not_rhyme 'midwestern', 'northwestern' # mid- + north-
    ought_not_rhyme 'eastern', 'northeastern' # north-
    ought_not_rhyme 'eastern', 'southeastern' # south-
    ought_not_rhyme 'eastern', 'northeastern' # north-
    ought_not_rhyme 'eastern', 'mideastern' # mid-
    ought_not_rhyme 'mideastern', 'northeastern' # mid- + north-
    ought_not_rhyme 'lay', 'overlay' # over-
    ought_not_rhyme 'lay', 'underlay' # under-
    ought_not_rhyme 'overlay', 'underlay' # over- + under-
    ought_not_rhyme 'lie', 'underlie' # under-
    ought_not_rhyme 'lying', 'underlying', not_working_reason: 'arguable; B says yes'
    oughta_rhyme 'owned', 'zoned'
    oughta_rhyme 'unowned', 'zoned', not_working_reason: "TODO: unowned lacks pron"
    oughta_rhyme 'owned', 'rezoned', not_working_reason: "TODO: rezoned lacks pron"
    oughta_rhyme 'unowned', 'rezoned', not_working_reason: "TODO: unowned and rezoned lack prons"
    ought_not_rhyme 'atonal', 'tonal' # a-
    ought_not_rhyme 'flame', 'aflame' # a-
    ought_not_rhyme 'round', 'around' # a-
    ought_not_rhyme 'ground', 'aground' # a-
    ought_not_rhyme 'sexual', 'asexual' # a-
    ought_not_rhyme 'shore', 'ashore' # a-
    ought_not_rhyme 'social', 'asocial' # a-
    ought_not_rhyme 'thermic', 'athermic' # a-
    ought_not_rhyme 'biotic', 'abiotic' # a-
    ought_not_rhyme 'caudal', 'acaudal' # a-
    ought_not_rhyme 'causal', 'acausal' # a-
    ought_not_rhyme 'buzz', 'abuzz' # a-
    ought_not_rhyme 'chromatic', 'achromatic' # a-
    ought_not_rhyme 'thermic', 'exothermic' # exo-
    ought_not_rhyme 'thermic', 'endothermic' # endo-
    ought_not_rhyme 'social', 'antisocial' # anti-
    ought_not_rhyme 'war', 'antiwar' # anti-
    ought_not_rhyme 'composition', 'decomposition' # de-
    oughta_rhyme 'chanted', 'enchanted' # arguable
    oughta_rhyme 'chanted', 'disenchanted' # arguable
    ought_not_rhyme 'enchanted', 'disenchanted' # en- + dis- en-
    ought_not_rhyme 'dishonesty', 'honesty' # dis-
    ought_not_rhyme 'healthy', 'unhealthy' # un-
    ought_not_rhyme 'side', 'beside' # be-
    ought_not_rhyme 'side', 'alongside' # along-
    ought_not_rhyme 'beside', 'alongside' # be- + along-
    ought_not_rhyme 'applied', 'misapplied' # mis-
    ought_not_rhyme 'recorded', 'prerecorded' # pre-
    ought_not_rhyme 'ordinate', 'subordinate' # sub-
    ought_not_rhyme 'ordinate', 'insubordinate' # in- sub-
    ought_not_rhyme 'subordinate', 'insubordinate' # in-
    ought_not_rhyme 'other', 'another' # arguable; an- is... kind of a prefix?
    ought_not_rhyme 'deserved', 'undeserved' # un-
    ought_not_rhyme 'legitimate', 'illegitimate' # il-
    ought_not_rhyme 'safe', 'unsafe'
    ought_not_rhyme 'kind', 'unkind'
    ought_not_rhyme 'bisect', 'trisect'
    ought_not_rhyme 'bisect', 'intersect'
    ought_not_rhyme 'bienneal', 'triennial'
    ought_not_rhyme 'centennial', 'bicentennial'
    oughta_rhyme 'centennial', 'biennial'
    ought_not_rhyme 'train', 'retrain'
    ought_not_rhyme 'derive', 'rederive'
    ought_not_rhyme 'distribute', 'redistribute'
    ought_not_rhyme 'person', 'businessperson'
    ought_not_rhyme 'person', 'layperson'
    ought_not_rhyme 'businessperson', 'layperson'
    ought_not_rhyme 'man', 'layman'
    ought_not_rhyme 'entity', 'nonentity'
    ought_not_rhyme 'entity', 'non-entity'
    context "unless they're not derivationally related" do
      oughta_rhyme 'tract', 'retract'
      oughta_rhyme 'tractor', 'retractor'
      oughta_rhyme 'parity', 'disparity'
      oughta_rhyme 'dress', 'redress'
      oughta_rhyme 'percussion', 'repercussion'
      oughta_rhyme 'lied', 'relied'
      oughta_rhyme 'quest', 'request'
      oughta_rhyme 'corded', 'recorded'
      oughta_rhyme 'tween', 'between'
      oughta_rhyme 'basement', 'abasement'
      oughta_rhyme 'bashed', 'abashed'
      oughta_rhyme 'but', 'abut'
      oughta_rhyme 'do', 'ado'
      oughta_rhyme 'go', 'ago'
      oughta_rhyme 'head', 'ahead'
      oughta_rhyme 'pathetic', 'apathetic'
      oughta_rhyme 'spire', 'aspire'
      oughta_rhyme 'void', 'avoid'
      oughta_rhyme 'based', 'abased'
      oughta_rhyme 'bode', 'abode'
      oughta_rhyme 'bodes', 'abodes'
      oughta_rhyme 'butter', 'abutter'
      oughta_rhyme 'pact', 'impact'
      oughta_rhyme 'peach', 'impeach'
      oughta_rhyme 'plied', 'implied'
      oughta_rhyme 'port', 'import' # arguable
      oughta_rhyme 'pound', 'impound'
      oughta_rhyme 'prove', 'improve'
      oughta_rhyme 'marine', 'submarine'
      oughta_rhyme 'tract', 'subtract'
      oughta_rhyme 'lime', 'sublime'
      oughta_rhyme 'due', 'subdue'
      oughta_rhyme 'scribe', 'subscribe'
      oughta_rhyme 'merge', 'submerge'
      oughta_rhyme 'sect', 'intersect'
      oughta_rhyme 'turn', 'return'
      oughta_rhyme 'member', 'remember'
      oughta_rhyme 'mind', 'remind'
      context "arguable" do
        oughta_rhyme 'bide', 'abide', not_working_reason: 'edge case'
        oughta_rhyme 'new', 'anew', not_working_reason: 'edge case'
        oughta_rhyme 'part', 'apart', not_working_reason: 'edge case'
        oughta_rhyme 'rise', 'arise', not_working_reason: 'edge case'
        ought_not_rhyme 'stand', 'understand', not_working_reason: "under- is a prefix, but 'understand' arguably has its own meaning"
        oughta_rhyme 'wait', 'await', not_working_reason: 'edge case'
        oughta_rhyme 'waits', 'awaits', not_working_reason: 'edge case'
        oughta_rhyme 'wake', 'awake', not_working_reason: 'edge case'
        oughta_rhyme 'wakes', 'awakes', not_working_reason: 'edge case'
        oughta_rhyme 'waken', 'awaken', not_working_reason: 'edge case'
        oughta_rhyme 'wakening', 'awakening', not_working_reason: 'edge case'
        oughta_rhyme 'woke', 'awoke', not_working_reason: 'edge case'
        oughta_rhyme 'woken', 'awoken', not_working_reason: 'edge case'
      end
    end
  end

  context "identical rimes" do
    oughta_rhyme 'fuse', 'diffuse'
    oughta_rhyme 'fusion', 'diffusion'
    oughta_rhyme 'leave', 'believe'
    oughta_rhyme 'troll', 'patrol'
    oughta_rhyme 'troll', 'control'
    oughta_rhyme 'end', 'pend'
    oughta_rhyme 'end', 'append'
    oughta_rhyme 'pend', 'append' # identical
    oughta_rhyme 'upend', 'pend' # skipped candidate: 'upend' isn't in cmudict, and if it were, we'd get an incorrect syllable boundary anyway
    ought_not_rhyme 'end', 'upend' # working for the wrong reasons: 'upend' isn't in cmudict, and if it were, we'd get an incorrect syllable boundary anyway
    oughta_rhyme 'confide', 'defied'
    oughta_rhyme 'plied', 'applied' # ap- is not a prefix
    oughta_rhyme 'complied', 'applied'
    oughta_rhyme 'illicit', 'solicit' # I'm sad that these are rich rhymes. illicit [IH2 L IH1 S AH0 T] solicit [S AH0 L IH1 S IH0 T]
    oughta_rhyme 'specter', 'inspector'
    oughta_rhyme 'spectre', 'inspector'
    oughta_rhyme 'supplemented', 'fermented'
    oughta_rhyme 'jar', 'ajar', not_working_reason: 'splash damage: a- prefix filter'
    oughta_rhyme 'bone', 'trombone' # trom- is not a prefix
    oughta_rhyme 'sable', 'disable' # arguable
    oughta_rhyme 'action', 'traction' # tr- is not a prefix
    oughta_rhyme 'action', 'attraction' # attr- is not a prefix
    oughta_rhyme 'traction', 'attraction' # arguable
    oughta_rhyme 'attribution', 'distribution' # arguable
    oughta_rhyme 'nest', 'finessed'
    oughta_rhyme 'keto', 'mosquito'
    oughta_rhyme_one_way 'record', 'cord'
    oughta_rhyme_one_way 'cord', 'record', not_working_reason: 'splash damage: re- prefix filter (record is etymologically re+cord)'
    oughta_rhyme 'chord', 'record'
    # hemiola isn't in our lexicon at all; mandolin/violin have genuinely different rimes
    # (AE_N_D_AH_L_AH_N vs IH_N -- the stress lands in different places), so they
    # can't rhyme under the current primary-stress-rime model.
    oughta_rhyme 'hemiola', 'viola'
    oughta_rhyme 'mandolin', 'violin'
    oughta_rhyme 'exhortations', 'meditations' # arguable
    oughta_rhyme 'composition', 'musician'
    oughta_rhyme 'compositions', 'musicians'
    oughta_rhyme 'condemnation', 'contamination' # arguable
    oughta_rhyme 'extracted', 'reacted'
    oughta_rhyme 'sanitation', 'temptation'
    oughta_rhyme 'totalitarian', 'vegetarian'
    oughta_rhyme 'nation', 'abomination'
    ought_not_rhyme 'corn', 'acorn' # stress mismatch
    # S ER V vs. Z ER V (and plurals/participles), so these aren't actually rich rhymes
    # phonetically. They share the de- shape orthographically and the spelling-only filter
    # used to drop them as splash damage; pron_suffix_aligned? now sees the S → Z onset
    # shift and lets the pair through.
    oughta_rhyme 'serve', 'deserve'
    oughta_rhyme 'served', 'deserved'
    oughta_rhyme 'served', 'undeserved'
    ought_not_rhyme 'served', 'underserved'
    ought_not_rhyme 'millionaire', 'multimillionaire'
    ought_not_rhyme 'meter', 'multimeter'
    ought_not_rhyme 'member', 'dismember'
    ought_not_rhyme 'members', 'dismembers'
    ought_not_rhyme 'science', 'pseudoscience'
    ought_not_rhyme 'scientific', 'pseudoscientific'
    ought_not_rhyme 'automatic', 'semiautomatic'
    ought_not_rhyme 'attack', 'counterattack'
    ought_not_rhyme 'attacked', 'counterattacked'
    ought_not_rhyme 'point', 'counterpoint'
    ought_not_rhyme 'espionage', 'counterespionage'
    ought_not_rhyme 'indicated', 'contraindicated'
    ought_not_rhyme 'house', 'boathouse'
    ought_not_rhyme 'houses', 'boathouses'
    ought_not_rhyme 'house', 'slaughterhouse'
    ought_not_rhyme 'houses', 'slaughterhouses'
    ought_not_rhyme 'mouse', 'boathouse' # stress mismatch
    oughta_rhyme 'arouses', 'houses'
    ought_not_rhyme 'arouses', 'boathouses' # stress mismatch
    ought_not_rhyme 'arouses', 'slaughterhouses' # stress mismatch
    ought_not_rhyme 'boiler', 'potboiler'
    ought_not_rhyme 'boil', 'parboil'
    ought_not_rhyme 'boiled', 'parboiled'
    ought_not_rhyme 'smoking', 'non-smoking'
    ought_not_rhyme 'fuse', 'defuse'
    ought_not_rhyme 'ultimate', 'penultimate'
    ought_not_rhyme 'penultimate', 'antepenultimate'
    ought_not_rhyme 'chamber', 'antechamber'
    ought_not_rhyme 'function', 'dysfunction'
    ought_not_rhyme 'functional', 'dysfunctional'
    ought_not_rhyme 'discovered', 'undiscovered'
    ought_not_rhyme 'men', 'councilmen' # ought to be stress mismatch regardless
    ought_not_rhyme 'medical', 'biomedical'
    ought_not_rhyme 'plastic', 'thermoplastic'
    ought_not_rhyme 'plastics', 'thermoplastics'
    ought_not_rhyme 'nuclear', 'thermonuclear'
    ought_not_rhyme 'dynamic', 'thermodynamic'
    ought_not_rhyme 'dynamics', 'thermodynamics'
    oughta_rhyme 'meter', 'neater'
    ought_not_rhyme 'meter', 'thermometer'
    ought_not_rhyme 'neater', 'thermometer'
    oughta_rhyme 'kilometer', 'thermometer' # kilo- is not in COMMON_PREFIXES, so the filter declines and the shared rime stands

    # Additional Greek combining forms (auto-, bio-, micro-, macro-, mono-, endo-, exo-,
    # hyper-) — same shape as thermo-: prefix peels to a real dict-headword tail with the
    # same rime, primary stress preserved, so the prefix-rhyme filter must fire.
    ought_not_rhyme 'biography', 'autobiography'
    ought_not_rhyme 'feedback', 'biofeedback'
    oughta_rhyme 'topic', 'microscopic'
    ought_not_rhyme 'economic', 'macroeconomic'
    ought_not_rhyme 'lingual', 'monolingual'
    ought_not_rhyme 'lingual', 'bilingual', not_working_reason: "if lingual weren't rare-ish, I would care more about this"
    ought_not_rhyme 'monolingual', 'bilingual'
    ought_not_rhyme 'thermic', 'endothermic'
    ought_not_rhyme 'thermic', 'exothermic'
    ought_not_rhyme 'endothermic', 'exothermic'
    ought_not_rhyme 'active', 'hyperactive'
    # Latin-prefix coverage that extends the existing anti-/non-/post-/inter-/trans-
    # families with rime-identical derivations.
    ought_not_rhyme 'matter', 'antimatter'
    ought_not_rhyme 'biotic', 'abiotic'
    ought_not_rhyme 'biotic', 'antibiotic'
    ought_not_rhyme 'fiction', 'nonfiction'
    ought_not_rhyme 'stop', 'nonstop'
    ought_not_rhyme 'natural', 'supernatural'
    ought_not_rhyme 'national', 'transnational'
    ought_not_rhyme 'venous', 'intravenous'
    ought_not_rhyme 'modern', 'postmodern'
    context "edge cases" do
      oughta_rhyme 'cycling', 'recycling'
      oughta_rhyme 'semblance', 'resemblance'
      oughta_rhyme 'angular', 'rectangular'
      oughta_rhyme 'thesis', 'prosthesis'
      ought_not_rhyme 'thesis', 'antithesis'
      oughta_rhyme 'mediterranean', 'subterranean' # medi- is not a prefix
      ought_not_rhyme 'motion', 'locomotion'
      ought_not_rhyme 'magnet', 'electromagnet'
      ought_not_rhyme 'magnetic', 'electromagnetic'
      oughta_rhyme 'prudence', 'jurisprudence' # they're semantically different enough to be interesting
      ought_not_rhyme 'explosion', 'implosion', not_working_reason: 'arguable; B says yes'
    end
  end

  context "spelling variants ought not count as rhymes" do
    ought_not_rhyme 'adapter', 'adaptor'
    ought_not_rhyme 'impostor', 'imposter'
    oughta_rhyme_one_way 'honour', 'goner' # input honour, you oughta get goner
    oughta_rhyme 'goner', 'honor' # but input goner, and you oughta get honor...
    ought_not_rhyme_one_way 'goner', 'honour' # ...but not honour
    oughta_rhyme_one_way 'realisable', 'advisable' # input realisable, you oughta get advisable
    oughta_rhyme 'advisable', 'realizable' # but input advisable, and you oughta get realizable...
    ought_not_rhyme_one_way 'advisable', 'realisable' # skipped candidate: ...but not realisable with an s
    ought_not_rhyme 'catalog', 'catalogue'
    ought_not_rhyme 'catalogs', 'catalogues'
    ought_not_rhyme 'catalogged', 'catalogued'
    ought_not_rhyme 'cataloging', 'cataloguing'
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
    oughta_rhyme 'mount', 'count'
    ought_not_rhyme_one_way 'count', 'mt'
    ought_not_rhyme 'noaa', 'boa'
    ought_not_rhyme 'ct', 'sort'
    ought_not_rhyme 'ip', 'dip'
  end

  context 'schwas' do
    oughta_rhyme 'picked', 'tricked'
    oughta_rhyme 'chucked', 'trucked'
    ought_not_rhyme 'picked', 'trucked'
    ought_not_rhyme 'can', 'done'
    oughta_rhyme 'supplemented', 'invented' # IH D oughta get dwimmed to AH D
  end

  context 'd vs. t' do
    # Many pairs below expect NA intervocalic flapping (T~D) as alternate prons; triage skipped examples until implemented.
    ought_not_rhyme 'need', 'meat'
    oughta_rhyme 'needy', 'meaty'
    oughta_rhyme 'neediest', 'greediest'
    oughta_rhyme 'meatiest', 'greediest'
    ought_not_rhyme 'panties', 'candies'
    ought_not_rhyme 'ants', 'hands'
    ought_not_rhyme 'kitten', 'hidden' # arguable
    oughta_rhyme 'kitten', 'smitten'
    ought_not_rhyme 'hidden', 'smitten' # arguable
    oughta_rhyme 'hidden', 'forbidden'
    ought_not_rhyme 'kitten', 'forbidden'
    oughta_rhyme 'little', 'riddle'
    oughta_rhyme 'litter', 'bidder' # arguable
    oughta_rhyme 'batter', 'madder'
    oughta_rhyme 'bottle', 'model'
    ought_not_rhyme 'bitty', 'biddy' # these become homophones after flapping, and homophones ought not rhyme
    oughta_rhyme 'bitty', 'titty'
    oughta_rhyme 'biddy', 'titty'

    # --- Classic T/D minimal pairs (intervocalic; GA flap neutralization) ---
    context 'identical rimes' do
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
      ought_not_rhyme 'sorted', 'sordid'
      ought_not_rhyme 'latter', 'ladder'
      ought_not_rhyme 'matter', 'madder'
      oughta_rhyme 'recital', 'suicidal'
    end

    # --- Classic T/D minimal pairs (intervocalic; GA flap neutralization) ---
    oughta_rhyme 'party', 'hardy' # R before T; flap often applies (party ~ hardy in songs)
    ought_not_rhyme 'water', 'wader'
    ought_not_rhyme 'water', 'hoarder' # only in Maryland'
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

    # --- word-initial T vs D: still rhymes if rime matches
    oughta_rhyme 'train', 'drain'
    oughta_rhyme 'try', 'dry'
    oughta_rhyme 'tame', 'dame'
    oughta_rhyme 'tear', 'deer' # homophone set; tear(rip) vs tear(cry)
    ought_not_rhyme 'stunt', 'done'
    ought_not_rhyme 'step', 'depth'

    # --- Following syllable stressed: often no word-internal flap ---
    ought_not_rhyme 'latex', 'climax'
    oughta_rhyme 'potato', 'tomato' # iconic

    # --- -er agent nouns & similar ---
    ought_not_rhyme 'sitter', 'cedar' # wrong onset
    ought_not_rhyme 'fitter', 'fiddler'
    oughta_rhyme 'hitter', 'bidder'
    ought_not_rhyme 'jotter', 'gaudier'

    # --- Past -ed (T vs D allomorph) ---
    ought_not_rhyme 'faint', 'pained'
    ought_not_rhyme 'bated', 'bayed'
    oughta_rhyme 'matted', 'padded'
    ought_not_rhyme 'wanted', 'sanded'
    ought_not_rhyme 'wanted', 'absconded'
    oughta_rhyme 'carded', 'farted'

    # --- Withgott (1982): morphological structure and T/D flap ---
    # T normally flaps across morpheme boundaries in derived words (positive cases).
    # Classic illustration: Plato (flaps) vs plateau (T before stressed syl → no flap),
    # but that T is before the rime so it doesn't affect rhyme matching directly.
    ought_not_rhyme 'creator', 'spectator' # stress mismatch
    oughta_rhyme 'equator', 'invader'
    oughta_rhyme 'dictator', 'crusader'
    oughta_rhyme 'recital', 'idle'
    oughta_rhyme 'ladle', 'fatal'
    oughta_rhyme 'beetle', 'needle'
    oughta_rhyme 'noodle', 'brutal'
    oughta_rhyme 'coital', 'colloidal'
    oughta_rhyme 'potato', 'tornado'
    oughta_rhyme 'transmittable', 'biddable'
    oughta_rhyme 'debatable', 'tradable'
    # Compound boundary may block flap (Withgott proper):
    oughta_rhyme 'whiteout', 'hideout'
    ought_not_rhyme 'cottage', 'bodice'
    oughta_rhyme 'tighten', 'whiten'
    ought_not_rhyme 'tighten', 'widen'

    # --- More positive candidates (informal or regional spellings marked) ---
    oughta_rhyme 'spotter', 'fodder'
    oughta_rhyme 'solder', 'fodder'
    ought_not_rhyme 'cotter', 'coddler'
    ought_not_rhyme 'brittle', 'bridle'
    oughta_rhyme 'kettle', 'medal'
    oughta_rhyme 'cattle', 'battle' # both T; control
    oughta_rhyme 'settled', 'meddled'
    ought_not_rhyme 'settled', 'saddled'
    oughta_rhyme 'titled', 'idled' # T AY T AH L D vs AY D AH L D — tricky
    oughta_rhyme 'tilted', 'jilted' # both T
    ought_not_rhyme 'jilted', 'gilded'
    oughta_rhyme 'belted', 'melted'
    ought_not_rhyme 'belted', 'melded'
    oughta_rhyme 'party', 'tardy'

    # --- Liquids before T (flap often applies after R; L is dialectal) ---
    oughta_rhyme 'faulty', 'salty'
    ought_not_rhyme 'filter', 'builder' # F IH1 L T ER vs B IH1 L D ER — ought_not
    ought_not_rhyme 'falter', 'alder' # F AO1 L T ER vs AO1 L D ER
    ought_not_rhyme 'falter', 'folder'

    # --- -ity / -ety (T in middle) ---
    oughta_rhyme 'pity', 'biddy'

    # --- Misc edge ---
    oughta_rhyme 'fiddle', 'little'
    oughta_rhyme 'throttle', 'waddle'
    oughta_rhyme 'bottle', 'wattle' # both flap-like env; wattle W AA1 T AH L vs B AA1 T AH L
    oughta_rhyme 'bottle', 'throttle'
    oughta_rhyme 'bottled', 'modeled'
    oughta_rhyme 'rattle', 'paddle' # R AE1 T AH L vs P AE1 D AH L
    oughta_rhyme 'cheetah', 'pita'
    ought_not_rhyme 'data', 'later' # don't elide final R in American English
    ought_not_rhyme 'beta', 'meta'
    oughta_rhyme 'beta', 'theta'
    ought_not_rhyme 'tutu', 'voodoo'
  end
  
  context 'apostrophes' do
    oughta_rhyme "hits", "its"
    ought_not_rhyme "its", "it's"
    oughta_rhyme "balls", "y'all's"
    oughta_rhyme "f'd", "bereft"
  end

  context 'hyphens' do
    could_go_either_way 'flaws', 'in-laws' # probably stress mismatch
    could_go_either_way 'flaws', 'inlaws' # probably stress mismatch
    ought_not_rhyme_one_way 'flaws', 'inlaws'
    ought_not_rhyme 'inlaws', 'in-laws'
    ought_not_rhyme 'nonbuilding', 'non-building'
    ought_not_rhyme 'cul-de-sac', 'back' # stress mismatch
    oughta_rhyme 'avant-garde', 'hard'
    oughta_rhyme 'topsy-turvy', 'scurvy'
    ought_not_rhyme 'ping-pong', 'wrong' # stress mismatch
    oughta_rhyme 'okey-dokey', 'hokey'
    oughta_rhyme_one_way 'okeydokey', 'hokey'
    ought_not_rhyme_one_way 'hokey', 'okeydokey' # okeydokey is dispreferred spelling of okey-dokey
    ought_not_rhyme 'flim-flam', 'slam' # stress mismatch
    oughta_rhyme 'papier-mache', 'way'
    oughta_rhyme 'tutti-frutti', 'booty'
    oughta_rhyme 'willy-nilly', 'silly'
    oughta_rhyme 'roly-poly', 'holy'
    ought_not_rhyme 'roly-poly', 'poly'
    oughta_rhyme 'hara-kiri', 'weary'
    oughta_rhyme 'queer', 'peer-to-peer'
    oughta_rhyme 'so-so', 'mafioso'
    oughta_rhyme 'fib', 'ad-lib'
  end
  
  context 'Limerick Heist' do
    oughta_rhyme 'heist', 'sliced'
    oughta_rhyme 'heist', 'iced'
    oughta_rhyme 'mum', 'chum'
    oughta_rhyme 'mom', 'bomb'
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
    oughta_rhyme 'lad', 'vlad'
    oughta_rhyme 'withdraw', 'voila'
  end
  
  context 'imperfect rhymes that ought to be perfect' do
    oughta_rhyme 'ear', 'beer' # used to fail because ear is [IY1 R] and beer is [B IH1 R]
    oughta_rhyme 'faring', 'glaring' # used to fail because faring is [F EH1 R IY0 NG] and glaring is [G L EH1 R IH0 NG]
    oughta_rhyme 'foster', 'impostor' # foster [AA S T ER] imposter [AO S T ER]
    oughta_rhyme 'curry', 'hurry' # curry [K AH1 R IY0] hurry [HH ER1 IY0]
    oughta_rhyme 'errors', 'terrors' # errors [EH1 R ER0 Z] terrors [T EH1 R AH0 R Z]
    oughta_rhyme 'array', 'hurray'
    oughta_rhyme 'array', 'moray'
    oughta_rhyme "taken", 'waken' # taken [T EY1 K IH0 N], waken [W EY1 K AH0 N]
    oughta_rhyme "takin'", 'waken' # takin' [T EY1 K IH0 N], waken [W EY1 K AH0 N]
    oughta_rhyme 'tons', 'funds' # [T AH1 N Z] [F AH1 N D Z], N D Z gets collapsed to N Z
    oughta_rhyme 'dance', 'ants' # plosive epenthesis. Technically this ought to only be valid within syllables, e.g. 'inside' ought not rhyme with 'ants hide', because you can't manifest a [t] out of nothing with 'inside', but whatever, it's fine.
    oughta_rhyme 'dreamt', 'tempt' # who cares about that P anyway. there's practically an invisible P in dreampt
    oughta_rhyme 'blotch', 'watch'
    oughta_rhyme 'blotched', 'watched'
    oughta_rhyme 'poor', 'tour' # P UW R / T UH R
    oughta_rhyme 'informant', 'torment', not_working_reason: true
  end

  context "-in'" do
    oughta_rhyme "winnin'", "linen"
    oughta_rhyme "failin'", "wailin'"
    oughta_rhyme "makin'", "bacon"
    oughta_rhyme "huffin'", "puffin"
    oughta_rhyme "huffin'", "puffin'"
    ought_not_rhyme "puffin", "puffin'"
    oughta_rhyme "puffin", "muffin"
    oughta_rhyme "puffin'", "muffin"
    oughta_rhyme "huffin'", "muffin"
    oughta_rhyme "poopin'", "scoopin'"
    oughta_rhyme "sobbin'", "bobbin"
    oughta_rhyme "sobbin'", "bobbin'"
    ought_not_rhyme "bobbin'", "bobbin'"
    oughta_rhyme 'layman', "shaman"
    oughta_rhyme 'layman', "gamin'"
    oughta_rhyme 'layman', "daemon", not_working_reason: "daemon is marked as a spelling variant of demon"
    ought_not_rhyme 'shaman', "shamin'" # homophone
    oughta_rhyme 'shaman', 'common'
  end

  context 'imperfect rhymes' do
    ought_not_rhyme 'mushroom', 'doom' # stress mismatch
    oughta_rhyme 'dodge', 'massage' # only in Texas, but we don't want dodge to get lonely in its empty lodge
    oughta_rhyme 'dodges', 'massages'
    oughta_rhyme 'dodger', 'massager'
    oughta_rhyme 'dodgers', 'massagers'
    oughta_rhyme 'dodged', 'massaged'
    oughta_rhyme 'dodging', 'massaging'
    oughta_rhyme 'fennel', 'sentimental' # it's OK to elide the final T in 'sentimental'
    oughta_rhyme 'greediest', 'devious', not_working_reason: true
    oughta_rhyme 'fence', 'wince', not_working_reason: true
    oughta_rhyme 'girl', 'world', not_working_reason: true
    oughta_rhyme 'false', 'malts' # sure I guess? otherwise 'false' won't rhyme with anything at all
    oughta_rhyme 'else', 'melts' # sure I guess? otherwise 'else' won't rhyme with anything at all
    oughta_rhyme 'poor', 'core', not_working_reason: "in some dialects, these rhyme"
    oughta_rhyme 'cajun', 'occasion'
    context 'pin/pen' do # I'm torn on this one
      ought_not_rhyme 'pin', 'pen'
      ought_not_rhyme 'vintage', 'percentage'
      ought_not_rhyme 'difference', 'preference'
      ought_not_rhyme 'kilogram', 'telegram'
      ought_not_rhyme 'incriminate', 'disseminate' # this sounds fine to me
      ought_not_rhyme 'ambivalent', 'benevolent'
      ought_not_rhyme 'winter', 'center'
      ought_not_rhyme 'interests', 'centrists'
      ought_not_rhyme 'deliverance', 'reverence'
      ought_not_rhyme 'vindictive', 'effective'
      ought_not_rhyme 'enlistment', 'investment'
      ought_not_rhyme 'abolitionist', 'impressionist'
      ought_not_rhyme 'magnificent', 'beneficent'
      ought_not_rhyme 'dissident', 'precedent'
      ought_not_rhyme 'filament', 'element'
      ought_not_rhyme 'curricular', 'molecular'
      ought_not_rhyme 'antiquity', 'inequity'
      ought_not_rhyme 'predictable', 'collectible'
      ought_not_rhyme 'fiction', 'section'
      ought_not_rhyme 'artistic', 'domestic'
    end
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
    oughta_rhyme 'freer', 'seer', not_working_reason: "bad seer pron in CMUdict"
    ought_not_rhyme 'seer', 'beer', not_working_reason: "bad seer pron in CMUdict"
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
    oughta_rhyme 'vibe', 'subscribe'
    oughta_rhyme 'vibes', 'subscribes'
    oughta_rhyme 'vibed', 'subscribed'
    ought_not_rhyme 'vibe', 'subscribed'
    ought_not_rhyme 'vibe', 'subscribes'
    ought_not_rhyme 'vibed', 'subscribe'
    ought_not_rhyme 'vibes', 'subscribe'
    ought_not_rhyme 'vibed', 'subscribes'
    oughta_rhyme 'vibing', 'subscribing'
  end

  context 'long words' do
    oughta_rhyme 'militaristic', 'ballistic'
    oughta_rhyme 'hypothetical', 'heretical'
    oughta_rhyme 'accelerometer', 'thermometer'
  end
  
  context 'homophone / spelling-variant traps' do
    ought_not_rhyme 'metal', 'mettle'
    ought_not_rhyme 'kernel', 'colonel'
    ought_not_rhyme 'write', 'right'
    ought_not_rhyme 'morning', 'mourning'
    ought_not_rhyme 'plain', 'plane'
    ought_not_rhyme 'symbol', 'cymbal'
    ought_not_rhyme 'serial', 'cereal'
    ought_not_rhyme 'aficionadoes', 'aficionados'
  end

  context 'non-binary rhymes' do
    oughta_rhyme 'latex', 'paychecks', not_working_reason: 'TODO: support non-binary rhymes'
    oughta_rhyme 'pitiful', 'biddable', not_working_reason: 'non-binary plus T -> D'
    oughta_rhyme 'cello', 'concerto', not_working_reason: 'TODO: support non-binary rhymes'
    oughta_rhyme 'symphony', 'timpani', not_working_reason: 'TODO: support non-binary rhymes'
    context 'multi-word' do
      oughta_rhyme 'cello', 'hell no', not_working_reason: 'TODO: support multi-word non-binary rhymes'
      oughta_rhyme 'bounty', 'brown tea', not_working_reason: 'TODO: support multi-word non-binary rhymes'
    end
  end

  context 'prereqs from similar_rhymes_spec: death' do
    oughta_rhyme 'bled', 'dead'
    oughta_rhyme 'bled', 'dread'
    oughta_rhyme 'dead', 'dread'
  end

  context 'prereqs from similar_rhymes_spec: pirate' do
    oughta_rhyme 'bold', 'gold'
    oughta_rhyme 'buccaneer', 'commandeer'
    oughta_rhyme 'buccaneer', 'peer-to-peer'
    oughta_rhyme 'cache', 'lash'
    oughta_rhyme 'coast', 'ghost'
    oughta_rhyme 'cove', 'trove'
    oughta_rhyme 'cracker', 'hacker'
    oughta_rhyme 'crew', 'tattoo'
    oughta_rhyme 'daring', 'swearing'
    oughta_rhyme 'dvd', 'sea'
    oughta_rhyme 'french', 'wench'
    oughta_rhyme 'gang', 'hang'
    oughta_rhyme 'handsome', 'ransom'
    oughta_rhyme 'leg', 'peg'
    oughta_rhyme 'loot', 'pursuit'
    oughta_rhyme 'reef', 'thief'
    oughta_rhyme 'abducted', 'obstructed'
    ought_not_rhyme 'aquatic', 'haddock' # fixed by an authoritative pronunciation
    oughta_rhyme 'haddock', 'thematic'
    ought_not_rhyme 'aquatic', 'thematic' # fixed by an authoritative pronunciation
    ought_not_rhyme 'satyr', 'splatter' # fixed by an authoritative pronunciation
    oughta_rhyme 'satyr', 'later'
    oughta_rhyme 'floating', 'loading'
    could_go_either_way 'floating', 'offloading'
    ought_not_rhyme 'laugher', 'rocker' # fixed by an authoritative pronunciation
    oughta_rhyme 'laugher', 'staffer' # fixed by an authoritative pronunciation
    oughta_rhyme 'haunted', 'daunted'
    oughta_rhyme 'haunted', 'undaunted'
    ought_not_rhyme 'daunted', 'undaunted'
    ought_not_rhyme 'official', 'unofficial'
    ought_not_rhyme 'color', 'scholar' # fixed by an authoritative pronunciation
    oughta_rhyme 'collar', 'scholar'
    ought_not_rhyme 'collar', 'color'
    oughta_rhyme 'marauding', 'plotting'
  end

  context 'prereqs from similar_rhymes_spec: halloween' do
    ought_not_rhyme 'broom', 'costume' # imperfect: stress mismatch
    oughta_rhyme 'bat', 'cat'
    oughta_rhyme 'celebration', 'decoration'
    oughta_rhyme 'cider', 'spider'
    oughta_rhyme 'fairy', 'scary'
    oughta_rhyme 'fright', 'night'
    oughta_rhyme 'sheet', 'treat'
  end

  context 'prereqs from similar_rhymes_spec: music' do
    ought_not_rhyme 'arpeggio', 'show' # imperfect: stress mismatch
    ought_not_rhyme 'cello', 'solo' # imperfect: stress mismatch
    ought_not_rhyme 'concerto', 'solo' # imperfect: stress mismatch
    ought_not_rhyme 'crooner', 'tuna'
    ought_not_rhyme 'drumsticks', 'mix' # imperfect: stress mismatch
    ought_not_rhyme 'oboe', 'piano' # imperfect: stress mismatch
    ought_not_rhyme 'overtone', 'xylophone' # imperfect: stress mismatch
    oughta_rhyme 'abbreviation', 'notation'
    oughta_rhyme 'accidental', 'instrumental'
    oughta_rhyme 'audition', 'composition'
    ought_not_rhyme 'bar', 'repertoire' # imperfect: stress mismatch    oughta_rhyme 'baroque', 'folk'
    oughta_rhyme 'beat', 'repeat'
    oughta_rhyme 'beat', 'sheet'
    oughta_rhyme 'bow', 'flow'
    oughta_rhyme 'bridal', 'idol'
    oughta_rhyme 'cantata', 'sonata'
    oughta_rhyme 'clarinet', 'minuet'
    oughta_rhyme 'croon', 'tune'
    oughta_rhyme 'crooner', 'tuner'
    oughta_rhyme 'duet', 'quartet'
    oughta_rhyme 'duet', 'quintet'
    oughta_rhyme 'ears', 'spheres'
    oughta_rhyme 'enjoys', 'noise'
    oughta_rhyme 'expressed', 'rest'
    oughta_rhyme 'fandango', 'tango'
    oughta_rhyme 'flute', 'lute'
    oughta_rhyme 'fortissimo', 'pianissimo', not_working_reason: 'both rare, rime bucket pruned'
    oughta_rhyme 'funk', 'punk'
    oughta_rhyme 'gong', 'song'
    oughta_rhyme 'harmonic', 'sonic'
    oughta_rhyme 'harp', 'sharp'
    oughta_rhyme 'jingle', 'single'
    oughta_rhyme 'orchestration', 'vibration'
    oughta_rhyme 'piano', 'soprano'
    oughta_rhyme 'piece', 'release'
    oughta_rhyme 'progression', 'session'
    oughta_rhyme 'rave', 'wave'
    oughta_rhyme 'recital', 'title'
    oughta_rhyme 'sing', 'swing'
    oughta_rhyme 'sings', 'strings'
    oughta_rhyme 'sticks', 'mix'
    oughta_rhyme 'violins', 'winds'
  end

  context 'prereqs from similar_rhymes_spec: water' do
    oughta_rhyme 'flush', 'gush'
    oughta_rhyme 'drink', 'sink'
    oughta_rhyme 'pee', 'sea'
    oughta_rhyme 'sky', 'supply'
    oughta_rhyme 'sprayed', 'wade'
    oughta_rhyme 'supplied', 'tide'
    oughta_rhyme 'dam', 'swam'
    oughta_rhyme 'slosh', 'wash'
    oughta_rhyme 'humidity', 'turbidity'
    oughta_rhyme 'bay', 'spray'
    oughta_rhyme 'steam', 'stream'
    oughta_rhyme 'eau', 'flow'
    oughta_rhyme 'sweat', 'wet'
    oughta_rhyme 'cool', 'pool'
    oughta_rhyme 'drain', 'rain'
    oughta_rhyme 'blood', 'flood'
    ought_not_rhyme 'marine', 'saline'
    oughta_rhyme 'dip', 'sip'
  end

  context 'prereqs from similar_rhymes_spec: clumsy' do
    oughta_rhyme 'bumbling', 'fumbling'
    oughta_rhyme 'bumbling', 'stumbling'
    oughta_rhyme 'excuse', 'shoes'
    oughta_rhyme 'excuse', 'loose'
    oughta_rhyme 'drop', 'flop'
  end

  context 'prereqs from similar_rhymes_spec: invoke' do
    oughta_rhyme 'dares', 'prayers'
    oughta_rhyme 'declare', 'prayer'
  end

  context 'prereqs from similar_rhymes_spec: prayers' do
    oughta_rhyme 'addressed', 'blessed'
    oughta_rhyme 'blessed', 'request'
    oughta_rhyme 'appeal', 'kneel'
    oughta_rhyme 'recites', 'rites'
    oughta_rhyme 'humble', 'mumble'
    oughta_rhyme 'jew', 'pew'
    oughta_rhyme 'knee', 'plea'
    oughta_rhyme 'heal', 'kneel'
    oughta_rhyme 'healing', 'kneeling'
    oughta_rhyme 'feast', 'priest'
    oughta_rhyme 'feasts', 'priests'
    oughta_rhyme 'blessed', 'confessed'
  end

  context 'prereqs from similar_rhymes_spec: carbon/bread/pasta' do
    oughta_rhyme 'sink', 'zinc'
    oughta_rhyme 'feast', 'yeast'
    oughta_rhyme 'champagne', 'grain'
    oughta_rhyme 'clam', 'ham'
    oughta_rhyme 'dish', 'fish'
    oughta_rhyme 'fork', 'pork'
    oughta_rhyme 'italian', 'scallion'
    oughta_rhyme 'paste', 'taste'
    oughta_rhyme 'ester', 'sequester'
    oughta_rhyme 'extract', 'react'
  end

  context 'prereqs from similar_rhymes_spec: crime' do
    oughta_rhyme 'acquit', 'commit'
    oughta_rhyme 'acquitted', 'committed'
    oughta_rhyme 'arrest', 'confessed'
    oughta_rhyme 'sleuth', 'truth'
    oughta_rhyme 'drugs', 'thugs'
    oughta_rhyme 'denial', 'trial'
    oughta_rhyme 'job', 'mob'
    oughta_rhyme 'repentance', 'sentence'
    oughta_rhyme 'skulduggery', 'thuggery'
    oughta_rhyme 'dog', 'smog'
    oughta_rhyme 'gas', 'mass'
    oughta_rhyme 'lake', 'quake'
    oughta_rhyme 'nerd', 'word'
  end

  context 'prereqs from similar_rhymes_spec: magic/medical/football/exploration' do
    oughta_rhyme 'chants', 'trance'
    oughta_rhyme 'disease', 'expertise'
    oughta_rhyme 'ccs', 'fees'
    oughta_rhyme 'incomplete', 'yeet'
    ought_not_rhyme 'backtrack', 'cul-de-sac' # imperfect: stress mismatch
  end

  context 'prereqs from similar_rhymes_spec: pair_related' do
    oughta_rhyme 'fraud', 'god'
    oughta_rhyme 'exciting', 'writing'
    oughta_rhyme 'chewed', 'rude'
    oughta_rhyme 'cuisine', 'mean'
    oughta_rhyme 'feed', 'greed'
    oughta_rhyme 'grain', 'pain'
    oughta_rhyme 'bane', 'grain'
    oughta_rhyme 'rice', 'vice'
    oughta_rhyme 'dinner', 'sinner'
    oughta_rhyme 'cake', 'rake'
    ought_not_rhyme 'apocalypse', 'chips' # imperfect: stress mismatch
    oughta_rhyme 'invader', 'seder'
    oughta_rhyme 'bread', 'undead'
    oughta_rhyme 'heinz', 'maligns'
    oughta_rhyme 'savory', 'slavery'
    oughta_rhyme 'crumb', 'scum'
    oughta_rhyme 'organic', 'satanic'
    oughta_rhyme 'abomination', 'starvation'
    oughta_rhyme 'malign', 'wine'
    oughta_rhyme 'traitor', 'waiter'
    oughta_rhyme 'deceit', 'wheat'
    oughta_rhyme 'dessert', 'hurt'
    oughta_rhyme 'murky', 'turkey'
    oughta_rhyme 'edgy', 'veggie'
    oughta_rhyme 'consume', 'gloom'
    oughta_rhyme 'buffet', 'gray'
    oughta_rhyme 'crab', 'drab'
    oughta_rhyme 'crustacean', 'illumination'
    oughta_rhyme 'hydration', 'illumination'
    oughta_rhyme 'melancholic', 'metabolic'
    oughta_rhyme 'ashen', 'ration'
    oughta_rhyme 'black', 'snack'
    oughta_rhyme 'cuisine', 'unseen'
    oughta_rhyme 'bleak', 'leek'
    oughta_rhyme 'lady', 'shady'
    oughta_rhyme 'bi', 'pie'
    oughta_rhyme 'flan', 'pan'
    oughta_rhyme 'flans', 'trans'
    oughta_rhyme 'bard', 'hard'
    ought_not_rhyme 'sachertorte', 'voldemort' # stress mismatch
    oughta_rhyme 'cider', 'snyder'
    ought_not_rhyme 'mushroom', 'doom' # stress mismatch
  end

  context 'prereqs from similar_rhymes_spec: related_rhymes' do
    oughta_rhyme 'please', 'siamese'
  end

  context 'prereqs from similar_rhymes_spec: ought_not_rhyme (homophones/spelling variants)' do
    ought_not_rhyme 'flour', 'flower'
    ought_not_rhyme 'realise', 'realize'
    ought_not_rhyme 'honor', 'honour'
  end

  context 'bad pronunciations' do
    ought_not_rhyme 'dante', 'dilettante'
    ought_not_rhyme 'kimono', 'persona'
    ought_not_rhyme 'scythe', 'myth'
    oughta_rhyme 'engineer', 'queer'
    ought_not_rhyme 'hibachi', 'mochi'
    ought_not_rhyme 'foreign', 'sarin'
    ought_not_rhyme 'euro', 'tempura'
    ought_not_rhyme 'otaku', 'sudoku'
    ought_not_rhyme 'no-one', 'cartoon'
    ought_not_rhyme 'noone', 'cartoon'
    ought_not_rhyme 'cameras', 'samurais'
    oughta_rhyme 'ratchet', 'hatchet'
    ought_not_rhyme 'ratchet', 'but'
    ought_not_rhyme 'marveled', 'held'
    ought_not_rhyme 'lances', 'nancies'
    ought_not_rhyme 'us', 'yes'
    ought_not_rhyme 'shat', 'nut'
    ought_not_rhyme 'egg', 'segue'
    ought_not_rhyme 'employee', 'gay'
    oughta_rhyme 'duty', 'booty'
    oughta_rhyme 'sooty', 'hoodie'
    ought_not_rhyme 'duty', 'sooty'
    oughta_rhyme 'than', 'man'
    oughta_rhyme 'fun', 'none'
    ought_not_rhyme 'than', 'none'
    oughta_rhyme 'confuse', 'muse'
    oughta_rhyme 'redoes', 'buzz'
    ought_not_rhyme 'confuse', 'redoes'
    ought_not_rhyme 'debutantes', 'renaissance' # stress mismaatch
    ought_not_rhyme 'prosthesis', 'transgresses'
    oughta_rhyme 'causal', 'menopausal'
    oughta_rhyme 'spousal', 'tousle'
    ought_not_rhyme 'causal', 'spousal'
    ought_not_rhyme 'different', 'vent'
    ought_not_rhyme 'differently', 'gently'
    oughta_rhyme 'corded', 'ported'
    oughta_rhyme 'bordered', 'quartered'
    ought_not_rhyme 'corded', 'quartered'
    oughta_rhyme 'britches', 'snitches' # fixed via an authoritative pronunciation
    ought_not_rhyme 'breeches', 'snitches' # fixed via an authoritative pronunciation
    oughta_rhyme 'breeches', 'beaches'
    ought_not_rhyme 'anal', 'bacchanal' # fixed via an authoritative pronunciation
    ought_not_rhyme 'anal', 'canal'
    ought_not_rhyme 'fez', 'snes' # fixed via an authoritative pronunciation
    ought_not_rhyme 'froggy', 'swaggy' # fixed via an authoritative pronunciation
    oughta_rhyme 'froggy', 'doggie'
    oughta_rhyme 'swaggy', 'baggy' # fixed via an authoritative pronunciation
    ought_not_rhyme 'a', 'into'
    ought_not_rhyme 'been', 'fun'
    oughta_rhyme 'been', 'seen' # yeah it's RP but so common in rhyming
    oughta_rhyme 'again', 'bane' # ditto
    ought_not_rhyme 'sloth', 'both'
    oughta_rhyme 'sloth', 'moth'
    oughta_rhyme 'snarf', 'barf'
    ought_not_rhyme 'snarf', 'cough'
    oughta_rhyme 'pigment', 'figment'
    ought_not_rhyme 'pigmented', 'dreaded'
    ought_not_rhyme 'midi', 'needy'
    oughta_rhyme 'midi', 'city'
    ought_not_rhyme 'marseille', 'isle'
    oughta_rhyme 'marseille', 'bay'
    oughta_rhyme 'marseilles', 'bay'
    ought_not_rhyme 'marseilles', 'bays'
    ought_not_rhyme 'upwind', 'mined'
    oughta_rhyme 'upwind', 'finned'
    oughta_rhyme 'refer', 'defer'
    oughta_rhyme 'rougher', 'tougher'
    ought_not_rhyme 'refer', 'tougher'
    ought_not_rhyme 'rougher', 'defer'
    oughta_rhyme 'prefer', 'defer'
    ought_not_rhyme 'prefer', 'tougher'
    ought_not_rhyme 'prefer', 'reefer'
    ought_not_rhyme 'refer', 'reefer'
    ought_not_rhyme 'defer', 'reefer'
    oughta_rhyme 'wino', 'rhino'
    ought_not_rhyme 'rhino', 'neutrino'
    ought_not_rhyme 'wino', 'neutrino'
    ought_not_rhyme 'bundt', "isn't"
    ought_not_rhyme 'mics', 'fix'
    ought_not_rhyme 'mit', 'get'
    ought_not_rhyme 'iterate', 'literate'
  end

  context 'ire' do
    oughta_rhyme 'ire', 'fire'
    oughta_rhyme 'tire', 'squire'
    oughta_rhyme 'attire', 'squire'
    oughta_rhyme 'dire', 'buyer'
    oughta_rhyme 'attire', 'aspire'
    oughta_rhyme 'briar', 'inquire'
    oughta_rhyme 'desire', 'inspire'
    oughta_rhyme 'choir', 'inquire' # identical rimes
    oughta_rhyme 'acquire', 'admire'
  end

  context 'almost rhymes' do
    oughta_rhyme 'harshly', 'partially'
    oughta_rhyme 'normally', 'warmly'
  end

  context "don't drop final R phoneme" do
    ought_not_rhyme 'fascia', 'masher'
    ought_not_rhyme 'lava', 'palaver'
    ought_not_rhyme 'kappa', 'zapper'
    ought_not_rhyme 'mecca', 'pecker'
    context "even when followed by -s" do
      ought_not_rhyme 'fascias', 'mashers'
      ought_not_rhyme 'lavas', 'palavers'
      ought_not_rhyme 'kappas', 'zappers'
      ought_not_rhyme 'meccas', 'peckers'
      ought_not_rhyme 'chandeliers', 'fizz'  # -er stem: chandelier + s
      ought_not_rhyme 'cars', 'because'      # mixed: catches the non-rhotic 'K AA1 Z' variant
      oughta_rhyme 'cars', 'stars'           # sanity: both rime AA R Z post-fix
    end
    context "even when followed by -ed" do
      ought_not_rhyme 'jabbered', 'rabid'
      ought_not_rhyme 'gendered', 'splendid' # -er stem: gender + ed
      ought_not_rhyme 'goitred', 'voided'    # BrE -re stem: goitre + d
      ought_not_rhyme 'debarred', 'cod'      # double-r past: debar + red
      oughta_rhyme 'bred', 'red'             # false-positive guard: 'br' is not a stem
    end
  end

  context 'unicode' do
    ought_not_rhyme '🍇', 'ape'
  end
  
  context 'spelling variants' do
    oughta_rhyme 'agonize', 'antagonize'
    oughta_rhyme 'agonize', 'antagonise'
    oughta_rhyme 'agonise', 'antagonize'
    oughta_rhyme 'agonise', 'antagonise'
  end

  context "semantically promiscuous" do
    ought_not_rhyme 'alles', 'males'
  end    
end
