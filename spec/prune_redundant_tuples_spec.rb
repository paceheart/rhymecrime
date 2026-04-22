# Unit tests for +prune_suffix_redundant_rhyming_tuples+: a redundant-inflection pruner that
# collapses rhyming tuples related by a single consistent +Inflect+ suffix kind. Covers the three
# decision regimes the pruner has to get right:
#
#   1. same-length base vs. inflected: keep the base
#   2. one tuple strictly richer (extra member whose base doesn't rhyme): keep the richer one
#   3. disjoint / irregular tuples: keep both
#
# These cases have historically been fragile because +tuples.sort+ does not reliably front-load
# base forms (e.g. +artilleries+ < +artillery+ because +'i' < 'y'+), so the pruner must be
# symmetric in both directions regardless of sort order.

# Slash-delimited tuple literal. Spaces around the +/+ are optional.
def parse_tuple_literal(s)
  s.to_s.split('/').map(&:strip).reject(&:empty?)
end

# Nil / empty / whitespace-only +not_working_reason+ means "working"; any other string marks the
# example as deferred and skips it with that reason as the pending message. Centralized here so
# the two helpers below stay in sync.
def prune_rhyming_tuple_not_working?(reason)
  !reason.nil? && !reason.to_s.strip.empty?
end

# Assert the pruner drops +prune_spec+ and keeps +keep_spec+ when given both as input.
# Each spec is a slash-joined literal, e.g. +prune_rhyming_tuple 'cat / rat', 'cats / rats'+.
# Pass a non-empty +not_working_reason+ to defer the case; the example is skipped with the
# reason as its pending message.
def prune_rhyming_tuple(keep_spec, prune_spec, not_working_reason = nil)
  it "prune: #{prune_spec}  (keep: #{keep_spec})" do
    skip_if_not_working(not_working_reason) if prune_rhyming_tuple_not_working?(not_working_reason)
    keep = parse_tuple_literal(keep_spec)
    prune_me = parse_tuple_literal(prune_spec)
    result = prune_suffix_redundant_rhyming_tuples([keep, prune_me])
    expect(result).to(
      contain_exactly(keep),
      "expected pruning to keep #{keep.inspect} and drop #{prune_me.inspect}, got #{result.inspect}"
    )
  end
end

# Assert the pruner drops +spec+ entirely (output has zero tuples). Use for inputs whose members
# are spelling variants of each other — the tuple carries no information the non-redundant forms
# don't already convey, so it should never be shown. See +prune_rhyming_tuple+ for
# +not_working_reason+ semantics.
def prune_entire_rhyming_tuple(spec, not_working_reason = nil)
  it "prune entire tuple: #{spec}" do
    skip_if_not_working(not_working_reason) if prune_rhyming_tuple_not_working?(not_working_reason)
    input = parse_tuple_literal(spec)
    result = prune_suffix_redundant_rhyming_tuples([input])
    expect(result).to(
      eq([]),
      "expected pruning to drop #{input.inspect} entirely, got #{result.inspect}"
    )
  end
end

# Assert the pruner allows +spec+. Inverse of prune_entire_rhyming_tuple.
def allow_entire_rhyming_tuple(spec, not_working_reason = nil)
  it "prune entire tuple: #{spec}" do
    skip_if_not_working(not_working_reason) if prune_rhyming_tuple_not_working?(not_working_reason)
    input = parse_tuple_literal(spec)
    result = prune_suffix_redundant_rhyming_tuples([input])
    expect(result).to_not(
      eq([]),
      "expected pruning to allow #{input.inspect} entirely, got #{result.inspect}"
    )
  end
end

# Assert the pruner keeps both tuples (i.e. neither is redundant with the other). See
# +prune_rhyming_tuple+ for +not_working_reason+ semantics.
def dont_prune_rhyming_tuple(a_spec, b_spec, not_working_reason = nil)
  it "don't prune: #{a_spec}  |  #{b_spec}" do
    skip_if_not_working(not_working_reason) if prune_rhyming_tuple_not_working?(not_working_reason)
    a = parse_tuple_literal(a_spec)
    b = parse_tuple_literal(b_spec)
    result = prune_suffix_redundant_rhyming_tuples([a, b])
    expect(result).to(
      contain_exactly(a, b),
      "expected pruning to keep both #{a.inspect} and #{b.inspect}, got #{result.inspect}"
    )
  end
end

describe 'prune_suffix_redundant_rhyming_tuples' do
  context 'unrelated tuples — keep both' do
    dont_prune_rhyming_tuple 'cat / bat / hat', 'dog / log / frog'
  end

  context 'degenerate inputs' do
    it 'returns [] for no tuples' do
      expect(prune_suffix_redundant_rhyming_tuples([])).to eq([])
    end

    it 'returns the singleton unchanged' do
      input = parse_tuple_literal('cat / dog')
      expect(prune_suffix_redundant_rhyming_tuples([input])).to eq([input])
    end
  end
  
  context 'same-length inflection pairs — keep the base' do
    prune_rhyming_tuple 'cat / rat', 'cats / rats'
    prune_rhyming_tuple 'walk / talk', 'walked / talked'
    prune_rhyming_tuple 'walk / talk', 'walking / talking'
    prune_rhyming_tuple 'artillery / pillory', 'artilleries / pillories'
    prune_rhyming_tuple 'carry / marry', 'carried / married'
    prune_rhyming_tuple 'carry / marry', 'carrying / marrying'
    prune_rhyming_tuple 'foist / hoist', 'foisting / hoisting'
    prune_rhyming_tuple 'foist / hoist', 'foistings / hoistings'
    prune_rhyming_tuple 'phony / pony', 'phonies / ponies'
  end

  context 'different-length inflection subsets — keep the richer tuple' do
    prune_rhyming_tuple(
      'archaeologists / scientologistes / scientologists',
      'archaeologist / scientologist'
    )
    prune_rhyming_tuple 'walk / talk / rock / lock', 'walked / talked / rocked'
    prune_rhyming_tuple 'baggy / laggy / shaggy', 'baggier / shaggier'
    prune_rhyming_tuple 'baggy / laggy / shaggy', 'baggiest / shaggiest'
    prune_rhyming_tuple 'breezier / sleazier', 'breeziest / sleaziest'
    prune_rhyming_tuple 'breezy / sleazy', 'breeziest / sleaziest'
    prune_rhyming_tuple 'breezy / sleazy', 'breezier / sleazier'

    prune_rhyming_tuple 'busy / dizzy', 'busied / dizzied'
    prune_rhyming_tuple 'busy / dizzy', 'busier / dizzier'
    prune_rhyming_tuple 'busy / dizzy', 'busies / dizzies'
    prune_rhyming_tuple 'busy / dizzy',  'busiest / dizziest'

    prune_rhyming_tuple 'defendant / independent', 'defendants / independents'
    prune_rhyming_tuple 'defendant / independent', 'defendants / independence', 'how to handle derivationally-different forms that happen to be hononyms of the derivationally-derived form'
    prune_rhyming_tuple 'defendant / independent', 'defendants / independence / independents', 'how to handle derivationally-different forms that happen to be hononyms of the derivationally-derived form'

    prune_rhyming_tuple 'foist / hoist / voiced', 'foistings / hoistings'
  end

  context "don't get tripped up by a stray t" do
    prune_rhyming_tuple 'prompt / romped / swamped', 'prompts / romps / swamps'
  end

  context 'prune dispreferred spelling variants' do
    prune_entire_rhyming_tuple 'desperados / desperadoes'
  end

  context 'misc' do
    prune_rhyming_tuple 'proving / removing', 'provings / removings'
    prune_rhyming_tuple 'boot / flute / fruit', 'booted / fluted / fruited'
    prune_rhyming_tuple 'boot / flute / fruit', 'booted / fluted'
    prune_rhyming_tuple 'boot / flute / fruit', 'booting / fluting'
    prune_rhyming_tuple 'booted / fluted / fruited', 'booting / fluting / fruiting'
    prune_rhyming_tuple 'booted / fluted / fruited', 'booting / fluting'
    prune_rhyming_tuple(
      'alluded / booted / fluted / fruited / polluted / suited',
      'alluding / booting / fluting / polluting / suiting'
    )
  end

  context 'stop words' do
    prune_entire_rhyming_tuple 'above / of' # prune tuples that are entirely stop words
    allow_entire_rhyming_tuple 'above / dove / of' # a single go-word allows it to live
  end

  # -'in is a lil dodgy, so prefer -ing
  context "g-drop vs -ing — keep the -ing tuple" do
    prune_rhyming_tuple 'faking / making / taking', "fakin' / makin' / takin'"
  end
end
