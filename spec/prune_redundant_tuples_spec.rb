# Unit tests for +prune_suffix_redundant_rhyming_tuples+: a redundant-inflection pruner that
# collapses rhyming tuples related by a single consistent +Inflect+ suffix kind. Covers the three
# decision regimes the pruner has to get right:
#
#   1. same-length base vs. inflected: keep the base
#   2. one tuple strictly richer (extra member whose base doesn't rhyme): keep the richer one
#   3. disjoint / irregular tuples: keep both
#
# These cases have historically been fragile because +tuples.sort+ does not reliably front-load
# base forms (e.g. +artilleries+ < +artillery+ because +"i" < "y"+), so the pruner must be
# symmetric in both directions regardless of sort order.

# Slash-delimited tuple literal. Spaces around the +/+ are optional.
def parse_tuple_literal(s)
  s.to_s.split("/").map(&:strip).reject(&:empty?)
end

# Assert the pruner drops +prune_spec+ and keeps +keep_spec+ when given both as input.
# Each spec is a slash-joined literal, e.g. +prune_rhyming_tuple "cat / rat", "cats / rats"+.
def prune_rhyming_tuple(keep_spec, prune_spec, not_working: nil)
  it "prune: #{prune_spec}  (keep: #{keep_spec})" do
    skip_if_not_working(not_working)
    keep = parse_tuple_literal(keep_spec)
    prune_me = parse_tuple_literal(prune_spec)
    result = prune_suffix_redundant_rhyming_tuples([keep, prune_me])
    expect(result).to(
      contain_exactly(keep),
      "expected pruning to keep #{keep.inspect} and drop #{prune_me.inspect}, got #{result.inspect}"
    )
  end
end

# Assert the pruner keeps both tuples (i.e. neither is redundant with the other).
def dont_prune_rhyming_tuple(a_spec, b_spec, not_working: nil)
  it "don't prune: #{a_spec}  |  #{b_spec}" do
    skip_if_not_working(not_working)
    a = parse_tuple_literal(a_spec)
    b = parse_tuple_literal(b_spec)
    result = prune_suffix_redundant_rhyming_tuples([a, b])
    expect(result).to(
      contain_exactly(a, b),
      "expected pruning to keep both #{a.inspect} and #{b.inspect}, got #{result.inspect}"
    )
  end
end

describe "prune_suffix_redundant_rhyming_tuples" do
  context "same-length inflection pairs — keep the base" do
    prune_rhyming_tuple "cat / rat", "cats / rats"
    prune_rhyming_tuple "jump / walk / talk", "jumped / walked / talked"
    prune_rhyming_tuple "artillery / pillory", "artilleries / pillories" # keep -y, ditch -ies
    prune_rhyming_tuple "carry / marry", "carried / married"
  end

  context "different-length inflection subsets — keep the richer tuple" do
    prune_rhyming_tuple(
      "archaeologists / scientologistes / scientologists",
      "archaeologist / scientologist"
    )
    prune_rhyming_tuple(
      "walk / talk / rock / lock", "walked / talked / rocked"
    )
    # Multiple inflected subsets of one richer base tuple; both get pruned.
    prune_rhyming_tuple(
      "baggy / laggy / shaggy",
      "baggier / shaggier"
    )
    prune_rhyming_tuple(
      "baggy / laggy / shaggy",
      "baggiest / shaggiest"
    )
    prune_rhyming_tuple 'breezier / sleazier', 'breeziest / sleaziest'
    prune_rhyming_tuple 'breezy / sleazy', 'breeziest / sleaziest'
    prune_rhyming_tuple 'breezy / sleazy', 'breezier / sleazier'

    prune_rhyming_tuple 'busy / dizzy', 'busied / dizzied'
    prune_rhyming_tuple 'busy / dizzy', 'busier / dizzier'
    prune_rhyming_tuple 'busy / dizzy', 'busies / dizzies'
    prune_rhyming_tuple 'busy / dizzy',  'busiest / dizziest'
  end

  context "unrelated tuples — keep both" do
    dont_prune_rhyming_tuple "cat / bat / hat", "dog / log / frog"
    # +cats+ is a plural, +walked+ is a past — no single consistent inflection kind across slots.
    dont_prune_rhyming_tuple "cat / walk", "cats / walked"
  end

  context "degenerate inputs" do
    it "returns [] for no tuples" do
      expect(prune_suffix_redundant_rhyming_tuples([])).to eq([])
    end

    it "returns the singleton unchanged" do
      input = parse_tuple_literal("cat / dog")
      expect(prune_suffix_redundant_rhyming_tuples([input])).to eq([input])
    end
  end
end
