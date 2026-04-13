# Rarity test performance as of 2026-04-05
# 95.7% success overall
# 98.3% success on the examples we care most about
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

# Lower priority than oughta_be_common / oughta_be_rare: tagged :rarity_ish so you can
# focus on stricter examples first, e.g.  rspec spec/rarity_spec.rb --tag ~rarity_ish
def oughta_be_common_ish(word, not_working_message: nil)
  it "'#{word}' oughta be common (ish)", :rarity_ish do
    skip_if_not_working(not_working_message)
    msg = "'#{word}' oughta be common (ish), but is #{rarity_category(word)} — #{rarity_status_line(word)} (but it's not that big a deal)"
    expect(rarity_category(word)).to eq(:common), msg
  end
end

# Rhymeless words are filtered out early, so we can't test their rarity,
# but we can still verify that they have no rhymes
def oughta_be_common_but_has_no_rhymes(word, not_working_message: nil)
  ought_not_have_rhymes(word, not_working_message: not_working_message)
end

def ought_not_have_rhymes(word, not_working_message: nil)
  test_name = "'#{word}' oughta have no rhymes"
  it test_name do
    skip_if_not_working(not_working_message)
    expect(find_preferred_rhyming_words(word)).to be_empty, "'#{word}' ought not have any rhymes, but it does: #{find_preferred_rhyming_words(word)}"
  end
end

def oughta_have_rhymes(word, not_working_message: nil)
  test_name = "'#{word}' oughta have rhymes"
  it test_name do
    skip_if_not_working(not_working_message)
    expect(find_preferred_rhyming_words(word)).not_to be_empty, "'#{word}' oughta have rhymes, but it doesn't."
  end
end

# borderline - it's okay if these are either common or rare
def oughta_be_uncommon(word, not_working_message: nil)
  # intentional no-op
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

def oughta_be_rare_ish(word, not_working_message: nil)
  it "'#{word}' oughta be rare (ish)", :rarity_ish do
    skip_if_not_working(not_working_message)
    msg = "'#{word}' oughta be rare (ish), but is #{rarity_category(word)} — #{rarity_status_line(word)} (but it's not that big a deal)"
    expect(rarity_category(word)).to eq(:rare), msg
  end
end

# Rhymeless words are filtered out early, so we can't test their rarity,
# but we can still verify that they have no rhymes
def oughta_be_rare_but_has_no_rhymes(word, not_working_message: nil)
  ought_not_have_rhymes(word, not_working_message: not_working_message)
end

def oughta_be_forbidden(word, not_working_message: nil)
  test_name = "'#{word}' oughta be forbidden"
  it test_name do
    skip_if_not_working(not_working_message)
    msg = "'#{word}' oughta be forbidden, but is #{rarity_category(word)} — #{rarity_status_line(word)}"
    expect(rarity_category(word)).to eq(:forbidden), msg
  end
end

# Lower priority than +oughta_be_forbidden+; tagged :rarity_ish (see +oughta_be_rare_ish+).
def oughta_be_forbidden_ish(word, not_working_message: nil)
  it "'#{word}' oughta be forbidden (ish)", :rarity_ish do
    skip_if_not_working(not_working_message)
    msg = "'#{word}' oughta be forbidden (ish), but is #{rarity_category(word)} — #{rarity_status_line(word)} (but it's not that big a deal)"
    expect(rarity_category(word)).to eq(:forbidden), msg
  end
end

describe "RARITY" do
  load_and_define_rarity_test_cases_from_csv
end
