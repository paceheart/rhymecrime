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

# Run-time counters consumed by the +sanity+ context at the bottom of this file. We track both
# +attempted+ (every +prefer_spelling+ example body that started executing) and +non_vacuous+
# (the subset that got past the +word_dict_includes_headword?(alt)+ short-circuit). Used to
# guard against a silent-failure mode where +$word_dict+ hasn't been lazy-loaded yet at the
# moment these examples run, +word_dict_includes_headword?+ short-circuits on +nil+, and
# every +prefer_spelling+ example +next+s into a vacuous pass — making the file look green
# in isolation while still failing in the full suite once another spec triggers the load.
SPELLING_SPEC_STATS = { attempted: 0, non_vacuous: 0 }

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
#
# Note: we deliberately use +word_dict.key?(alt)+ (which lazy-loads via the +word_dict+
# accessor) rather than the +word_dict_includes_headword?+ predicate. That predicate is
# build-path-safe and short-circuits on +$word_dict.nil?+ without forcing a load — fine for
# dict-compile callers, but in tests it would silently turn every example into a vacuous
# pass when this file runs alone (since nothing in spec_helper triggers the load).
def prefer_spelling(preferred, alt)
  it "prefers '#{preferred}' over '#{alt}'" do
    SPELLING_SPEC_STATS[:attempted] += 1
    next unless word_dict.key?(alt)
    SPELLING_SPEC_STATS[:non_vacuous] += 1

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
    prefer_spelling 'agonize', 'agonise'
    prefer_spelling 'agonized', 'agonised'
    prefer_spelling 'agonizes', 'agonises'
    prefer_spelling 'agonizing', 'agonising'
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
    prefer_spelling "potatoes",  "potatos"
    prefer_spelling "echoes",    "echos"
  end

  context "-eys vs -ies" do
    prefer_spelling "monkeys", "monkies"
    prefer_spelling "abbeys", "abbies"
    prefer_spelling "valleys", "vallies"
  end

  context "consonant doubling" do
    prefer_spelling "tasered", "taserred"
    prefer_spelling "tasering", "taserring"
    prefer_spelling "parroted", "parrotted"
    prefer_spelling 'targeted', 'targetted'
    prefer_spelling 'riveted', 'rivetted'
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

  context '-eing' do
    prefer_spelling 'having', 'haveing'
    prefer_spelling 'shaving', 'shaveing'
    prefer_spelling 'shoving', 'shoveing'
    prefer_spelling 'rueing', 'ruing'
    prefer_spelling 'barbecuing', 'barbecueing'
    prefer_spelling 'ogling', 'ogleing'
    prefer_spelling 'googling', 'googleing'
  end

  context '-er / -re US/UK' do
    prefer_spelling 'theater', 'theatre'
    prefer_spelling 'meter', 'metre'
    prefer_spelling 'micrometer', 'micrometre'
    prefer_spelling 'megameter', 'megametre'
    prefer_spelling 'gigameter', 'gigametre'
  end

  context "manual list (curated/spelling.csv)" do
    each_spelling_csv_pair do |preferred, alt|
      prefer_spelling preferred, alt
    end
  end

  # Defined LAST on purpose: with rspec's default +:defined+ order it runs after every
  # other example in this file, so +SPELLING_SPEC_STATS+ has accumulated by the time the
  # check fires. If some future change flips the suite to random ordering and this example
  # happens to land first, the +attempted == 0+ skip below keeps it from false-alarming.
  context "sanity" do
    it "at least one prefer_spelling example exercised the dict (non-vacuous run)" do
      attempted = SPELLING_SPEC_STATS[:attempted]
      non_vacuous = SPELLING_SPEC_STATS[:non_vacuous]
      skip "no prefer_spelling examples have run yet (subset run, or this example ran first under random order)" if attempted == 0
      expect(non_vacuous).to be > 0,
        "all #{attempted} prefer_spelling example(s) passed vacuously: word_dict_includes_headword?(alt) " \
        "returned false for every alt, so the +preferred_form+ assertions never fired. This usually " \
        "means $word_dict had not been lazy-loaded by the time spelling_spec ran — try requiring it " \
        "from spec_helper, or run alongside another file (e.g. rarity_spec) that triggers the load."
    end
  end
end
