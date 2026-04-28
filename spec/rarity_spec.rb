# Rarity test performance as of 2026-04-05
#
# Examples live in spec/rarity.csv (context, word, kind, important, skip, notes) — loaded below.
# +kind+ includes forbidden_ish (soft-priority forbidden; see +oughta_be_forbidden_ish+).
# See spec/test_utils.rb (+load_and_define_rarity_test_cases_from_csv+).

require_relative "test_utils"

#
# rare?
#

def allowed?(word)
  !explicitly_forbidden?(word) && word_dict.key?(word)
end

# Coarse bucket for expectations: not allowed for use (:forbidden) vs allowed and rare vs common.
def rarity_category(word)
  return :forbidden unless allowed?(word)
  rare?(word) ? :rare : :common
end

# Human-readable state for failure messages.
def rarity_status_line(word)
  f = frequency(word)
  case rarity_category(word)
  when :forbidden
    if explicitly_forbidden?(word)
      "explicitly_forbidden, frequency #{f}"
    elsif !word_dict.key?(word)
      "not in word_dict (frequency #{f})"
    else
      "not allowed, frequency #{f}"
    end
  when :rare
    "in word_dict, frequency #{f}, rare"
  when :common
    "in word_dict, frequency #{f}, common"
  end
end

def oughta_be_common(word, important: true, not_working_message: nil)
  test_name = "'#{word}' oughta be common"
  it test_name do
    skip_if_not_working(not_working_message)
    msg = "'#{word}' oughta be common, but is #{rarity_category(word)} — #{rarity_status_line(word)}"
    msg += " (but it's not that big a deal)" unless important
    expect(rarity_category(word)).to eq(:common), msg
  end
end

def oughta_be_rare(word, important: true, not_working_message: nil)
  test_name = "'#{word}' oughta be rare"
  it test_name do
    skip_if_not_working(not_working_message)
    msg = "'#{word}' oughta be rare, but is #{rarity_category(word)} — #{rarity_status_line(word)}"
    msg += " (but it's not that big a deal)" unless important
    expect(rarity_category(word)).to eq(:rare), msg
  end
end

def oughta_be_forbidden(word, not_working_message: nil)
  test_name = "'#{word}' oughta be forbidden"
  it test_name do
    skip_if_not_working(not_working_message)
    msg = "'#{word}' oughta be forbidden, but is #{rarity_category(word)} — #{rarity_status_line(word)}"
    expect(rarity_category(word)).to eq(:forbidden), msg
  end
end

describe "RARITY" do
  oughta_be_forbidden 'gypsy'
  oughta_be_forbidden 'aosidhgjqoerigh'
  oughta_be_forbidden 'imagineeringes'
  oughta_be_forbidden 'skyey'
  oughta_be_forbidden 'tooken'
  oughta_be_forbidden 'e-mai'
  oughta_be_forbidden 'iii'
  oughta_be_forbidden 'the' # stop word

  oughta_be_rare 'blepharoplasty'
  oughta_be_rare 'rikers'
  oughta_be_rare 'wakefield'
  oughta_be_rare 'absquatulate'
  oughta_be_rare 'taw'

  oughta_be_common 'pirate'
  oughta_be_common 'cat'
  oughta_be_common 'crime'
  oughta_be_common 'geometry'
  oughta_be_common 'mitten'
  oughta_be_common 'finesse'
  oughta_be_common 'finessed'
end
