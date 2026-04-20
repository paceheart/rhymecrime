# Surface-spelling preference expectations: the dictionary should normalize each documented
# pair to a single preferred form via +preferred_form+. Covers both:
#
#   - manually declared variants (+lib/rhymecrime/dict/spelling_variants.txt+), and
#   - automatically detected morphology pairs (+us_uk_morphology_pair+ and friends).
#
# Per-pair semantics: if the non-preferred form is not a headword in +word_dict+ there is nothing
# to normalize away, so the example passes vacuously. When the variant IS a headword, we assert
# it normalizes to the preferred form, AND that the preferred form is itself a fixed point (so a
# future regression that flips the preference shows up as a spec failure either way).

# Assert that +preferred_form(alt) == preferred+ (and that +preferred+ is a fixed point).
# Passes vacuously when +alt+ is not in +word_dict+ — there is nothing the dict could normalize.
def prefer_spelling(preferred, alt)
  it "prefers '#{preferred}' over '#{alt}'" do
    next unless word_dict_includes_headword?(alt)

    expect(preferred_form(alt)).to eq(preferred),
      "expected preferred_form('#{alt}') == '#{preferred}', got '#{preferred_form(alt)}'"
    expect(preferred_form(preferred)).to eq(preferred),
      "expected preferred_form('#{preferred}') == '#{preferred}' (fixed point), got '#{preferred_form(preferred)}'"
  end
end

describe "SPELLING VARIANTS" do
  # Loanwords from Spanish / Italian with a native -o plural. English dictionaries list both
  # -oes and -os forms, but the -os spelling is the better-attested modern choice for these
  # specific stems. (Contrast with the native -o nouns below, which prefer -oes.)
  context "-o loanwords prefer plain -os" do
    prefer_spelling "aficionados", "aficionadoes"
    prefer_spelling "desperados",  "desperadoes"
    prefer_spelling "mottos",      "mottoes"
    prefer_spelling "ghettos",     "ghettoes"
  end

  # Native English -o nouns that take the older -oes plural in standard orthography.
  context "native -o nouns prefer -oes" do
    prefer_spelling "heroes",    "heros"
    prefer_spelling "tomatoes",  "tomatos"
    prefer_spelling "potatoes",  "potatos"
    prefer_spelling "echoes",    "echos"
  end

  context "-eys vs -ies" do
    prefer_spelling "monies", "moneys"
    prefer_spelling "monkeys", "monkies"
    prefer_spelling "abbeys", "abbies"
    prefer_spelling "valleys", "vallies"
  end

  context "consonant doubling" do
    prefer_spelling "tasered", "taserred"
    prefer_spelling "tasering", "taserring"
    prefer_spelling "parroted", "parrotted"
  end

  context "words ending in e" do
    prefer_spelling "icing", "iceing"
  end
end
