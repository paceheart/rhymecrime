# Surface-spelling preference expectations: the dictionary should normalize each documented
# pair to a single preferred form via +preferred_form+. Covers both:
#
#   - manually declared variants (+curated/spelling.csv+), and
#   - automatically detected morphology pairs (+us_uk_morphology_pair+ and friends).
#
# Per-pair semantics: if the non-preferred form is not a headword in +word_dict+ there is nothing
# to normalize away, so the example passes vacuously. When the variant IS a headword, we assert
# it normalizes to the preferred form, AND that the preferred form is itself a fixed point (so a
# future regression that flips the preference shows up as a spec failure either way).

SPELLING_CSV_SPEC_PATH = File.expand_path("../curated/spelling.csv", __dir__)

# Parse +curated/spelling.csv+: each non-comment line is
# +preferred,alt1[,alt2,...][,free-text notes]+. We yield every +(preferred, alt)+ pair.
# The +#+-prefixed comment header at the top is skipped, and an optional trailing notes
# column (any column containing whitespace / punctuation / digits — i.e. not matching
# +split_spelling_row+'s word-form regex) is silently dropped here.
def each_spelling_csv_pair
  File.foreach(SPELLING_CSV_SPEC_PATH, chomp: true, encoding: "UTF-8") do |line|
    next unless line =~ /\A[[:alpha:]]/
    forms, _notes = split_spelling_row(line)
    next if forms.size < 2
    preferred = forms.first
    forms[1..].each { |alt| yield preferred, alt }
  end
end

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

def dont_prefer_spelling(first, second)
  it "does not prefer '#{first}' over '#{second}'" do
    expect(preferred_form(second)).to_not eq(first),
      "expected preferred_form('#{second}') to not be '#{first}', but it was"
  end
end

describe "SPELLING VARIANTS" do
  context "-ize/-ise US/UK" do
    prefer_spelling 'standardize', 'standardise'
    prefer_spelling 'standardized', 'standardised'
    prefer_spelling 'standardizes', 'standardises'
    prefer_spelling 'standardizing', 'standardising'
    prefer_spelling 'aggrandize', 'aggrandise'
  end
  
  context "-or/-our US/UK" do
    prefer_spelling 'behavior', 'behaviour'
    prefer_spelling 'color', 'colour'
    prefer_spelling 'harbor', 'harbour'
    prefer_spelling 'recolor', 'recolour'
    dont_prefer_spelling 'tor', 'tour'
    dont_prefer_spelling 'for', 'four'
    dont_prefer_spelling 'or', 'our'
    context "plus -ize / -ise" do
      prefer_spelling 'colorize', 'colourize'
      prefer_spelling 'colorize', 'colourise'
      prefer_spelling 'colorize', 'colorise'
      prefer_spelling 'recolorize', 'recolorise'
      prefer_spelling 'recolorize', 'recolourize'
      prefer_spelling 'recolorize', 'recolourise'
      prefer_spelling 'recolorized', 'recolorised'
      prefer_spelling 'recolorized', 'recolourized'
      prefer_spelling 'recolorized', 'recolourised'
    end
  end

  # Loanwords from Spanish / Italian with a native -o plural. English dictionaries list both
  # -oes and -os forms, but the -os spelling is the better-attested modern choice for these
  # specific stems. (Contrast with the native -o nouns below, which prefer -oes.)
  context "-o loanwords prefer plain -os" do
    prefer_spelling "aficionados", "aficionadoes"
    prefer_spelling "desperados",  "desperadoes"
    prefer_spelling "mottos",      "mottoes"
    prefer_spelling "ghettos",     "ghettoes"
    prefer_spelling "solos",       "soloes"
    prefer_spelling 'tuxedos',     'tuxedoes'
  end

  # Native English -o nouns that take the older -oes plural in standard orthography.
  context "native -o nouns prefer -oes" do
    prefer_spelling "heroes",    "heros"
    prefer_spelling "tomatoes",  "tomatos"
    prefer_spelling "tornadoes", "tornados"
    prefer_spelling "torpedoes", "torpedos"
    prefer_spelling "tuxedoes", "torpedos"
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

  context "-l/-ll US/UK" do
    prefer_spelling 'counselor', 'counsellor'
    prefer_spelling 'traveling', 'travelling'
    prefer_spelling 'traveler', 'traveller'
    prefer_spelling 'fulfill', 'fulfil'
    prefer_spelling 'distill', 'distil'
    prefer_spelling 'distills', 'distils'
    prefer_spelling 'enroll', 'enrol'
    prefer_spelling 'enrolls', 'enrols'
  end

  context "words ending in e" do
    prefer_spelling "icing", "iceing"
  end

  context "unicode" do
    prefer_spelling 'naive', 'naïve'
    prefer_spelling 'cafe', 'café'
    prefer_spelling 'oeuvre', 'œuvre'
  end

  context "manual list (curated/spelling.csv)" do
    each_spelling_csv_pair do |preferred, alt|
      prefer_spelling preferred, alt
    end
  end
end
