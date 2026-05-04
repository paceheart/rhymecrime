#!/usr/bin/env ruby
# coding: utf-8

#
# control parameters
# Don't tweak these here, tweak them in frontend.rb
#

$output_format = 'cgi'
$display_word_frequencies = false
$display_word_similarities = false

# When set to a String (e.g. by +build_rhymecrime_page+), HTML fragments append to
# +Thread.current[:html_output_buffer]+ instead of stdout. MUST be thread-local: Sinatra on Puma
# serves requests on multiple threads, and a process-wide +$global+ would let concurrent requests
# overwrite each other's output buffers mid-response (e.g. a fidget query's tuples leaking into
# a pirate query's HTML).

#
# Public interface: rhymecrime(word1, word2, goal, output_format='text', debug_mode=false)
# see bin/rhyme.rb for documentation
#

require "rwordnet"
require "net/http"
require "uri"
require "json"
require "cgi"
require_relative "data_source"
require_relative "dict/utils_rhyme"
require_relative "dict/phoneme.rb"
require_relative "dict/inflect"
require_relative "dict/lexical"
require_relative "dict/pronunciation.rb"
require_relative "timing"
require "memery"

#
# utilities (defined before +related.rb+ so +cgi_print+ exists for helpers there)
#

def cgi_print(string)
  buf = Thread.current[:html_output_buffer]
  if buf
    buf << string.to_s
  elsif $output_format == "cgi"
    print string
  end
end

def emit_text(string)
  buf = Thread.current[:html_output_buffer]
  if buf
    buf << string.to_s
  else
    print string
  end
end

def emit_line(string = "")
  buf = Thread.current[:html_output_buffer]
  if buf
    buf << string.to_s << "\n"
  else
    puts string
  end
end

require_relative "related"
require_relative "feedback_store"
require_relative "dynamo_store" if Rhymecrime::DataSource.dynamodb?

#
# Lexicon: in-process +$word_dict+, loaded from +word_dict.msgpack+ at boot.
# Same data shape in dev and Lambda; the DDB +word#+ partition was retired
# (see +bin/upload-to-dynamodb+ and +bin/stage-lambda+) once the msgpack got
# small enough (~5.5 MB) to ship in the deploy bundle. +DynamoRuntime+ now
# only fronts the +related#+ / +score#+ partitions.
#

def lexicon_word_entry(word)
  word_dict[word]
end

def debug_info(word)
  result = ""
  i = 0
  prons = pronunciations(word)
  for pron in prons
    i = i + 1
    unless i == 1
      result << " "
    end

    # pronunciation
    if prons.length == 1
      result << "pron="
    else
      result << "pron#{i}="
    end
    result << pron.to_s

    # rhyme syllables string
    if prons.length == 1
      result << " rsyll="
    else
      result << " rsyll#{i}="
    end

    result << pron.rhyme_syllables_string

    if prons.length == 1
      result << " rime="
    else
      result << " rime#{i}="
    end
    result << pron.rime
  end
  return result
end

#
# rhyme computation
#

$word_dict = nil
def word_dict()
  # word => [frequency, pronunciations, lemma]
  # pronunciations = [pronunciation1, pronunciation2 ...]
  # pronunciation = [syllable1, syllable1, ...]
  return $word_dict unless $word_dict.nil?
  # Prefer the msgpack: it's the runtime-canonical artifact (smaller, faster
  # to parse, and the only one shipped to Lambda). Fall back to the +.txt+
  # loader for fresh checkouts where +bin/dict-build+ hasn't run yet — keeps
  # +bundle exec rspec+ working before the first build.
  $word_dict = load_word_dict_msgpack || load_word_dict
end

WORDS_NEEDED_FOR_TESTING = ['arpeggio', 'asterisk', 'blackmail', 'bobcat', 'burglar', 'burglary', 'cat', 'celebrity', 'costume', 'crime', 'doubloons', 'drumsticks', 'fanciers', 'feline', 'fortissimo', 'galaxy', 'glissando', 'halloween', 'hemiola', 'homicide', 'item', 'jaguar', 'mandolin', 'music', 'overtone', 'pianissimo', 'pirate', 'pussy', 'repertoire', 'ritardando', 'scurvy', 'star', 'thing', 'tree', 'treetop', 'trespassing', 'whiskers', 'wildcat', 'xylophone'] # include these even if they don't have any rhymes

$rdict = nil # rime (underscore ARPABET key) -> words hash
def rdict
  # rime => [rhyming_word1 rhyming_word2 ...]
  return $rdict unless $rdict.nil?
  # Mirror of the +word_dict+ loader: prefer +rime_dict.msgpack+, fall back to
  # the +.txt+ surface for pre-dict-build checkouts.
  $rdict = load_rime_dict_msgpack || load_rime_dict_as_hash
end

def load_rime_dict_as_hash()
  load_string_hash(generated_dict_path(RIME_DICT_FILENAME)) or die "First run ./bin/dict-build to populate generated/"
end

def pronunciations(word)
  word_info = lexicon_word_entry(word)
  if word_info
    return word_info[1]
  else
    return []
  end
end

def frequency(word)
  word_info = lexicon_word_entry(word)
  if word_info
    return word_info[0]
  else
    return 0
  end
end

# Sorted list of RhymeCrime part-of-speech tags for +word+ (Kaikki +pos+ union, then lexical
# Kaikki POS intersected with WordNet coarse POS when WN has the lemma; see apply_lexical_pos_layer_a!
# in dict.rb (build). Empty array if the word is unknown to the loaded map.
#
# Strict-load: raises +RuntimeError+ if +generated/part_of_speech.json+ is missing. The file
# is *deliberately* excluded from the Lambda deploy bundle (see +bin/stage-lambda+) because
# the only Lambda-reachable caller — +relatedness/signals.rb+'s +pos_count+ feature — is the
# local-dev compute fallback that DDB mode short-circuits before ever requiring
# +signals.rb+. If you trip this raise from inside a Lambda invocation, something has
# pulled +signals.rb+ (or another POS reader) into the runtime path that shouldn't be there;
# fix the offender rather than re-including the file in the deploy zip.
$part_of_speech_by_word = nil
def part_of_speech_tags(word)
  w = word.to_s.downcase.strip
  return [] if w.empty?
  if $part_of_speech_by_word.nil?
    path = generated_dict_path(PART_OF_SPEECH_FILENAME)
    unless File.exist?(path)
      raise "missing #{path}: run ./bin/dict-build to generate it. " \
            "If this fired inside Lambda, the file is excluded by design — see " \
            "bin/stage-lambda and the doc comment above part_of_speech_tags."
    end
    $part_of_speech_by_word = JSON.parse(File.read(path, encoding: "UTF-8"))
  end
  tags = $part_of_speech_by_word[w]
  tags.is_a?(Array) ? tags : []
end

# Cohort for +rime+ from +rime_dict+ (dict-build keeps preferred headwords only; see +strip_dispreferred_headwords_from_rdict!+).
def rdict_lookup(rime)
  rdict[rime] || []
end

def find_preferred_rhyming_words(word)
  return filter_out_dispreferred_words(find_rhyming_words(word, false), word)
end

def filter_out_dispreferred_words(words, focal_word)
  # filters out dispreferred spelling variants and prefix words
  result = words.map { |word| preferred_form(word) }
  if result
    result.sort!.uniq!
    result = result - all_forms(focal_word)
    debug "preferred: #{result.inspect}"
  end
  result = filter_out_prefix_words(result, focal_word)
  return result || [ ]
end

def filter_out_prefix_words(words, focal_word)
  return words - prefix_words(words, focal_word)
end

# After stripping +prefix+ (+non+, +anti+, …), hyphenated forms yield +-rest+ (+-alcoholic+ → +alcoholic+).
def lexical_root_after_prefix(word, prefix)
  return nil unless word.start_with?(prefix)
  word[prefix.length..-1].sub(/\A-+/, "")
end

# Words in WORDS that share a +COMMON_PREFIXES+ derivation with FOCAL_WORD. A candidate is
# filtered when it shares a recursive-prefix-strip ancestor with focal AND both phonologically
# end with that ancestor's pronunciation (with consonants strict, unstressed vowels relaxed).
#
#   1. Ancestor sets (+recursive_prefix_ancestors+) walk +COMMON_PREFIXES+ at each step so
#      compound shapes like +in+sub-+ in +insubordinate+ collapse to +ordinate+ without
#      enumerating +insub-+ in the prefix list. Captures both the "candidate strips to
#      focal" case (+insubordinate+ → +ordinate+) and the "shared root" case (+unable+ and
#      +disable+ both → +able+) — the latter is what the old +focal_roots+ seeding
#      handled. Depth-bounded; restricted to lexicon entries so non-word artifacts of
#      over-stripping (+a-+ off +able+ → +ble+) don't poison the intersection.
#
#   2. Phonological-suffix alignment (+pron_suffix_aligned?+) requires each side's flat
#      ARPAbet to end with the common ancestor's, consonants and primary-stressed vowels
#      strict, unstressed vowels relaxed (+disenchanted+'s AH0 N tail matches +enchanted+'s
#      EH0 N — morphological vowel reduction at the prefix-stem boundary). The pron gate
#      is what makes the recursion safe: +un+de+served+ orthographically peels to +served+,
#      but +undeserved+'s tail is +Z AH1 R V D+ vs +served+'s +S AH1 R V D+ — the de- →
#      /d ɪ z/ shift before voiced-onset roots breaks the consonant frame, so the gate
#      (and therefore the filter) declines.
#
# Opaque/etymologically-prefixed words that modern speakers don't perceive as derivational
# (+record+ = re+cord, +ajar+ = a+jar, +abasement+ = a+basement) still suffix-align
# phonologically and are accepted as splash damage. The S→Z onset shift in +deserve+ /
# +serve+ used to be splash damage too; the pron gate now lets that pair through. See
# +rhyme_spec.rb+ for the working/skipped split.
def prefix_words(words, focal_word)
  focal_ancestors = recursive_prefix_ancestors(focal_word)
  result = words.select do |w|
    next false if w == focal_word
    candidate_ancestors = recursive_prefix_ancestors(w)
    common = focal_ancestors & candidate_ancestors
    next false if common.empty?
    common.any? do |anc|
      pron_suffix_aligned_or_equal?(focal_word, anc) &&
        pron_suffix_aligned_or_equal?(w, anc)
    end
  end
  debug "Filtering out prefix words #{result} from #{words}" unless result.empty?
  result
end

# Set of forms reachable by recursively peeling +COMMON_PREFIXES+ — and now also leading
# dict-headword compound modifiers (+business+ + +person+) and hyphenated leading words
# (+same+-+sex+) — from +word+. Always includes +word+ itself. Depth-bounded: the deepest
# legitimate English chain is ~3 (+dis+en+chanted+, +in+sub+ordinate+); ≤4 leaves headroom
# for as-yet-unseen compounds without risk of pathological recursion on words like
# +nonconcomitant+ where many prefixes happen to match the start.
#
# Three peel families:
#
#   * Single-prefix (+COMMON_PREFIXES+): +re-orient+ → +orient+. Recurses only when the
#     stripped tail is a dict headword OR a morphologically-valid surface of one
#     (+re-orienting+ → +orienting+ where +orienting+ isn't its own dict entry but is the
#     +-ing+ form of dict-attested +orient+). Non-dict morphologically-valid forms are
#     added to the set but not recursed from — keeps the over-stripping artifact (+a-+ off
#     +able+ → +ble+) out of the recursion while letting two prefixed siblings converge
#     on a shared inflected root.
#
#   * Compound-modifier (+businessperson+ → +person+): +word+ = +HEAD+ + +REST+ where both
#     +HEAD+ and +REST+ are dict headwords (each ≥ 3 chars). Peels +HEAD+ off and recurses
#     on +REST+. The pron-suffix-alignment gate downstream is what makes this safe for
#     sibling compounds with secondary-stressed shared elements (+eyeball+/+highball+ both
#     peel to +ball+ but +eyeball+'s +AA2+ tail doesn't align with +ball+'s primary
#     +AO1+ — different bare bases AND, post-strengthening, different stress —
#     so the filter declines).
#
#   * Hyphenated leading word (+same-sex+ → +sex+): when +word+ contains a hyphen and each
#     leading hyphen-segment is a dict headword, peel the leading segments and recurse on
#     the remainder. Covers +same-sex+, +self-organizing+ (when it's in dict), etc.
#
# Phonological-suffix alignment (+pron_suffix_aligned?+) is the safety net for all three
# branches: requires each side's flat ARPAbet to end with the common ancestor's, with
# consonants strict, vowel bare-bases strict, and primary stress preserved (the shorter
# side's primary-stressed vowel must still carry primary stress at the same position in
# the longer side). Without the primary-stress preservation, sibling compounds where the
# shared element loses primary stress (+handout+'s +AW2+ tail vs +out+'s primary +AW1+)
# would over-filter. With it, only true compound-rhymes-of-the-same-element pairs
# (+businessperson+/+layperson+ where both keep primary on +per+) get caught.
RECURSIVE_PREFIX_STRIP_MAX_DEPTH = 4

# Min char length for the HEAD in a compound-modifier peel. 4 excludes 3-char heads
# whose dict-membership is mostly opaque/etymological coincidences (+app+lied,
# +ant+agonize, +pig+ment, +hum+ble, +app+end) where the orthographic split has no
# real morphological status. Real 3-char compound modifiers used by the failing
# spec set (+bio+, +lay+) are routed through +COMMON_PREFIXES+ instead. Real
# productive modifiers (+business+, +council+, +thermo+, +same+) are 4+ chars.
COMPOUND_MODIFIER_HEAD_MIN_LENGTH = 4

# Min char length for the REST (the tail recursed on) in a compound-modifier peel. 3 keeps
# +-men+, +-sex+, +-out+ working as compound elements while excluding 1-2-char remainders
# that don't have their own pronunciation cohort.
COMPOUND_MODIFIER_REST_MIN_LENGTH = 3

def recursive_prefix_ancestors(word, depth = 0, set = nil)
  set ||= Set.new
  return set if depth >= RECURSIVE_PREFIX_STRIP_MAX_DEPTH
  return set if set.include?(word)
  set.add(word)

  COMMON_PREFIXES.each do |prefix|
    tail = lexical_root_after_prefix(word, prefix)
    next unless tail && !tail.empty?
    next if set.include?(tail)
    next unless prefix_ancestor_morpheme_like?(tail)
    if word_dict_includes_headword?(tail)
      recursive_prefix_ancestors(tail, depth + 1, set)
    elsif morphologically_valid_non_dict_form?(tail)
      set.add(tail)
    end
  end

  compound_modifier_remainders(word).each do |rest|
    next if set.include?(rest)
    next unless prefix_ancestor_morpheme_like?(rest)
    recursive_prefix_ancestors(rest, depth + 1, set)
  end

  hyphen_compound_remainders(word).each do |rest|
    next if set.include?(rest)
    next unless prefix_ancestor_morpheme_like?(rest)
    if word_dict_includes_headword?(rest)
      recursive_prefix_ancestors(rest, depth + 1, set)
    elsif morphologically_valid_non_dict_form?(rest)
      set.add(rest)
    end
  end

  set
end

# Minimum length for a pronunciation-less form to count as a morpheme-like
# ancestor. Pron-less surfaces fall back to +pron_suffix_aligned?+'s
# orthographic-suffix fallback, which matches by string suffix and so will
# happily call any common letter ending a "shared ancestor" — +rest+ and
# +best+ both end with the dict's contentless +st+ abbreviation row,
# +expressed+ and +pressed+ both end with the inferred +ssed+ form. Real
# pron-less morphological roots that need to survive are longer
# (+plosion+ at 7 chars: indexed dict headword, no stored pron, anchors
# the +explosion+/+implosion+ parallel-derivation collapse). 5 keeps that
# anchor while excluding both noise cases above.
PRONLESS_ANCESTOR_MIN_LENGTH = 5

def prefix_ancestor_morpheme_like?(form)
  return true unless pronunciations(form).empty?
  form.to_s.length >= PRONLESS_ANCESTOR_MIN_LENGTH
end

# True when +form+ is a non-dict surface that an +Inflect.raw_candidate_bases_for_inflected+
# strip relates to a dict headword (+orienting+ → +orient+, +tensions+ → +tension+). Lets
# +recursive_prefix_ancestors+ accept the stripped tail when two prefixed siblings
# (+re-orienting+, +dis-orienting+) converge on a real-but-not-stored inflected form.
# Excludes opaque non-derivational tails (+pre+fer → +fer+: no Inflect base in dict) so
# real-rhyme pairs (+prefer+/+defer+) aren't false-paired.
def morphologically_valid_non_dict_form?(form)
  return false if form.nil? || form.length < 3
  return false if word_dict_includes_headword?(form)
  Inflect.raw_candidate_bases_for_inflected(form).any? { |b| word_dict_includes_headword?(b) }
end

# Compound-modifier peels: +word+ = +HEAD+ + +REST+ where +HEAD+ is a non-rare dict
# headword of length ≥ +COMPOUND_MODIFIER_HEAD_MIN_LENGTH+ whose pronunciation aligns
# phonologically with +word+'s prefix, and +REST+ is a dict headword of length
# ≥ +COMPOUND_MODIFIER_REST_MIN_LENGTH+. Returns the +REST+ candidates. Skips
# hyphenated input — those go through +hyphen_compound_remainders+.
#
# Skips apostrophe-bearing input. In standard English orthography an apostrophe
# inside a "word" marks a contraction of an inflectional or function-word morpheme
# (verbal +-in'+ for +-ing+, +'em+ for +them+, +'tis+ for +it is+, +'bout+ for
# +about+, +o'clock+ for +of the clock+). Contractions are not free-standing
# lexical elements that combine into compounds. Without this guard, the 3-char
# +-in'+ contraction (exactly +COMPOUND_MODIFIER_REST_MIN_LENGTH+, slipping past
# the size threshold that excludes the bare 2-char preposition +in+) gets treated
# as a compound REST: +failin'+ falsely peels to +fail+ + +in'+, +huffin'+ to
# +huff+ + +in'+, +poopin'+ to +poop+ + +in'+, etc. The shared phantom +in'+
# ancestor then causes +prefix_words+ to filter sibling +-in'+ rhymes
# (+failin'+/+wailin'+, +huffin'+/+puffin'+, +poopin'+/+scoopin'+) out of each
# other's preferred-rhyme lists. The substring rule is sufficient because
# substrings of an apostrophe-free +word+ are themselves apostrophe-free.
#
# The rare-headword exclusion drops opaque-Latin compounds whose split words happen to
# be in dict only because they're corner-case headwords (+juris+ in +jurisprudence+:
# freq=2, rare). The pron-prefix-alignment gate (with the same primary-stress
# preservation as +phoneme_tail_match?+) drops splits whose orthographic match isn't
# matched at the phonological level (+complied+'s first 4 chars +comp+ would split
# orthographically but +comp+'s pron +K AA1 M P+ doesn't align with +complied+'s
# +K AH0 M P+ — different vowel base). Both gates together leave the rule firing only
# on transparent productive compounds (+business+person+, +council+men+,
# +thermo+plastic+).
def compound_modifier_remainders(word)
  return [] if word.nil? || word.empty? || word.include?("-") || word.include?("'")
  result = []
  head_min = COMPOUND_MODIFIER_HEAD_MIN_LENGTH
  rest_min = COMPOUND_MODIFIER_REST_MIN_LENGTH
  return result if word.length < (head_min + rest_min)
  (head_min..(word.length - rest_min)).each do |split|
    head = word[0...split]
    rest = word[split..-1]
    next unless word_dict_includes_headword?(head)
    next unless word_dict_includes_headword?(rest)
    next if rare?(head)
    next unless pron_prefix_aligned_or_equal?(word, head)
    result << rest
  end
  result
end

# +pron_prefix_aligned?+ but trivially true when +word+ equals +head+ (so a word counts
# as its own prefix for the same-word degenerate case).
def pron_prefix_aligned_or_equal?(word, head)
  return true if word == head
  pron_prefix_aligned?(word, head)
end

# Mirror of +pron_suffix_aligned?+ for the leading edge: any flat ARPAbet pronunciation
# of +longer+ starts with any of +shorter+'s, with the same +phoneme_tail_match?+
# semantics (consonants strict, vowels by bare base, primary-stress preservation
# from shorter to longer). Falls back to spelling-startswith when either word lacks
# pronunciations (covers headwords like +thermo+ that are dict-only with no prons but
# still gate +thermoplastic+'s compound peel orthographically).
def pron_prefix_aligned?(longer, shorter)
  longer_prons = pronunciations(longer)
  shorter_prons = pronunciations(shorter)
  if longer_prons.empty? || shorter_prons.empty?
    return longer.to_s.downcase.start_with?(shorter.to_s.downcase)
  end
  shorter_prons.any? do |sp|
    s_phones = sp.phonemes.reject(&:syllable_boundary?)
    next false if s_phones.empty?
    longer_prons.any? do |lp|
      l_phones = lp.phonemes.reject(&:syllable_boundary?)
      next false if l_phones.length <= s_phones.length
      l_head = l_phones[0...s_phones.length]
      longer_has_primary = pron_phones_have_primary_stress?(l_phones)
      l_head.zip(s_phones).all? { |a, b| phoneme_tail_match?(a, b, longer_has_primary: longer_has_primary) }
    end
  end
end

# Hyphenated-leading-word peels: +same-sex+ → +sex+, +okey-dokey+ → +dokey+ (when each
# leading segment is a dict headword). Returns the trailing remainder candidates.
def hyphen_compound_remainders(word)
  return [] if word.nil? || !word.include?("-")
  parts = word.split("-")
  return [] if parts.size < 2
  result = []
  (1...parts.size).each do |i|
    head_parts = parts[0...i]
    next unless head_parts.all? { |hp| !hp.empty? && word_dict_includes_headword?(hp) }
    rest = parts[i..-1].join("-")
    next if rest.empty?
    result << rest
  end
  result
end

# +pron_suffix_aligned?+ but trivially true when +word+ equals +ancestor+ (so a word counts
# as its own ancestor for the common-ancestor intersection).
def pron_suffix_aligned_or_equal?(word, ancestor)
  return true if word == ancestor
  pron_suffix_aligned?(word, ancestor)
end

# True when any flat ARPAbet pronunciation of +longer+ ends with any of +shorter+'s, with
# strict consonant/primary-stressed-vowel matching and unstressed-vowel relaxation. Falls
# back to spelling-endswith if either word has no pronunciations (rare; preserves coverage
# for hyphenated/missing-pron entries that +lexical_root_after_prefix+ already handles
# orthographically).
def pron_suffix_aligned?(longer, shorter)
  longer_prons = pronunciations(longer)
  shorter_prons = pronunciations(shorter)
  if longer_prons.empty? || shorter_prons.empty?
    return longer.to_s.downcase.end_with?(shorter.to_s.downcase)
  end
  shorter_prons.any? do |sp|
    s_phones = sp.phonemes.reject(&:syllable_boundary?)
    next false if s_phones.empty?
    longer_prons.any? do |lp|
      l_phones = lp.phonemes.reject(&:syllable_boundary?)
      next false if l_phones.length <= s_phones.length
      l_tail = l_phones[-s_phones.length..]
      longer_has_primary = pron_phones_have_primary_stress?(l_phones)
      l_tail.zip(s_phones).all? { |a, b| phoneme_tail_match?(a, b, longer_has_primary: longer_has_primary) }
    end
  end
end

# True when any phoneme in +phones+ carries primary stress (digit "1"). Used by
# +pron_suffix_aligned?+ / +pron_prefix_aligned?+ to detect prons that lack
# primary stress entirely (occasional dict-build artifacts on inferred forms
# like +microamerica+: M AY2 K R OW0 AH0 M EH2 R AH0 K AH0). +phoneme_tail_match?+
# relaxes its primary-preservation gate in that case so the highest-stressed
# vowel acts as the de-facto primary, matching the rime extractor's stress-1
# → 2 → 0 fallback.
def pron_phones_have_primary_stress?(phones)
  phones.any? { |p| p.to_s.include?("1") }
end

# Phoneme equivalence for +pron_suffix_aligned?+. +a+ is the longer-side phone,
# +b+ is the shorter-side (ancestor's) phone; +pron_suffix_aligned?+ feeds them
# in that order via +l_tail.zip(s_phones)+.
#
# Consonants: must match by bare base.
# Vowels: bare bases must match; if neither phoneme carries primary stress, any
# vowel-vowel pair counts as a match (handles morphological vowel reduction at
# the prefix-stem boundary, e.g. +enchanted+ EH0 N ↔ +disenchanted+'s AH0 N
# tail). Additionally, when the SHORTER side carries primary stress AND the
# longer pron has primary stress somewhere, the LONGER side must carry primary
# stress at the same position. This blocks secondary-stressed compound
# elements from aligning with the bare element's primary (+handout+'s +AW2+
# tail vs +out+'s +AW1+ — perceptually a different rhyme contour from a true
# compound-rhyme like +businessperson+/+person+ where both keep primary on
# +per+). When the longer pron carries no primary stress at all
# (+microamerica+: only AY2 / EH2), the gate relaxes — the highest-stressed
# vowel is the de-facto primary under the same fallback the rime extractor
# uses (stress 1 → 2 → 0), so secondary at the aligned position counts as
# primary-equivalent. Pre-strengthening, the bare-base check alone passed
# AW2/AW1 and over-filtered sibling compounds whose shared element kept
# secondary stress (+handout+/+standout+).
def phoneme_tail_match?(a, b, longer_has_primary: true)
  return true if a == b
  return false if a.syllable_boundary? || b.syllable_boundary?
  if a.vowel? && b.vowel?
    return true if !a.include?("1") && !b.include?("1")
    return false unless Phoneme.bare_base(a) == Phoneme.bare_base(b)
    return false if b.include?("1") && !a.include?("1") && longer_has_primary
    true
  else
    return false if a.vowel? || b.vowel?
    Phoneme.bare_base(a) == Phoneme.bare_base(b)
  end
end

def find_rhyming_words(word, identical_ok=true)
  # merges multiple pronunciations of WORD
  # use our compiled rime dictionary
  #
  # +explicitly_forbidden?+ status is checked per spelling-variant form rather
  # than gated on the input surface. This lets a query for a forbidden surface
  # whose preferred form is allowed (e.g. +okeydokey+ → +okey-dokey+) still
  # return rhymes via the allowed canonical form. Forbidden forms have already
  # been deleted from +word_dict+ at build time, so they contribute zero prons
  # in practice; the explicit per-form skip is a belt-and-braces guard against
  # any forbidden form accidentally retaining prons (e.g. via the
  # +authoritative_pronunciations.txt+ override path).
  rhyming_words = Array.new
  for form in all_forms(word) # to increase the likelihood of a hit, try all spelling variants
    next if explicitly_forbidden?(form)
    debug "Finding rhyming words for #{form} #{debug_info(form)}:"
    for pron in pronunciations(form)
      for rhyme in find_rhyming_words_for_pronunciation(pron, identical_ok)
        rhyming_words.push(rhyme)
      end
    end
    rhyming_words.delete(word)
    if(rhyming_words)
      rhyming_words = rhyming_words.uniq
    end
  end
  return rhyming_words || [ ]
end

# Returns true when two ARPABET tokens describe the same surface phone for duplicate-pron
# trapping: collapse secondary stress (digit 2) with unstressed (0); keep primary (1) distinct from both.
def homophone_trap_equivalent_phone_tokens?(a, b)
  return true if a == b
  normalize_secondary_stress_to_unstressed_for_homophone_trap(a.to_s) == normalize_secondary_stress_to_unstressed_for_homophone_trap(b.to_s)
end

def normalize_secondary_stress_to_unstressed_for_homophone_trap(s)
  return s if s == "."
  if s =~ /\A(.+)([012])\z/
    base = Regexp.last_match(1).to_s
    d = Regexp.last_match(2).to_i
    nd = (d == 1) ? 1 : 0
    "#{base}#{nd}"
  else
    s
  end
end

def pronunciation_phoneme_homophone_trap_duplicate?(pron_a, pron_b)
  return false unless pron_a.phonemes.length == pron_b.phonemes.length

  pron_a.phonemes.each_with_index do |ph, i|
    return false unless homophone_trap_equivalent_phone_tokens?(ph, pron_b.phonemes[i])
  end
  true
end

def identical_rhyme?(rhyme, target_pron)
  # Catches true homophones (same full pronunciation): +write+/+right+, +plain+/+plane+,
  # +symbol+/+cymbal+, +flour+/+flower+, +puffin+/+puffin'+. These would pass a
  # rime-cohort lookup but almost never count as legitimate rhymes; they're
  # "homophone / spelling-variant traps".
  #
  # CMU marks secondary syllable stress with +2+ and unstressed with +0+; perceptually close
  # pairs (+sunday+/+sundae+, +marquee+/+marquis+) differ only there. Collapse +2+ onto +0+
  # (+1+ unchanged) when comparing phoneme tuples so those become duplicate-pronunciation
  # traps (+plumber+/+demur+ stays distinct: mismatched consonants and primary stresses).
  #
  # Morphological prefix cases (+loading+/+unloading+, +end+/+upend+, +able+/+disable+)
  # are intentionally _not_ caught here -- they're handled by +filter_out_prefix_words+
  # downstream. Coincidental identical rhyme syllables with different onsets
  # (+leave+/+believe+, +plied+/+applied+, +bone+/+trombone+) _pass_ this filter and
  # are allowed to rhyme. We accept splash damage (e.g. +percussion+/+repercussion+
  # getting caught by +filter_out_prefix_words+) in exchange for a simpler rule.
  target_rime = target_pron.rime
  for pron in pronunciations(rhyme)
    next unless pron.rime == target_rime
    next unless pronunciation_phoneme_homophone_trap_duplicate?(pron, target_pron)
    return true
  end
  return false
end

def all_identical_rhymes?(words)
  syllable_signatures = Hash.new
  for word in words do
    for pron in pronunciations(word)
      syllable_signatures[pron.rhyme_syllables_string] = true
    end
  end
  if syllable_signatures.length == 1
    debug "Filtered out identical rhymes #{words}"
    return true
  else
    return false
  end
end

def find_rhyming_words_for_pronunciation(pron, identical_ok=true)
  # use our compiled rime dictionary
  results = Array.new
  rime = pron.rime
  rdict_lookup(rime).each do |rhyme|
    if(!identical_ok && identical_rhyme?(rhyme, pron))
      debug "Filtered out identical rhyme: #{pron} / #{rhyme} (#{debug_info(rhyme)})"
    else
      results.push(rhyme)
    end
  end
  return results || [ ]
end

def has_rhyming_word?(word)
  unless(explicitly_forbidden?(word))
    for pron in pronunciations(word)
      rime = pron.rime
      if(! rdict_lookup(rime).empty?)
        return true
      end
    end
  end
  return false
end

def filter_out_rhymeless_words(words)
  words.select { |word| has_rhyming_word?(word) }
end

#
# Thematic relatedness
#

module Rhymecrime
  module FindRelatedWordsMemo
    class << self
      include Memery

      memoize def find_related_words(word, include_self, include_rhymeless = true, common_only = false, max_candidates = SIMILAR_MAX)
        words = []
        unless explicitly_forbidden?(word)
          words = RelatedWords.find_thematically_related_words(word, include_self, include_rhymeless, common_only, max_candidates)
          words = filter_out_dispreferred_words(words, word)
        end
        words
      end
    end
  end
end

# +common_only:+ when true, restrict candidates to non-+rare?+ headwords (+words_we_care_about(..., true)+).
def find_related_words(word, include_self, include_rhymeless = true, max_candidates = SIMILAR_MAX, common_only: false)
  Rhymecrime::FindRelatedWordsMemo.find_related_words(word, include_self, include_rhymeless, common_only, max_candidates)
end

def find_related_rhymes(rhyme, rel)
  # +rhyme+ supplies the phonological anchor (we collect everything that rhymes
  # with it); +rel+ supplies the directional relatedness cue (each surviving
  # rhyme must be thematically related *to +rel+*, in the cue→related sense
  # the classifier learned post-symmetry-break). Pre-directional this filter
  # was +thematically_related?(rhyme, w)+, which checked relatedness against
  # the rhyme anchor instead of +rel+ — silently fine when the classifier was
  # symmetric and +rhyme+ happened to share a relatedness cluster with +rel+,
  # but wrong by construction now that direction matters and the column header
  # explicitly promises "rhymes for word1 related to word2".
  result = find_rhyming_words(rhyme, false)
  result = filter_out_dispreferred_words(result, rhyme)
  result = result.select { |w| thematically_related?(rel, w) }
end

# Inflect suffix kind from +base+ to +inflected+, or nil if not a recognized surface pattern.
#
# Extends +Inflect.match_suffix_kind+ with one chained suffix: +:ings+ (+ing+ then +s+, as in
# +foist → foisting → foistings+). Conservative scope on purpose: +foistings+-shaped forms are
# the only multi-inflection we've observed in rhyming-tuple output (+ing+s is the only productive
# chain in English that lands on a common-enough surface to rhyme-cluster), and we don't want to
# change pronunciation derivation or dict-build frequency inheritance, which both lean on
# +Inflect.match_suffix_kind+ returning single kinds. Generalize later if more chains show up.
def inflection_suffix_kind_from_base(base, inflected)
  return nil if base.nil? || inflected.nil?

  k = Inflect.send(:match_suffix_kind, base, inflected)
  return k unless k.nil?

  if inflected.end_with?("ings")
    ing_form = inflected[0...-1]
    return :ings if Inflect.send(:match_suffix_kind, base, ing_form) == :ing
  end

  # Colloquial g-drop: +fooin'+/+gluin'+/+stoppin'+/+tryin'+ share the same +base+
  # as the corresponding +-ing+ form (see +Inflect.gdropped_in_apostrophe_spelling+).
  # Reconstitute the +-ing+ surface and lean on the existing +:ing+ probe so every
  # branch (silent-e, y-stem, doubling) stays authoritative in one place. A distinct
  # kind lets +rhyming_tuple_kind_preferred?+ strictly prefer the non-apostrophe
  # spelling via +RHYMING_TUPLE_SIBLING_KIND_RANK+.
  if inflected.end_with?("in'") && inflected.bytesize >= 4
    ing_form = inflected[0...-3] + "ing"
    return :ing_gdrop if Inflect.send(:match_suffix_kind, base, ing_form) == :ing
  end

  # Agent-noun +-or+ as an orthographic sibling of +-er+: +sail+→+sailor+,
  # +act+→+actor+, +invent+→+inventor+. Rhymes identically (unstressed schwa
  # +/ɚ/), and surfaces as +sailor/whaler+ alongside +sail/whale+ in real
  # rhyming-tuple output. Reported as +:er+ rather than a distinct +:or+ so
  # the same-length kind-lock in +rhyming_tuple_suffix_redundant_with?+
  # treats +sail→sailor+ and +whale→whaler+ as the SAME inflection and the
  # tuple gets pruned. Kept narrow on purpose: only fires when +Inflect+
  # has rejected every other reading first, and only for the simplest +base
  # + "or"+ surface (no doubling, no silent-e) to avoid trampling the
  # +Inflect+ derivation tables, which the dict-build / frequency
  # inheritance paths still own.
  if inflected.end_with?("or") &&
      inflected.bytesize == base.bytesize + 2 &&
      inflected.start_with?(base)
    return :er
  end

  # Denominal +-y+ adjective: +health+→+healthy+, +stealth+→+stealthy+,
  # +dust+→+dusty+, +snow+→+snowy+. Surfaces in rhyming output as the
  # +healthy/stealthy+ adjective tuple shadowing the +health/stealth+
  # noun tuple. A distinct +:y_adj+ (not folded into any +Inflect+ kind)
  # so the only path that ever sees it is the rhyming-tuple pruner —
  # +Inflect+ derivation, dict-build, and frequency inheritance keep their
  # current behavior, which never synthesizes a +base+y+ surface from a
  # noun. Doubling-stem forms (+mud+→+muddy+, +sun+→+sunny+) are not
  # covered yet; add them when a failing tuple shows up.
  if inflected.end_with?("y") &&
      inflected.bytesize == base.bytesize + 1 &&
      inflected.start_with?(base)
    return :y_adj
  end

  # Two-step +:y_adj+ + +:er+/+:est+ chain: +feather+→+feathery+→+featherier+,
  # +leather+→+leathery+→+leatheriest+. Mirrors the +:ings+ chain above
  # (+-ing+ + +-s+) — same construction, just bridging through the synthetic
  # +base+"y"+ adjective intermediate that +:y_adj+ already recognizes. Distinct
  # kinds (+:y_adj_er+ / +:y_adj_est+) so the same-length kind-lock in
  # +rhyming_tuple_suffix_redundant_with?+ holds — both +featherier+ and
  # +leatherier+ report +:y_adj_er+ from their respective bases, the lock
  # accepts both, and the +featherier/leatherier+ tuple gets pruned when the
  # +feather/leather/...+ base tuple is present. Without this, the pruner
  # missed two-step adjective-comparative shadows of noun tuples — see
  # +featherier/leatherier+ vs +feather/leather/tether/whether+ in
  # +spec/prune_redundant_tuples_spec.rb+.
  #
  # +Inflect.match_suffix_kind+ is the second-stage probe rather than a
  # recursive +inflection_suffix_kind_from_base+ call so we can't accidentally
  # cascade further (+:y_adj_er_…+) — the chain is bounded at exactly two steps.
  if inflected.end_with?("ier") &&
      inflected.bytesize == base.bytesize + 3 &&
      inflected.start_with?(base) &&
      Inflect.send(:match_suffix_kind, base + "y", inflected) == :er
    return :y_adj_er
  end
  if inflected.end_with?("iest") &&
      inflected.bytesize == base.bytesize + 4 &&
      inflected.start_with?(base) &&
      Inflect.send(:match_suffix_kind, base + "y", inflected) == :est
    return :y_adj_est
  end

  nil
end

# True if +later+ is an uninterestingly redundant inflection of +earlier+ (same tuple length and
# each +later[i]+ is the same +Inflect+ suffix kind from +earlier[i]+, or +later+ is shorter and
# every word matches a distinct earlier word with one shared suffix kind). +later+ must not be longer.
def rhyming_tuple_suffix_redundant_with?(earlier, later)
  return false if earlier.empty? || later.empty?
  return false if earlier.size < later.size

  if earlier.size == later.size
    kinds = earlier.each_index.map { |i| inflection_suffix_kind_from_base(earlier[i], later[i]) }
    return false if kinds.any?(&:nil?)

    kinds.uniq.size == 1
  else
    kind_lock = nil
    used_idx = {}
    later.each do |w|
      matched_i = nil
      matched_k = nil
      earlier.each_with_index do |base, i|
        next if used_idx[i]

        k = inflection_suffix_kind_from_base(base, w)
        next if k.nil?

        matched_i = i
        matched_k = k
        break
      end
      return false if matched_i.nil?

      if kind_lock.nil?
        kind_lock = matched_k
      elsif kind_lock != matched_k
        return false
      end
      used_idx[matched_i] = true
    end
    true
  end
end

# Preference order for sibling pruning: when two same-length tuples are both inflections of the
# same absent base, the tuple with the lower-ranked kind wins (more basic inflections are kept).
# Example: +breezier / sleazier+ (kind +:er+, rank 4) beats +breeziest / sleaziest+ (+:est+, rank
# 5) when neither +breezy / sleazy+ is present in the input.
# Sibling-kind preference ladder. Lower rank wins when +rhyming_tuples_share_hidden_base+
# finds two tuples parallel-inflected off the same hidden base via two different kinds.
# +:ing_gdrop+ sits strictly *below* +:ing+ so +making / faking / taking+ beats
# +makin' / fakin' / takin'+ (and every analogous g-drop pair) — the apostrophe form
# is a colloquial surface of the same inflection, and we never want to render it when
# the canonical spelling is available.
RHYMING_TUPLE_SIBLING_KIND_RANK = { s: 1, ed: 2, ing: 3, er: 4, est: 5, ly: 6, ful: 7, ing_gdrop: 8 }.freeze

def rhyming_tuple_kind_preferred?(preferred, other)
  return false if preferred.nil? || other.nil? || preferred == other
  rp = RHYMING_TUPLE_SIBLING_KIND_RANK.fetch(preferred, Float::INFINITY)
  ro = RHYMING_TUPLE_SIBLING_KIND_RANK.fetch(other, Float::INFINITY)
  rp < ro
end

# If same-length tuples +a+ and +b+ are slot-parallel inflections of a common hidden base (not
# necessarily a headword in the dictionary) via two *different* consistent +Inflect+ suffix kinds,
# return +[kind_a, kind_b]+. Otherwise +nil+. Used to prune sibling inflections of an
# absent-from-input base, e.g. pruning +breeziest / sleaziest+ in favor of +breezier / sleazier+.
def rhyming_tuples_share_hidden_base(a, b)
  return nil if a.empty? || a.size != b.size
  return nil if a == b

  candidates_per_slot = a.each_index.map do |i|
    ca = Inflect.raw_candidate_bases_for_inflected(a[i])
    cb = Inflect.raw_candidate_bases_for_inflected(b[i])
    (ca & cb).to_a
  end
  return nil if candidates_per_slot.any?(&:empty?)

  candidates_per_slot.first.each do |b0|
    # Uses +inflection_suffix_kind_from_base+ (not +Inflect.match_suffix_kind+) so
    # superset kinds like +:ings+ and +:ing_gdrop+ (see that wrapper) participate in
    # hidden-base parallelism — otherwise +making / taking+ vs +makin' / takin'+
    # would go undetected and the g-drop tuple would slip past the pruner.
    ka = inflection_suffix_kind_from_base(b0, a.first)
    kb = inflection_suffix_kind_from_base(b0, b.first)
    next if ka.nil? || kb.nil? || ka == kb

    matches_all = true
    (1...a.size).each do |i|
      found = candidates_per_slot[i].any? do |bi|
        inflection_suffix_kind_from_base(bi, a[i]) == ka &&
          inflection_suffix_kind_from_base(bi, b[i]) == kb
      end
      unless found
        matches_all = false
        break
      end
    end
    return [ka, kb] if matches_all
  end

  nil
end

# Greek/Latin derivational suffix pairs used by
# +rhyming_tuples_share_letter_stem_via_derivational_suffix?+. Each entry is a
# pair of suffixes that attach to a shared letter stem to produce sibling
# noun/adjective forms (+anorex+ + +ia+ = +anorexia+, +anorex+ + +ic+ =
# +anorexic+). Order matters within a pair: the FIRST element is preferred —
# the cross-tuple sweep keeps tuples whose suffix matches +.first+ and prunes
# the sibling whose suffix matches +.last+. (For the cases here that means we
# keep the noun and prune the adjective: +anorexia / dyslexia+ wins over
# +anorexic / dyslexic+.) These derivations aren't productive in modern
# English — they're fossilized Greek/Latin loans — so +Inflect+ doesn't list
# them and the rhyming-tuple pruner's stock probes
# (+rhyming_tuples_share_hidden_base+, +rhyming_tuple_suffix_redundant_with?+)
# all decline. Listed conservatively; add new pairs only when a failing tuple
# in +spec/prune_redundant_tuples_spec.rb+ shows up.
DERIVATIONAL_SUFFIX_PAIRS = [
  %w[ia ic], # anorexia / anorexic, dyslexia / dyslexia → noun preferred
].freeze

# Recognize same-length sibling tuples that share a fixed letter-stem prefix
# at every slot and differ only by a known derivational suffix pair from
# +DERIVATIONAL_SUFFIX_PAIRS+. Returns +true+ when the slot-aligned suffix
# pair (+ear[i]+'s suffix, +tup[i]+'s suffix) matches a registered pair (any
# orientation) and stays consistent across all slots; the per-slot stem
# overlap must be at least +DERIVATIONAL_STEM_MIN_LENGTH+ characters so we
# don't latch onto trivial 1-2-letter coincidences. Used by
# +really_rhyming_tuple_redundant_with?+ to mark +tup+ as redundant with
# +ear+ when the suffix pair fires in the +ear-preferred+ direction
# (+ear+'s suffix is +.first+ in the registered pair). False otherwise — the
# reverse direction is handled implicitly by the cross-tuple sweep iterating
# in sort order: the noun tuple sorts before the adjective tuple
# alphabetically (+anorexia+ < +anorexic+), so it lands in +kept+ first and
# the adjective tuple gets compared against it (+ear+=noun, +tup+=adj) →
# pruned.
DERIVATIONAL_STEM_MIN_LENGTH = 4
def rhyming_tuples_share_letter_stem_via_derivational_suffix?(ear, tup)
  return false if ear.size != tup.size || ear.empty?
  return false if ear == tup

  pair_key = nil
  ear.each_with_index do |ew, i|
    tw = tup[i]
    return false if ew == tw

    # Try every registered suffix pair before splitting the stem. A naive
    # longest-common-prefix split would mis-segment +anorexia+/+anorexic+ at
    # +anorexi+ (the trailing +i+ is shared) and miss the +ia+/+ic+ pair —
    # the suffix has to bound the stem instead of the other way around.
    matched = DERIVATIONAL_SUFFIX_PAIRS.find do |es_suf, ts_suf|
      ew.end_with?(es_suf) && tw.end_with?(ts_suf) &&
        ew[0...-es_suf.bytesize] == tw[0...-ts_suf.bytesize] &&
        (ew.bytesize - es_suf.bytesize) >= DERIVATIONAL_STEM_MIN_LENGTH
    end
    return false unless matched

    if pair_key.nil?
      pair_key = matched
    else
      return false unless matched == pair_key
    end
  end
  !pair_key.nil?
end

# True if every word in +bases+ (the shorter tuple) inflects into a distinct word in +inflecteds+
# (the longer tuple) using one shared +Inflect+ suffix kind. Used to detect the case where a
# base-form tuple is a strict inflectional subset of a richer inflected tuple (e.g. the 3-member
# singular [archaeologist/paleontologist/scientologist] vs. the 4-member plural
# [archaeologists/paleontologists/scientologistes/scientologists]).
def rhyming_tuple_bases_all_inflect_into?(bases, inflecteds)
  return false if bases.empty? || inflecteds.empty?
  return false if bases.size > inflecteds.size

  kind_lock = nil
  used_idx = {}
  bases.each do |b|
    matched_i = nil
    matched_k = nil
    inflecteds.each_with_index do |infl, i|
      next if used_idx[i]

      k = inflection_suffix_kind_from_base(b, infl)
      next if k.nil?

      matched_i = i
      matched_k = k
      break
    end
    return false if matched_i.nil?

    if kind_lock.nil?
      kind_lock = matched_k
    elsif kind_lock != matched_k
      return false
    end
    used_idx[matched_i] = true
  end
  true
end

# Per-request memo for +rhyming_tuple_word_bases+. The function is pure over
# +word_dict+ / +Inflect+ (both load-time-stable) so the memo is safe to hold
# across a whole page render. +prune_suffix_redundant_rhyming_tuples+ calls
# +rhyming_tuple_word_bases+ repeatedly for the same word across multiple
# pruning passes (subset check, canonical base, all-spelling-variants), so
# caching drops cold-render time by ~25s for large rhyme sets. Cleared in
# +RelatedWords.reset_caches!+ alongside the other per-render caches.
$rhyming_tuple_word_bases_cache = {}

# Set of valid-looking base headwords for +word+ — +word+ itself (when it is a headword), its
# stored lemma, and any +Inflect.raw_candidate_bases_for_inflected+ candidate that is a headword.
# Recurses one level (e.g. +foistings+ → +foisting+ → +foist+) so chained inflections stay
# connected. Used by the hidden-base pruning path in +prune_suffix_redundant_rhyming_tuples+.
def rhyming_tuple_word_bases(word)
  cached = $rhyming_tuple_word_bases_cache[word]
  return cached unless cached.nil?

  result = Set.new
  if word.nil? || word.empty?
    $rhyming_tuple_word_bases_cache[word] = result
    return result
  end
  result.add(word) if word_dict_includes_headword?(word)
  lem = lemma(word)
  result.add(lem) if lem && word_dict_includes_headword?(lem)
  Inflect.raw_candidate_bases_for_inflected(word).each do |b|
    next unless word_dict_includes_headword?(b)
    result.add(b)
    # One level of recursion so chained inflections (+foistings+ → +foisting+ → +foist+) and
    # e-drop chains (+suiting+ listed with both +suite+ and +suit+) all reach the deepest
    # attested headword.
    lem2 = lemma(b)
    result.add(lem2) if lem2 && word_dict_includes_headword?(lem2)
    Inflect.raw_candidate_bases_for_inflected(b).each do |c|
      result.add(c) if word_dict_includes_headword?(c)
    end
  end
  $rhyming_tuple_word_bases_cache[word] = result
end

# Pre-filter fingerprint for the cross-tuple redundancy index in
# +prune_suffix_redundant_rhyming_tuples+. Returns a Set of identifiers such
# that two tuples can only be redundant with each other (under any branch of
# +rhyming_tuple_redundant_with?+) if their fingerprints intersect.
#
# Includes:
#
#   * +word+ itself — for the "ear is the base of tup" direction. The
#     predicate calls +inflection_suffix_kind_from_base(ear[i], tup[i])+,
#     which is true when +ear[i]+ is a base of +tup[i]+; the candidate
#     lookup needs +ear[i]+ to live in +tup[i]+'s key set, and the easy
#     side is just adding +ear[i]+ to +ear+'s own keys here.
#   * +lemma(word)+ — irregular-form bridge (+ran → run+, +mice → mouse+)
#     not reachable via surface-suffix morphology.
#   * +Inflect.raw_candidate_bases_for_inflected(word)+ — every surface-
#     morphology base (-s, -ed, -ing, -er, -est, -ly, -ful, -ily, y/ies,
#     consonant-doubling undo, silent-e). This is the *unfiltered* Inflect
#     output, NOT the headword-vetted +rhyming_tuple_word_bases+: the
#     predicate's +inflection_suffix_kind_from_base+ doesn't require either
#     side to be a headword (it's pure surface morphology), so the
#     fingerprint can't either, or any tuple with a non-headword member
#     (synthetic test data; partially-loaded DDB cache) would silently fall
#     out of the candidate pool. Found this trying to optimize the prune in
#     a fixture-only test where the dict was empty — see commit history.
#   * Surface reversals of the custom branches in
#     +inflection_suffix_kind_from_base+ that route around Inflect: +:y_adj+
#     (+healthy → health+), +:er+ via +-or+ (+sailor → sail+), +:ing_gdrop+
#     (+fakin' → faking+ / +fakin+), +:ings+ (+foistings → foisting / foist+),
#     +:y_adj_er+ / +:y_adj_est+ (+featherier → feather+, +leatheriest → leather+).
#
# All entries are unvalidated by design — the fingerprint only narrows the
# candidate pool the real +rhyming_tuple_redundant_with?+ predicate is then
# run against, so false positives cost a few extra (cheap) predicate calls;
# false negatives would silently change pruning output. Mirroring every
# reverse-strip branch in +inflection_suffix_kind_from_base+ + every Inflect
# pattern is the contract that keeps +spec/prune_redundant_tuples_spec.rb+
# green and matches the un-optimized pruner output bit-for-bit.
def tuple_redundancy_keys_for_word(word)
  keys = Set.new
  return keys if word.nil? || word.empty?

  keys.add(word)

  lem = lemma(word)
  keys.add(lem) if lem && !lem.empty?

  Inflect.raw_candidate_bases_for_inflected(word).each { |b| keys.add(b) }

  if word.end_with?("y") && word.bytesize >= 2
    keys.add(word[0...-1])
  end
  if word.end_with?("or") && word.bytesize >= 4
    keys.add(word[0...-2])
  end
  if word.end_with?("in'") && word.bytesize >= 4
    keys.add(word[0...-3] + "ing")
    keys.add(word[0...-3])
  end
  if word.end_with?("ings") && word.bytesize >= 5
    keys.add(word[0...-1])
    keys.add(word[0...-4])
  end
  # Surface reversal of the +:y_adj_er+ / +:y_adj_est+ chains added in
  # +inflection_suffix_kind_from_base+ above: +featherier → feather+,
  # +leatheriest → leather+. The fingerprint adds the chain-base
  # unconditionally — the predicate's +Inflect.match_suffix_kind(base + "y", …)
  # probe is what actually validates that the chain is real (e.g. +crazier+
  # gets +craz+ added here, but the predicate rejects it because
  # +Inflect.match_suffix_kind("crazy", "crazier") == :er+ requires +crazy+ to
  # exist in Inflect's adjective table, not just the surface stripping).
  if word.end_with?("ier") && word.bytesize >= 4
    keys.add(word[0...-3])
  end
  if word.end_with?("iest") && word.bytesize >= 5
    keys.add(word[0...-4])
  end

  # Letter-stem reversals of +DERIVATIONAL_SUFFIX_PAIRS+ entries used by
  # +rhyming_tuples_share_letter_stem_via_derivational_suffix?+: the index
  # bucket for both sides of a pair (+anorexia+, +anorexic+) needs to share a
  # stem key (+anorex+) so the cross-tuple sweep ever brings the two tuples
  # into +really_rhyming_tuple_redundant_with?+ for the dedicated probe to
  # fire. Like the +:y_adj_er+ / +:ier+ stems above, these are added
  # unvalidated — false-positive index entries are cheap; the predicate
  # validates the per-slot suffix pair against +DERIVATIONAL_SUFFIX_PAIRS+.
  DERIVATIONAL_SUFFIX_PAIRS.flatten.uniq.each do |suf|
    if word.bytesize >= suf.bytesize + DERIVATIONAL_STEM_MIN_LENGTH && word.end_with?(suf)
      keys.add(word[0...-suf.bytesize])
    end
  end

  keys
end

# Shortest headword in +rhyming_tuple_word_bases+, tie-broken lex. Returns +word+ itself when no
# bases are known (pure OOV). Used by +rhyming_tuple_inflection_distance+ to count how many words
# in a tuple have shifted off their root form.
def rhyming_tuple_word_canonical_base(word)
  bases = rhyming_tuple_word_bases(word).to_a
  return word if bases.empty?
  bases.min_by { |b| [b.length, b] }
end

# Greedy bipartite assignment: can every word in +shorter+ be paired with a distinct word in
# +longer+ whose +rhyming_tuple_word_bases+ set overlaps? When true, +shorter+ is redundant with
# +longer+ via a shared-hidden-base mapping (even when direct +Inflect.match_suffix_kind+ probes
# don't fire because both sides are inflected, e.g. +booting / fluting+ vs +booted / fluted /
# fruited+).
def rhyming_tuples_lemma_subset?(shorter, longer)
  return false if shorter.empty? || shorter.size > longer.size
  s_bases = shorter.map { |w| rhyming_tuple_word_bases(w) }
  return false if s_bases.any?(&:empty?)
  l_bases = longer.map { |w| rhyming_tuple_word_bases(w) }
  return false if l_bases.any?(&:empty?)
  used = Array.new(longer.size, false)
  s_bases.each do |sb|
    idx = (0...longer.size).find { |i| !used[i] && !(sb & l_bases[i]).empty? }
    return false if idx.nil?
    used[idx] = true
  end
  true
end

# Count of slots where the word is NOT its own canonical base (has been inflected off a root).
# Lower = closer to base forms. Primary tiebreaker for same-length hidden-base-parallel tuples:
# +[prompt, romped, swamped]+ (distance 2) beats +[prompts, romps, swamps]+ (distance 3) because
# the former retains one uninflected base.
def rhyming_tuple_inflection_distance(tuple)
  tuple.count { |w| rhyming_tuple_word_canonical_base(w) != w }
end

# True when every word in +tuple+ shares a common non-self base — the tuple is N different
# spellings of one root (+desperados / desperadoes+ both → +desperado+). Such tuples add no
# information beyond the canonical surface and +prune_suffix_redundant_rhyming_tuples+ drops them
# entirely.
def rhyming_tuple_all_spelling_variants?(tuple)
  return false if tuple.size < 2
  shared = nil
  tuple.each do |w|
    non_self = rhyming_tuple_word_bases(w) - [w]
    return false if non_self.empty?
    shared = shared.nil? ? non_self.dup : shared & non_self
    return false if shared.empty?
  end
  true
end

# True when +tup+ is redundant with the already-kept +ear+. Consolidates the four existing signal
# paths (same-length suffix-redundant, same-length sibling hidden base, richer base via
# +bases_all_inflect_into+, richer inflected via +suffix_redundant_with+) and adds the
# +rhyming_tuples_lemma_subset?+ fallback for cases where both tuples are inflected off a shared
# absent base that +Inflect.match_suffix_kind+ can't directly bridge
# (+booting / fluting+ vs +booted / fluted / fruited+, +prompt / romped / swamped+ vs
# +prompts / romps / swamps+).
# Optional cross-cue memoization layer for +rhyming_tuple_redundant_with?+.
# Populated only by +bin/compute-set-related+ (which sets it to a fresh
# Hash before kicking off the en-masse prune loop). Runtime never sets it,
# so the predicate stays a pure function call on the hot path. The keys are
# +[ear, tup]+ array pairs; Ruby Hashes hash arrays-of-strings naturally,
# and tuples in this codebase are already sorted before they reach
# +prune_suffix_redundant_rhyming_tuples+, so the same pair always normalizes
# to the same key without explicit canonicalization.
#
# Per the doc comment on +prune_cross_tuple_redundancy_sweep+:
# "+rhyming_tuple_redundant_with?+, whose entire transitive call graph is
# pure over +(ear, tup)+ (no +focal_word+ dependency anywhere). Safe to
# share a +rhyming_tuple_redundant_with?+ memoization layer across cues."
# That's exactly what this memo exploits: in the en-masse compute, the
# same tuple-pair recurs across many cues' tuple sets (animal / transport /
# emotion clusters share heavily) — collapsing the redundant calls drops
# the prune phase from ~8h to ~10min across the full ~28K cueniverse.
$rhyming_tuple_redundant_memo = nil

def rhyming_tuple_redundant_with?(ear, tup)
  if $rhyming_tuple_redundant_memo
    key = [ear, tup]
    return $rhyming_tuple_redundant_memo[key] if $rhyming_tuple_redundant_memo.key?(key)
    result = really_rhyming_tuple_redundant_with?(ear, tup)
    $rhyming_tuple_redundant_memo[key] = result
    return result
  end
  really_rhyming_tuple_redundant_with?(ear, tup)
end

def really_rhyming_tuple_redundant_with?(ear, tup)
  if ear.size == tup.size
    return true if rhyming_tuple_suffix_redundant_with?(ear, tup)
    kinds = rhyming_tuples_share_hidden_base(ear, tup)
    return true if kinds && rhyming_tuple_kind_preferred?(kinds[0], kinds[1])
    # Fallback: hidden-base-parallel siblings whose kinds aren't uniform per tuple (so the
    # existing share_hidden_base probe can't seat them) but whose lemma multisets match and ear
    # carries more base-form words.
    return true if rhyming_tuples_lemma_subset?(tup, ear) &&
      rhyming_tuples_lemma_subset?(ear, tup) &&
      rhyming_tuple_inflection_distance(ear) < rhyming_tuple_inflection_distance(tup)
    # Fallback: Greek/Latin derivational siblings (+anorexia+/+anorexic+,
    # +dyslexia+/+dyslexic+). +Inflect+ doesn't list these unproductive
    # alternations, so the probes above all decline; the dedicated
    # letter-stem probe consults +DERIVATIONAL_SUFFIX_PAIRS+ to pair the
    # noun-side tuple (kept) with the adjective-side tuple (pruned).
    return true if rhyming_tuples_share_letter_stem_via_derivational_suffix?(ear, tup)
    false
  elsif ear.size > tup.size
    return true if rhyming_tuple_suffix_redundant_with?(ear, tup)
    return true if rhyming_tuple_bases_all_inflect_into?(tup, ear)
    # Fallback: tup's hidden-base multiset is a subset of ear's (richer wins), even when both
    # sides are already-inflected surfaces (ear = +booted / fluted / fruited+, tup =
    # +booting / fluting+). The direct suffix-kind probes above can't bridge two inflected
    # forms; the lemma-subset probe can.
    return true if rhyming_tuples_lemma_subset?(tup, ear)
    false
  else
    false
  end
end

# Drop tuples that differ from another tuple only by parallel +Inflect+ suffixes (e.g. plural or
# past tense of the same set). Handles four regimes:
#
#   0. whole-tuple spelling-variant drop: all members are alternate spellings of one root
#      (+desperados / desperadoes+ → drop)
#   1. same-length base/inflected pair: keep the base, prune the inflected
#   2. richer-vs-smaller inflectional subset: keep the richer tuple
#   3. base-vs-inflected-superset (richer inflected has extra members not in the base): keep the
#      richer inflected
#
# Checks are bidirectional against the kept list because +tuples.sort+ does not reliably
# front-load base forms (e.g. +"artilleries" < "artillery"+ because +"i" < "y"+).
#
# Set +VERBOSE=1+ in the environment to print each pruned tuple (and the kept tuple it matched);
# this is separate from +$debug_mode+ / +debug+, which remain very chatty elsewhere.
#
# When +$debug_pruning+ is true (set per-request from the +debug=1+ URL param), tuples that
# would normally be dropped are instead retained in the returned array AND recorded in
# +$debug_pruned_tuples+, so the renderer can display them inline, greyed out, alongside
# the kept tuples.
# Within a single rhyming tuple, drop members that are morphological +COMMON_PREFIXES+
# derivations of another member already present in the tuple, when the two share an
# identical rhyme-syllable fingerprint (the criterion +all_identical_rhymes?+ already
# uses to identify phonologically-redundant members). Example:
# +[healthy, stealthy, unhealthy]+ -> +[healthy, stealthy]+ because +unhealthy+ = +un+
# + +healthy+ and both share the +HH EH L TH IY+ rsyll. Does not touch independent
# same-pron homophones (+coral+/+choral+, +flour+/+flower+) since neither is a prefix
# derivation of the other.
#
# Gated on +gloss_cites_base?+ for prefixes in +GLOSS_GATED_PREFIXES+ only.
# Productive prefixes (+un+, +re+, +non+, +dis+, +mis+, ...) almost always
# produce true derivations and we always collapse for those — WordNet glosses
# for productive negations/repetitions describe the meaning with synonyms
# rather than citing the base, so the gloss-citation signal is too noisy to
# use as a gate (40-60% false-negative rate per a +un-+ sweep). The gate
# applies to prefixes that frequently produce *lexicalized* compounds, where
# the prefix+base surface masks an idiomatic meaning that should NOT be
# rhyme-collapsed — +sub-+ being the headline case (+submarine+ vs +marine+,
# +subway+ vs +way+, +subdue+ vs +due+, +submerge+ vs +merge+, +subscribe+
# vs +scribe+, +subtract+ vs +tract+). Productive +sub-+ derivations
# (+subset+, +submenu+, +subgroup+) cite their base in the gloss and still
# collapse correctly.
GLOSS_GATED_PREFIXES = Set["sub"].freeze

def condense_tuple_derived_forms(tup, focal_word = nil)
  return tup if tup.size < 2
  rsyll_set_of = {}
  tup.each do |w|
    rsyll_set_of[w] = pronunciations(w).map { |p| p.rhyme_syllables_string }.to_set
  end
  dropped = Set.new
  tup.each do |derived|
    next if dropped.include?(derived)
    tup.each do |base|
      next if base == derived
      next if dropped.include?(base)
      next if dropped.include?(derived)
      # Phonological proximity: rsyll overlap (fast path) or +pron_suffix_aligned?+
      # fallback. The fallback catches cases where rsyll differs by an extra
      # syllable-onset consonant due to syllabifier choices (+disorienting+'s
      # "S AO ..." rsyll vs +orienting+'s "AO ..." — the +S+ migrated onset
      # because the dis- prefix's +AH0+ stays open before the new third
      # syllable). The pron-tail check is what +prefix_words+ already uses
      # as the safety gate, so accepting it here aligns the within-tuple
      # condenser with the rhyme filter.
      next if (rsyll_set_of[derived] & rsyll_set_of[base]).empty? &&
        !pron_suffix_aligned?(derived, base)
      COMMON_PREFIXES.each do |prefix|
        next unless derived.start_with?(prefix) && derived[prefix.length..] == base
        if GLOSS_GATED_PREFIXES.include?(prefix)
          next unless gloss_cites_base?(derived, base)
        end
        loser = derived_form_loser(derived, base, focal_word)
        dropped << loser if loser
        break
      end
    end
  end

  return tup if dropped.empty?
  tup - dropped.to_a
end

# Pick which of an explicit (+derived+, +base+) prefix-derivation pair
# +condense_tuple_derived_forms+ should drop. Returns +nil+ to keep both.
#
# Cue-blind path (+focal_word+ +nil+): always drop +derived+ — preserves
# the historic behavior used by +rhyming_pair_trivial?+ and any future
# focal-independent en-masse caller.
#
# Cue-aware path: when both members are materially related to the cue
# (+score >= RELATEDNESS_SCORE_THRESHOLD+), keep both — the rhyme isn't
# trivial-by-construction once both surfaces independently earn their
# place in the cue's tuple set (+music+'s tuple keeps +composition+
# alongside +position+; +prayers+ keeps +request+ alongside +quest+).
# When only the +derived+ form clears the threshold, drop the +base+
# instead (+pirate+'s +illegal+/+legal+: keep the cue-relevant +illegal+
# even though +legal+ is the bare base). Otherwise fall back to the
# cue-blind drop-derived default.
#
# Score is +parallel_sibling_score+'s (cached-then-live-relatedness)
# blend so non-cached cues — the typical shape at runtime live-compute —
# still get a meaningful signal rather than the constant-zero
# +RelatedWords.lookup_score+ stub.
def derived_form_loser(derived, base, focal_word)
  return derived if focal_word.nil? || focal_word.to_s.empty?
  sd = parallel_sibling_score(focal_word, derived)
  sb = parallel_sibling_score(focal_word, base)
  if sd >= RELATEDNESS_SCORE_THRESHOLD && sb >= RELATEDNESS_SCORE_THRESHOLD
    return nil
  end
  if sd >= RELATEDNESS_SCORE_THRESHOLD && sb < RELATEDNESS_SCORE_THRESHOLD
    return base
  end
  derived
end

# Within a single rhyming tuple, when two members are parallel
# +COMMON_PREFIXES+ derivations of an absent shared base, drop one — the
# pair carries no rhyme information beyond the implicit base. Catches
# +[disorient, reorient]+, +[extralegal, illegal]+, +[disoriented,
# reoriented]+, and the plural/gerund variants where the bare base
# (+orient+, +legal+) isn't in the tuple, while leaving +[coral, choral]+
# alone (no shared prefix-strip ancestor) and +[eyeball, highball]+ alone
# (the AA2/AO1 stress mismatch makes +pron_suffix_aligned?+ decline
# against the bare +ball+).
#
# Cue-aware tie-break: same ranking as +condense_tuple_homophones+ —
#
#   1. +similarity(focal_word, w)+ — stored relatedness to the cue, highest wins.
#   2. +frequency(w)+ — unigram frequency, highest wins.
#   3. alphabetical +w+ — final deterministic tiebreak.
#
# When +focal_word+ is +nil+ (en-masse compute callers that haven't
# plumbed the cue through, plus +rhyming_pair_trivial?+ where the
# collapse-or-not answer is independent of which member wins) the rank
# degenerates to lex-max, preserving the historic deterministic behavior.
def condense_tuple_parallel_derivations(tup, focal_word = nil)
  return tup if tup.size < 2
  ancestors_of = {}
  tup.each do |w|
    ancestors_of[w] = recursive_prefix_ancestors(w) - [w]
  end
  dropped = Set.new
  tup.each do |a|
    next if dropped.include?(a)
    tup.each do |b|
      next if a == b || dropped.include?(b)
      shared = ancestors_of[a] & ancestors_of[b]
      next if shared.empty?
      matched = shared.any? do |anc|
        pron_suffix_aligned?(a, anc) && pron_suffix_aligned?(b, anc)
      end
      next unless matched
      loser = parallel_sibling_loser(a, b, focal_word)
      dropped << loser
      break if loser == a
    end
  end
  return tup if dropped.empty?
  tup - dropped.to_a
end

# Pick which of two parallel-derivation siblings to drop. Cue-aware: rank
# both by +(score, frequency, alphabetical)+ against +focal_word+ and
# return the lower-ranked surface; +focal_word+ +nil+ degenerates to
# lex-max so en-masse compute / pair-trivial callers get deterministic
# focal-independent behavior.
#
# +score+ falls back from the cached +similarity+ to a live
# +relatedness_score+ when the cached read is uninformative (zero for
# both siblings — the typical shape when +focal_word+ is a non-cached
# cue, e.g. +pirate+, where the +RelatedWords.lookup_score+ path returns
# 0 for every related). Without the live fallback the tiebreak collapses
# to frequency / lex-max for *every* parallel-derivation pair under a
# non-cached cue, defeating the purpose of being cue-aware. The live
# call is cheap here (two +PairSignals+ evaluations per pair) and only
# fires when the prune is already in the live-compute branch — cached
# cues hit +Store.fetch_set_related_tuples+ before reaching the prune.
def parallel_sibling_loser(a, b, focal_word)
  if focal_word.nil? || focal_word.to_s.empty?
    return [a, b].max
  end
  sim_a = parallel_sibling_score(focal_word, a)
  sim_b = parallel_sibling_score(focal_word, b)
  ranked = [a, b].sort_by.with_index do |w, i|
    sim = i.zero? ? sim_a : sim_b
    [-sim, -frequency(w).to_i, w]
  end
  ranked.last
end

# Cached +similarity+ first; fall back to a live
# +relatedness_score(PairSignals.new(cue, related))+ when the cached
# value is 0 (typical for non-cached cues where +RelatedWords.lookup_score+
# has no row to consult). Lazy-loads the relatedness compute pipeline on
# first call from a process that hadn't already loaded it via
# +find_related_words+ — at Lambda runtime this only fires when the
# +set_related+ goal has already gone live-compute (the cached-tuples
# path skips the prune entirely), so the load is paid for either way.
def parallel_sibling_score(focal_word, w)
  cached = similarity(focal_word, w).to_i
  return cached if cached > 0
  relatedness_lazy_load_compute!
  relatedness_score(PairSignals.new(lemma(focal_word), lemma(w))).to_i
rescue StandardError
  0
end

# Per-word cache of tokenized lowercase WordNet gloss text. Built lazily on
# first miss; persists for the lifetime of the process. WN access is wrapped
# so a missing or unconfigured WN install yields an empty token list rather
# than crashing the rhyme pipeline (the caller +gloss_cites_base?+ treats
# empty-as-collapse, so the prefix rule still fires unchanged in that case).
# Per-word cache of WN derivationally-related lemmas (lowercase). Built lazily
# from +wn_derivation_target_lemmas_for_word+; empty when WN is unconfigured
# or the helper isn't loaded, in which case the citation check just falls
# back to surface-form / inflectional matching.
$gloss_deriv_targets_cache = {}
def gloss_deriv_targets_for_word(word)
  return Set.new if word.nil? || word.to_s.empty?

  key = word.to_s.downcase
  cached = $gloss_deriv_targets_cache[key]
  return cached unless cached.nil?

  Inflect.configure_wordnet_db_path! if defined?(Inflect)
  targets =
    begin
      if defined?(WordNet::Lemma) &&
          defined?(WordNet::DB) && !WordNet::DB.path.to_s.empty? &&
          respond_to?(:wn_derivation_target_lemmas_for_word, true)
        Set.new(wn_derivation_target_lemmas_for_word(key).map(&:to_s).map(&:downcase))
      else
        Set.new
      end
    rescue StandardError
      Set.new
    end
  $gloss_deriv_targets_cache[key] = targets.freeze
end

$gloss_tokens_cache = {}
def gloss_tokens_for_word(word)
  cached = $gloss_tokens_cache[word]
  return cached unless cached.nil?

  Inflect.configure_wordnet_db_path! if defined?(Inflect)
  tokens =
    begin
      if defined?(WordNet::Lemma) &&
          defined?(WordNet::DB) && !WordNet::DB.path.to_s.empty?
        # Plurals/inflected forms (+submarines+, +rewrites+) don't have their
        # own WN gloss entries — the lemma owns the gloss. Try the surface
        # form first, then fall back to +lemma(word)+ so +submarines+'s
        # citation check still consults +submarine+'s "submersible warship"
        # gloss instead of returning empty (which would default-collapse).
        forms = [word.to_s.downcase]
        lem = lemma(word.to_s.downcase) rescue nil
        forms << lem if lem && !forms.include?(lem)
        glosses = nil
        forms.each do |f|
          g = WordNet::Lemma.find_all(f).flat_map { |l| l.synsets.map(&:gloss) }
          if !g.empty?
            glosses = g
            break
          end
        end
        if glosses
          glosses.join(" ").downcase.scan(/[a-z]+/).freeze
        else
          [].freeze
        end
      else
        [].freeze
      end
    rescue StandardError
      [].freeze
    end
  $gloss_tokens_cache[word] = tokens
end

# True iff +derived+'s WordNet gloss(es) cite +base+ (the base spelling, any
# +Inflect.each_derivable_form+ surface, or — when +base.length >= 5+ — any
# gloss token that shares the base's first 4 characters; the stem-prefix
# branch lets +unhealthy+'s gloss "not in good health" cite +healthy+ via
# the token "health"). The derived word's self-mention (+unhealthy+ in
# +unhealthy+'s own gloss) is filtered out so +unhappy+'s gloss "experiencing
# ... unhappy ..." can't trivially "cite" +happy+ via its own surface.
#
# Conservative on the no-signal side: when WordNet has no gloss for
# +derived+ (proper nouns, +bedecked+, +into+), we return +true+ so the
# existing +condense_tuple_derived_forms+ behavior is preserved.
def gloss_cites_base?(derived, base)
  tokens = gloss_tokens_for_word(derived)
  return true if tokens.empty?

  derived_lc = derived.to_s.downcase
  base_lc = base.to_s.downcase

  # Accept set construction:
  #  1. base spelling and its lemma
  #  2. their +Inflect.each_derivable_form+ surfaces (handles +restarts+ vs
  #     +starts+: lemma-fallback gloss "start an engine again" cites +start+)
  #  3. WN derivationally-related lemmas of base, *but only the
  #     spelling-adjacent ones* (sharing a 4-char prefix with the base
  #     lemma). +marine+'s WN derivations include +sea+, which is the
  #     conceptual root but not a morphological cousin — accepting +sea+
  #     would let submarine's 3rd-sense gloss ("attack ... beneath the
  #     surface of the sea") falsely cite +marine+. The
  #     spelling-adjacency filter keeps +kindness+/+kindly+ (citing +kind+)
  #     while rejecting +sea+/+navigation+ (peripheral to +marine+).
  accept = Set[base_lc]
  base_lemma = (lemma(base_lc) rescue nil)
  accept << base_lemma if base_lemma
  if defined?(Inflect)
    [base_lc, base_lemma].compact.uniq.each do |seed|
      Inflect.each_derivable_form(seed) { |f| accept << f.downcase }
    end
  end
  stem_seed = base_lemma || base_lc
  spelling_adjacent_stem = stem_seed.length >= 4 ? stem_seed[0, 4] : nil
  if spelling_adjacent_stem
    [base_lc, base_lemma].compact.uniq.each do |seed|
      gloss_deriv_targets_for_word(seed).each do |t|
        accept << t if t.length >= 4 && t.start_with?(spelling_adjacent_stem)
      end
    end
  end

  # Stem prefix check (orthographic fallback): any gloss token sharing the
  # base lemma's first 4 chars counts as a citation. Lowered from len>=5 so
  # +kind+'s gloss-citation in +unkind+ matches the token "kindness" (which
  # is also a WN deriv-target, but the stem check covers it without
  # depending on WN being loaded).
  stem = stem_seed.length >= 4 ? stem_seed[0, 4] : nil

  tokens.any? do |t|
    next false if t == derived_lc
    next true if accept.include?(t)
    !stem.nil? && t.length >= stem.length && t.start_with?(stem)
  end
end

# Within a single rhyming tuple, break homophone clusters down to one winner.
# "Homophone cluster" = members sharing a full phoneme sequence (+identical_rhyme?+):
# +coral+/+choral+, +flour+/+flower+, +write+/+right+, +rite+/+right+, +symbol+/+cymbal+.
# Unlike +condense_tuple_derived_forms+ (which handles +COMMON_PREFIXES+ derivations
# sharing only a rhyme-syllable fingerprint), neither member here is morphologically
# derived from the other, so there's no a-priori favorite; we need the cue to pick.
# Ranking key per member +w+:
#   1. +similarity(focal_word, w)+ — stored relatedness to the cue, highest wins.
#   2. +frequency(w)+ — unigram frequency, highest wins (user-specified tiebreak).
#   3. alphabetical +w+ — final deterministic tiebreak.
# A +nil+ +focal_word+ (callers that haven't plumbed the cue through) disables this
# pass; the tuple is returned untouched.
def condense_tuple_homophones(tup, focal_word)
  return tup if tup.size < 2 || focal_word.nil?
  ungrouped = tup.dup
  clusters = []
  while (seed = ungrouped.shift)
    seed_prons = pronunciations(seed)
    mates = ungrouped.select do |other|
      seed_prons.any? { |sp| identical_rhyme?(other, sp) }
    end
    next if mates.empty?
    ungrouped -= mates
    clusters << [seed, *mates]
  end
  return tup if clusters.empty?
  dropped = Set.new
  clusters.each do |cluster|
    ranked = cluster.sort_by do |w|
      [-similarity(focal_word, w).to_i, -frequency(w).to_i, w]
    end
    ranked[1..].each { |w| dropped << w }
  end
  tup - dropped.to_a
end

# True when the pair +[a, b]+ would collapse to a single member under within-tuple
# derivation/homophone condensation — i.e. it is a morphological +COMMON_PREFIXES+
# derivation over matching +rhyme_syllables_string+ (+condense_tuple_derived_forms+),
# or a true same-phoneme homophone pair (+condense_tuple_homophones+). Examples:
# +[healthy, unhealthy]+ (prefix); +[flour, flower]+, +[coral, choral]+,
# +[symbol, cymbal]+ (homophones). The homophone condenser needs a +focal_word+
# to pick a winner, but for the drop-or-keep decision here we only care whether
# the cluster collapses, so any non-nil focal (we pass +a+) produces the same
# +size+ result.
def rhyming_pair_trivial?(a, b)
  return false if a == b
  condense_tuple_derived_forms([a, b]).size < 2 ||
    condense_tuple_parallel_derivations([a, b]).size < 2 ||
    condense_tuple_homophones([a, b], a).size < 2
end

# Pair-mode analog of within-tuple derivation/homophone condensation in
# +prune_suffix_redundant_rhyming_tuples+. Drops pairs whose two members
# +rhyming_pair_trivial?+ flags as prefix derivations or same-pronunciation
# homophones — the "rhyme" carries no
# information beyond the trivial collapse. A pair is binary, so unlike the
# tuple condensers (which pick a winner and keep the tuple alive) we drop the
# whole pair. Called from +really_find_rhyming_pairs+ after the rhyme-cross.
def prune_trivial_rhyming_pairs(pairs)
  return pairs if pairs.empty?
  verbose_prunes = ENV["VERBOSE"] == "1"
  pairs.reject do |(a, b)|
    trivial = rhyming_pair_trivial?(a, b)
    puts "pruned rhyming pair (trivial rhyme: prefix or homophone): #{a} / #{b}" if trivial && verbose_prunes
    trivial
  end
end

# When +$disable_cross_tuple_redundancy_pruning+ is true, the cross-tuple
# +rhyming_tuple_redundant_with?+ pass below is skipped: distinct rhyme-bucket
# tuples that differ only by parallel +Inflect+ suffixes (+[deck, wreck]+ vs
# +[decked, wrecked]+, +[crew, tattoo]+ vs +[crews, tattoos]+) all survive.
# Within-tuple derivation condensation (+condense_tuple_derived_forms+, which
# collapses +[legal, illegal]+-style identical-rhyme prefix derivations) still
# runs — only the *across-tuple* derivational dedup is bypassed. Used by
# +spec/similar_rhymes_spec.rb+ so per-pair assertions like
# +set_related_oughta_contain 'pirate', 'deck', 'wreck'+ aren't masked by an
# already-kept past-tense sibling tuple. Production runtime keeps it +false+.
$disable_cross_tuple_redundancy_pruning = false

# Per-tuple prune: applies the stop-word wholesale drop, the
# spelling-variant wholesale drop, and within-tuple derivation
# condensation. Returns either:
#
#   * +nil+ — tuple was dropped wholesale by the stop-word drop (all stop
#     words — +above / of+) or the spelling-variant drop (all members are
#     spelling variants of one root — +desperados / desperadoes+).
#   * a (possibly shorter) tuple — survived the wholesale-drop steps;
#     within-tuple derivation condensation may have removed prefix-derivation
#     members whose +rhyme_syllables_string+ matched a base already present
#     in the tuple (+[healthy, stealthy, unhealthy] → [healthy, stealthy]+,
#     +[recorded, prerecorded, unrecorded] → [recorded]+).
#
# Cue awareness: the wholesale-drop steps are pure functions of the
# tuple. +condense_tuple_derived_forms+ consults +focal_word+ when one
# is supplied, so a +derived+/+base+ pair where the +derived+ form is
# the cue-relevant surface (+music+'s +composition+ over +position+,
# +prayers+'s +request+ over +quest+) survives the collapse rather than
# always losing to its bare base. With +focal_word+ +nil+ the helper
# stays focal-independent and a cache-aware caller can memoize the
# result across cues.
def prune_tuple_cue_independent_steps(tup, focal_word = nil)
  return nil if tup.all? { |w| semantically_promiscuous?(w) }
  return nil if rhyming_tuple_all_spelling_variants?(tup)
  condense_tuple_derived_forms(tup, focal_word)
end

# Cross-tuple redundancy sweep: drops tuples that differ from another
# already-kept tuple only by parallel +Inflect+ suffixes, hidden-base
# parallelism, or lemma-multiset inclusion. Operates on a pre-sorted list
# of tuples that have already been through the cue-independent steps
# (stop-word/spelling-variant drops, derivation condensation),
# within-tuple homophone condensation, and the below-two-member drop.
#
# Focal-independent: every redundancy decision routes through
# +rhyming_tuple_redundant_with?+, whose entire transitive call graph is
# pure over +(ear, tup)+ (no +focal_word+ dependency anywhere). Safe to
# share a +rhyming_tuple_redundant_with?+ memoization layer across cues;
# the only cue-specific input is the per-cue tuple list itself.
#
# Indexing: tuples are bucketed by an "inflection-key" fingerprint
# (+tuple_redundancy_keys_for_word+) so each new +tup+ only compares
# against +kept+ entries that share at least one key. Every branch in
# +rhyming_tuple_redundant_with?+ ultimately routes through
# +inflection_suffix_kind_from_base+,
# +Inflect.raw_candidate_bases_for_inflected+, or
# +rhyming_tuple_word_bases+ — all three require the two tuples' words to
# share a lemma / inflection base, so disjoint-fingerprint tuples can be
# pruned from consideration without ever invoking the predicate. This
# collapses the original O(N^2) scan to roughly O(N * avg_bucket_size)
# and is the difference between cat (654 tuples → 11 s) and pirate (~900
# tuples) in the 29-second API Gateway budget — see +[timing]
# set_related[<word>] prune+ in CloudWatch under
# +RHYMECRIME_LOG_TIMING=1+.
#
# Insertion-order semantics are preserved: +kept+ is a Hash (which
# iterates in insertion order on MRI), so +kept.values+ at the bottom
# returns the same sequence as the previous +kept+ Array would have.
# +Set+ is used for the inverted index so candidate-lookup is O(1) per
# key.
#
# The fingerprint must be a *superset* of every reachable redundancy
# match or we silently drop comparisons. +rhyming_tuple_word_bases+ alone
# is too narrow because +inflection_suffix_kind_from_base+ has several
# extensions beyond +Inflect.match_suffix_kind+ that don't show up in the
# Inflect base table: +:y_adj+ (+health → healthy+), +:er+ via +-or+
# (+sail → sailor+), +:ing_gdrop+ (+fakin' → faking+), +:ings+ (+foist →
# foistings+, mostly already covered by Inflect's +-s+ stripping but
# mirrored here for safety), and the two-step +:y_adj_er+ / +:y_adj_est+
# chain (+feather → featherier+, +leather → leatheriest+).
# +tuple_redundancy_keys_for_word+ inlines those reversals against the
# surface, *unvalidated* — false positives in the pre-filter just mean we
# run the real predicate on a few extra pairs, which is cheap. False
# negatives would silently change pruning output (regression in
# +spec/prune_redundant_tuples_spec.rb+).
def prune_cross_tuple_redundancy_sweep(sorted_tuples)
  verbose_prunes = ENV["VERBOSE"] == "1"
  debug_pruning = $debug_pruning

  base_index = Hash.new { |h, k| h[k] = Set.new }
  kept = {}
  kept_bases = {}
  next_idx = 0

  bases_for_tuple = lambda do |tup|
    set = Set.new
    tup.each { |w| set.merge(tuple_redundancy_keys_for_word(w)) }
    set
  end

  sorted_tuples.each do |tup|
    bases = bases_for_tuple.call(tup)
    candidate_idx = Set.new
    bases.each { |b| candidate_idx.merge(base_index[b]) }

    keeper_idx = candidate_idx.find { |ki| rhyming_tuple_redundant_with?(kept[ki], tup) }
    if keeper_idx
      if verbose_prunes
        puts "pruned rhyming tuple (suffix-redundant): #{tup.join(' / ')}  [kept: #{kept[keeper_idx].join(' / ')}]"
      end
      if debug_pruning
        $debug_pruned_tuples << tup
        # Under debug, the pruned tuple still flows through to the output (the
        # renderer paints it grey via +output_tuple_pruned+). Index it like any
        # other survivor so later candidates can find it as a +keeper+ too —
        # mirrors the original +kept << tup+ behavior.
        kept[next_idx] = tup
        kept_bases[next_idx] = bases
        bases.each { |b| base_index[b] << next_idx }
        next_idx += 1
      end
      next
    end

    # +tup+ stands; check whether it obsoletes any earlier +ear+. Only candidate
    # indices need checking (other entries in +kept+ have disjoint base sets and
    # so can't be redundant with +tup+ under any branch of the predicate).
    to_remove = []
    candidate_idx.each do |ki|
      ear = kept[ki]
      next unless ear
      redundant = rhyming_tuple_redundant_with?(tup, ear)
      next unless redundant

      if verbose_prunes
        puts "pruned rhyming tuple (suffix-redundant): #{ear.join(' / ')}  [kept: #{tup.join(' / ')}]"
      end
      if debug_pruning
        $debug_pruned_tuples << ear
        # Retain ear (marked pruned) instead of rejecting it — matches the
        # original +next false+ branch in +kept.reject!+.
      else
        to_remove << ki
      end
    end

    to_remove.each do |ki|
      kept_bases[ki].each { |b| base_index[b].delete(ki) }
      kept.delete(ki)
      kept_bases.delete(ki)
    end

    kept[next_idx] = tup
    kept_bases[next_idx] = bases
    bases.each { |b| base_index[b] << next_idx }
    next_idx += 1
  end

  kept.values
end

# Drop rhyming tuples that differ from another tuple only by parallel +Inflect+ suffixes
# (e.g. plural or past tense of the same set). Handles four regimes:
#
#   0. whole-tuple spelling-variant drop: all members are alternate spellings of one root
#      (+desperados / desperadoes+ → drop)
#   1. same-length base/inflected pair: keep the base, prune the inflected
#   2. richer-vs-smaller inflectional subset: keep the richer tuple
#   3. base-vs-inflected-superset (richer inflected has extra members not in the base): keep the
#      richer inflected
#
# Pipeline:
#
#   * Cue-independent per-tuple steps — factored into
#     +prune_tuple_cue_independent_steps+ so an en-masse caller can
#     memoize the result. Runs (in order): the *stop-word wholesale drop*
#     (drop tuples that are all stop words — +above / of+), the
#     *spelling-variant wholesale drop* (drop tuples whose members are
#     all spelling variants of one root — +desperados / desperadoes+),
#     and *within-tuple derivation condensation* (drop +COMMON_PREFIXES+
#     derivation members whose +rhyme_syllables_string+ matches a base
#     already in the tuple — +[healthy, stealthy, unhealthy] → [healthy,
#     stealthy]+).
#   * Within-tuple homophone condensation — +condense_tuple_homophones+.
#     The *only* prune step that consults +focal_word+: breaks residual
#     full-pronunciation homophone clusters (+coral+/+choral+,
#     +flour+/+flower+, +write+/+right+) by picking the member most
#     closely related to the cue (tie-break: unigram frequency, then
#     alphabetical). Requires a non-nil +focal_word+; otherwise this
#     sub-pass is a no-op.
#   * Below-two-member drop — drop tuples whose condensation collapsed
#     them below 2 members. A "rhyming tuple" with one (or zero) word is
#     no longer a rhyme — the input was a pure prefix-derivation pair
#     like +[legitimate, illegitimate]+ or a homophone cluster like
#     +[coral, choral]+, and condense_tuple_* picked the one keeper.
#     Without this drop the singleton would survive the pruner and render
#     as a single-word "tuple". Callers (find_rhyming_tuples) already
#     filter +size < 2+ on the way out, but the unit pruner itself owes
#     the same contract so spec assertions on
#     +prune_suffix_redundant_rhyming_tuples+ output match what the UI
#     ultimately renders.
#   * Cross-tuple redundancy sweep — focal-independent O(N * avg_bucket_size)
#     pass factored into +prune_cross_tuple_redundancy_sweep+. Drops
#     tuples redundant with another already-kept tuple under any of the
#     +rhyming_tuple_redundant_with?+ branches.
#
# Checks are bidirectional against the kept list because +tuples.sort+ does not reliably
# front-load base forms (e.g. +"artilleries" < "artillery"+ because +"i" < "y"+).
#
# Set +VERBOSE=1+ in the environment to print each pruned tuple (and the kept tuple it matched);
# this is separate from +$debug_mode+ / +debug+, which remain very chatty elsewhere.
#
# When +$debug_pruning+ is true (set per-request from the +debug=1+ URL param), tuples that
# would normally be dropped are instead retained in the returned array AND recorded in
# +$debug_pruned_tuples+, so the renderer can display them inline, greyed out, alongside
# the kept tuples.
def prune_suffix_redundant_rhyming_tuples(tuples, focal_word = nil)
  verbose_prunes = ENV["VERBOSE"] == "1"
  debug_pruning = $debug_pruning

  # Cue-independent per-tuple steps via the pure helper (stop-word
  # wholesale drop, spelling-variant wholesale drop, within-tuple
  # derivation condensation). The orchestrator handles the verbose /
  # debug-pruning side effects so the helper itself stays a pure function
  # of its tuple.
  tuples = tuples.flat_map do |tup|
    survivor = prune_tuple_cue_independent_steps(tup, focal_word)
    if survivor.nil?
      # Wholesale drop (semantically-promiscuous or spelling-variant).
      reason = tup.all? { |w| semantically_promiscuous?(w) } ? "all semantically promiscuous" : "all spelling variants of one root"
      puts "pruned rhyming tuple (#{reason}): #{tup.join(' / ')}" if verbose_prunes
      $debug_pruned_tuples << tup if debug_pruning
      next debug_pruning ? [tup] : []
    end
    # Within-tuple derivation condensation may have shortened the tuple.
    # Under debug we retain the original tup so the renderer keeps
    # showing it (with the dropped member recorded as a singleton in
    # +$debug_pruned_tuples+); the downstream homophone condensation then
    # runs on the retained original, which is semantically equivalent
    # because prefix-derivation drops and full-pronunciation homophone
    # clusters are disjoint by construction (a prefix derivation has an
    # extra phoneme prefix that makes it phonologically distinct from
    # its base).
    if verbose_prunes && survivor.size < tup.size
      dropped = tup - survivor
      puts "condensed rhyming tuple (dropped #{dropped.inspect}, derived forms): #{tup.join(' / ')} -> #{survivor.join(' / ')}"
    end
    if debug_pruning
      (tup - survivor).each { |w| $debug_pruned_tuples << [w] }
      [tup]
    else
      [survivor]
    end
  end

  # Within-tuple parallel-derivation condensation — focal-dependent.
  # Collapse +[disorient, reorient]+ / +[illegal, extralegal]+-style
  # parallel sibling pairs (two members sharing a non-self prefix-strip
  # ancestor that pron-suffix-aligns with both). Cue-aware tie-break in
  # +parallel_sibling_loser+ keeps the sibling more similar to
  # +focal_word+ — pirate's tuple keeps +illegal+ over +extralegal+,
  # constitution's tuple would keep +extralegal+ over +illegal+.
  tuples = tuples.map do |tup|
    condensed = condense_tuple_parallel_derivations(tup, focal_word)
    if verbose_prunes && condensed.size < tup.size
      dropped = tup - condensed
      puts "condensed rhyming tuple (dropped #{dropped.inspect}, parallel derivations): #{tup.join(' / ')} -> #{condensed.join(' / ')}"
    end
    if debug_pruning
      (tup - condensed).each { |w| $debug_pruned_tuples << [w] }
      tup
    else
      condensed
    end
  end

  # Within-tuple homophone condensation — focal-dependent. Within each
  # tuple, break full-pronunciation homophone clusters down to one
  # winner by stored relatedness to +focal_word+.
  tuples = tuples.map do |tup|
    condensed = condense_tuple_homophones(tup, focal_word)
    if verbose_prunes && condensed.size < tup.size
      dropped = tup - condensed
      puts "condensed rhyming tuple (dropped #{dropped.inspect}, homophones): #{tup.join(' / ')} -> #{condensed.join(' / ')}"
    end
    if debug_pruning
      (tup - condensed).each { |w| $debug_pruned_tuples << [w] }
      tup
    else
      condensed
    end
  end

  # Below-two-member drop: drop tuples whose condensation collapsed them below 2 members.
  tuples = tuples.reject do |tup|
    next false if tup.size >= 2
    if verbose_prunes
      puts "pruned rhyming tuple (collapsed below 2 members during condensation): #{tup.join(' / ')}"
    end
    $debug_pruned_tuples << tup if debug_pruning
    !debug_pruning
  end

  return tuples.sort if $disable_cross_tuple_redundancy_pruning

  prune_cross_tuple_redundancy_sweep(tuples.sort)
end

# Related headwords for tuple/pair construction: common (freq > +RARE_FREQ_MAX+) and preferred surface
# (+preferred_form_in_build_lexicon+ when +word_dict+ is populated, else +preferred_form+).
def word_common_preferred_for_tuple_or_pair?(w)
  entry = lexicon_word_entry(w)
  return false unless entry
  return false if entry[0].to_i <= RARE_FREQ_MAX

  wd = word_dict
  if wd.is_a?(Hash) && !wd.empty? && wd.key?(w)
    preferred_form_in_build_lexicon(w, wd) == w
  else
    preferred_form(w) == w
  end
end

def filter_related_words_to_common_preferred(words)
  words.select { |w| word_common_preferred_for_tuple_or_pair?(w) }
end

# Maximum number of entries held by each of the rhyming-result LRU caches
# (+$rhyming_tuple_cache+ and +$rhyming_pair_cache+). Small by design: a single
# web request typically hits only a handful of distinct (word[, word2], common_only)
# keys, so 30 is plenty to absorb repeat calls without letting the caches grow
# unboundedly across a long-running process.
RHYMING_LRU_CACHE_SIZE = 30

# LRU cache backed by a Ruby Hash (which preserves insertion order). On a hit
# we delete + reinsert the key to bump it to the most-recently-used slot; on a
# miss we evict the oldest entry via +shift+ once capacity is exceeded. The
# block passed to +lru_cache_fetch+ is only invoked on a miss.
def lru_cache_fetch(cache, key, capacity)
  if cache.key?(key)
    value = cache.delete(key)
    cache[key] = value
    return value
  end
  value = yield
  cache[key] = value
  cache.shift while cache.size > capacity
  value
end

$rhyming_tuple_cache = {}
def find_rhyming_tuples(input_rel1, common_only = false)
  # Skip the computed-store and LRU paths when +$debug_pruning+ is true:
  # the pruner side-effects +$debug_pruned_tuples+ (a per-request Set consulted
  # by +print_tuple+ for the grey pruning color), and returning cached results
  # (whether from +$rhyming_tuple_cache+ or the computed +set_related#+ row)
  # would bypass that population, leaving retained-pruned tuples un-colored.
  # Debug requests are rare so recomputing is fine. We also avoid populating
  # +$rhyming_tuple_cache+ from debug-mode results, since those include tuples
  # that non-debug callers expect to have been dropped.
  return really_find_rhyming_tuples(input_rel1, common_only) if $debug_pruning
  return really_find_rhyming_tuples(input_rel1, common_only) if $disable_cross_tuple_redundancy_pruning

  # Computed-store path: +bin/compute-set-related+ stashes the fully
  # post-pruned tuple list for every cue lemma in the cueniverse. The Lambda
  # runtime (+DataSource.dynamodb?+ → +store_authoritative?+) treats a missing
  # row as "this cue isn't in our common-word set" and returns +nil+ here so
  # the goal-dispatch branch in +rhymecrime+ can render the friendly
  # bad_input message ("I don't like that word." for forbid_list cues, "Oops,
  # I don't know what words are related to <cue>..." otherwise). Local-dev
  # (+LocalStore+, non-authoritative) falls through to the live-compute path
  # so spec runs and pre-compute checkouts still produce results.
  if Rhymecrime::Store.available?
    cached = Rhymecrime::Store.fetch_set_related_tuples(lemma(input_rel1))
    return cached if cached
    return nil if store_authoritative?
  end

  lru_cache_fetch($rhyming_tuple_cache, [input_rel1, common_only], RHYMING_LRU_CACHE_SIZE) do
    really_find_rhyming_tuples(input_rel1, common_only)
  end
end

def really_find_rhyming_tuples(input_rel1, common_only = false)
  # Rhyming word sets that are related to INPUT_REL1.
  # Each element of the returned array is an array of words that rhyme with each other and are all related to INPUT_REL1.
  # Algorithm:
  # Compute the set of all words thematically related to INPUT_REL1, call it RELATEDS1.
  # For each word REL1 in RELATEDS1,
  #   Get all rhymes RHYME1 of REL1.
  #   If R is in RELATEDS1, compute R's rime and put RHYME1 in the bucket labeled by that rime.
  # Return all buckets with two or more words in them, after +prune_suffix_redundant_rhyming_tuples+
  # drops tuples that only parallel an earlier tuple's +Inflect+ suffixes (e.g. all plural or all past).
  #
  # +Rhymecrime::Timing.measure+ wrappers below are no-ops unless
  # +RHYMECRIME_LOG_TIMING=1+ is set (template.yaml turns this on for the
  # deployed Lambda). The phase labels mirror the algorithm steps above so a
  # CloudWatch grep for +[timing] set_related[<word>]+ tells you whether the
  # 29-second budget is being eaten by find_related (single +get_item+ on
  # +related#<lemma>+ + N batched gets), prefetch (rhyme-cohort fan-out), the
  # main rhyme-bucket loop (in-memory after prefetch), or prune (O(N^2) cross-
  # tuple suffix-redundancy check).
  return [] if explicitly_forbidden?(input_rel1)

  related_list = Rhymecrime::Timing.measure("set_related[#{input_rel1}] find+filter related") do
    filter_related_words_to_common_preferred(
      find_related_words(input_rel1, true, false, nil, common_only: true)
    )
  end
  relateds1 = related_list.to_set

  related_rhymes = Hash.new { |h, k| h[k] = [] }
  Rhymecrime::Timing.measure("set_related[#{input_rel1}] rhyme-bucket loop n=#{related_list.size}") do
    related_list.each do |rel1|
      pronunciations(rel1).each do |rel1pron|
        rime = rel1pron.rime
        debug "Rhymes for #{rel1} [#{rime}] #{debug_info(rel1)}:"
        find_rhyming_words_for_pronunciation(rel1pron, true).each do |rhyme1|
          if relateds1.include?(rhyme1) # we only care about relateds of input_rel1
            rhyme1 = preferred_form(rhyme1) # push 'honor' instead of 'honour'. This will ensure we don't push both.
            related_rhymes[rime].push(rhyme1)
            debug " #{rhyme1} #{debug_info(rhyme1)}"
          end
        end
      end
    end
  end

  tuples = []
  related_rhymes.each do |_rime, relrhymes|
    relrhymes.sort!.uniq!
    tuples.push(relrhymes.sort) if relrhymes.length > 1 && !all_identical_rhymes?(relrhymes)
  end
  # Alternate pronunciations can yield different +rime+ keys (e.g. OW_L_IY_AH_N vs OW_L_Y_AH_N) with the
  # same sorted word set — dedupe before suffix pruning so output is not repeated line-for-line.
  tuples.uniq!
  Rhymecrime::Timing.measure("set_related[#{input_rel1}] prune tuples=#{tuples.size}") do
    prune_suffix_redundant_rhyming_tuples(tuples, input_rel1).reject { |tup| tup.nil? || tup.size < 2 }
  end
end

$rhyming_pair_cache = {}
def find_rhyming_pairs(input_rel1, input_rel2, common_only = false)
  # Mirrors +find_rhyming_tuples+'s caching policy: bypass the cache whenever
  # +$debug_pruning+ is true so pruning side-effects still populate.
  return really_find_rhyming_pairs(input_rel1, input_rel2, common_only) if $debug_pruning
  return really_find_rhyming_pairs(input_rel1, input_rel2, common_only) if $disable_cross_tuple_redundancy_pruning

  lru_cache_fetch($rhyming_pair_cache, [input_rel1, input_rel2, common_only], RHYMING_LRU_CACHE_SIZE) do
    really_find_rhyming_pairs(input_rel1, input_rel2, common_only)
  end
end

def really_find_rhyming_pairs(input_rel1, input_rel2, common_only = false)
  # Pairs of rhyming words where the first word is related to INPUT_REL1 and the second word is related to INPUT_REL2
  # Each element of the returned array is a pair of rhyming words [W1 W2] where W1 is related to INPUT_REL1 and W2 is related to INPUT_REL2
  # Algorithm:
  # Compute the set of all words thematically related to INPUT_REL1, call it RELATEDS1.
  # Compute the set of all words thematically related to INPUT_REL2, call it RELATEDS2.
  # For each word REL1 in RELATEDS1,
  #   Get all non-identical rhymes RHYME of REL1.
  #   If RHYME rhymes with REL1 and is related to INPUT_REL2, we win! "REL1 / RHYME" is a pair.
  return [] if explicitly_forbidden?(input_rel1) || explicitly_forbidden?(input_rel2)

  # Semantically promiscuous words are thematically related to everything by
  # policy, which would otherwise flood the pair output with pairs like
  # [perhaps, duh] / [could, then]. A 2-element pair has no room for a
  # go-word anchor when either side is promiscuous, so we drop those before
  # the rhyme cross.
  relateds1 = filter_related_words_to_common_preferred(
    find_related_words(input_rel1, true, false, nil, common_only: true)
  ).reject { |w| semantically_promiscuous?(w) }
  relateds2 = filter_related_words_to_common_preferred(
    find_related_words(input_rel2, true, false, nil, common_only: true)
  ).reject { |w| semantically_promiscuous?(w) }.to_set

  related_rhymes = Hash.new { |h, k| h[k] = [] }
  relateds1.each do |rel1|
    # rel1 is a word related to input_rel1. We're looking for rhyming pairs [rel1 rel2].
    debug "rhymes for #{rel1} (#{debug_info(rel1)}):<br>"
    find_rhyming_words(rel1, false).each do |rhyme| # check all non-identical rhymes of REL1, call each one 'RHYME'
      if relateds2.include?(rhyme) # is RHYME related to INPUT_REL2? If so, we win!
        related_rhymes[rel1].push(rhyme)
        debug " " + rhyme + " " + debug_info(rhyme)
      end
    end
    debug "<br><br>"
  end

  pairs = []
  related_rhymes.each do |relrhyme1, relrhyme2_list|
    relrhyme2_list.each { |relrhyme2| pairs.push([relrhyme1, relrhyme2]) }
  end
  prune_trivial_rhyming_pairs(pairs)
end

#
# Display
#

def print_synsets(synsets, input_word)
  # prints the synsets in SYNSETS that are nontrivial wrt INPUT_WORD
  isFirst = true
  for synset in synsets
    synonyms = synset.words - [ input_word ]
    unless(synonyms.empty?)
      unless isFirst
        cgi_print "<br>"
      end
      isFirst = false;
      cgi_print "<i>"
      emit_line(short_gloss(synset))
      cgi_print "</i>"
      emit_line
      print_words(synonyms)
    end
  end
end

def short_gloss(synset)
  gloss = synset.gloss
  i = gloss.index(';')
  if i
    return gloss[0,i]
  else
    return gloss
  end
end

# +cues+ in tuple/words printers can be:
#   * +nil+ — no thumbs feedback rendered (e.g. plain rhymes column).
#   * a +String+ — uniform cue for every slot (set_related uses word1; the
#     debug +related+ column uses word1; +related_rhymes+ uses word2).
#   * an +Array+ — per-slot cue, parallel to the tuple (used by pair_related,
#     where slot 0's cue is word1 and slot 1's cue is word2).
# +cue_for+ resolves which to use for a given slot index in a tuple.
def cue_for(cues, index)
  return nil if cues.nil?
  cues.is_a?(Array) ? cues[index] : cues
end

def print_tuple(tuple, focal_word=false, cues: nil)
  # this basically just pushes the rare words to the end, but we could do something snazzier if we want
  pruned_class = ($debug_pruning && $debug_pruned_tuples&.include?(tuple)) ? " output_tuple_pruned" : ""
  cgi_print "<div class='output_tuple#{pruned_class}'><p class='output_p'>"
  # Sub-tuples (good/bad) inherit a sliced view of +cues+ when +cues+ is an
  # Array, so the per-slot cue stays aligned with the rare-word reordering.
  good_idx = tuple.each_index.reject { |i| rare?(tuple[i]) }
  bad_idx  = tuple.each_index.select { |i| rare?(tuple[i]) }
  good_tuple = good_idx.map { |i| tuple[i] }
  bad_tuple  = bad_idx.map { |i| tuple[i] }
  good_cues  = cues.is_a?(Array) ? good_idx.map { |i| cues[i] } : cues
  bad_cues   = cues.is_a?(Array) ? bad_idx.map  { |i| cues[i] } : cues

  if(good_tuple.empty?)
    print_half_of_tuple(bad_tuple, focal_word, cues: bad_cues)
  elsif(bad_tuple.empty?)
    print_half_of_tuple(good_tuple, focal_word, cues: good_cues)
  else
    print_half_of_tuple(good_tuple, focal_word, cues: good_cues)
    emit_text " / "
    print_half_of_tuple(bad_tuple, focal_word, cues: bad_cues)
  end
  cgi_print "</p></div>"
  emit_line
  STDOUT.flush unless Thread.current[:html_output_buffer]
end

def print_half_of_tuple(tuple, focal_word=false, cues: nil)
  # print TUPLE separated by slashes
  tuple.each_with_index do |elem, i|
    emit_text " / " if i > 0
    print_word(elem, focal_word, cue: cue_for(cues, i))
  end
end

def print_tuples(tuples, focal_word=false, cues: nil)
  # return boolean, did I print anything? i.e. was TUPLES nonempty?
  success = !tuples.empty?
  if(success)
    tuples.sort.uniq.each { |tuple|
      print_tuple(tuple, focal_word, cues: cues)
    }
  end
  return success
end

def print_words(words, focal_word=false, cue: nil)
  success = !words.empty?
  if(success)
    words.sort.uniq.each { |word|
      cgi_print "<div class='output_tuple'>"
      cgi_print "<p class='output_p'>"
      print_word(word, focal_word, cue: cue)
      if($display_word_frequencies)
        emit_text " (#{frequency(word)})"
      end
      cgi_print "</p>"
      cgi_print "</div>"
      emit_line
    }
  end
  return success
end

def ubiquity(word)
  # 0-255
  result = 0
  case frequency(word)
  when 0
    result = 0
  when 1
    result = 40
  when 2..5
    result = 80
  when 6..20
    result = 120
  when 21..100
    result = 160
  when 101..1000
    result = 200
  else
    result = 255
  end
  result
end

def rare?(word)
  frequency(word) <= RARE_FREQ_MAX
end

def filter_out_rare_words(words)
  # When you enter e.g. 'kitten', you'll get back some reasonable
  # things like 'bitten', 'britain', and 'smitten', but you'll also
  # get back crap like 'bitton', 'brittain', 'brittan', 'brittin',
  # 'britton', 'ditton', 'fitton', etc.
  #
  # Some of these are rare words, and some are just
  # mistakes. Regardless, we don't want them in our output. They
  # clutter up the place and make the good rhymes harder to see.
  #
  # We don't want to get rid of them entirely, though; occasionally
  # that rare word is exactly the one you want, or a good word gets
  # misfiled as rare. So instead we put them in the 'dregs' bucket,
  # which shows up as "For the desperate:" on the website.
  good = words.reject{ |w| rare?(w) }
  bad = words.select { |w| rare?(w) }
  return good, bad
end

def rare_tuple?(tuple, threshold=2)
  common_count = 0
  for word in tuple
    unless rare?(word)
      common_count = common_count + 1
      if(common_count >= threshold)
        return false
      end
    end
  end
  return true
end

def filter_out_rare_tuples(tuples)
  # A tuple gets to be common if it contains at least two common words
  good = tuples.reject{ |t| rare_tuple?(t) }
  bad = tuples.select { |t| rare_tuple?(t) }
  return good, bad
end

def print_word(word, focal_word=false, cue: nil)
  word = word.gsub(/\(.*\)/, '') # remove stuff in parentheses
  got_rhymes = !pronunciations(word).empty?
  # Semantically promiscuous words ("could", "perhaps", "henceforth", ...)
  # get rendered (mostly via the rhymes column) but we strip the click link
  # off them: clicking such a word would land the user on a page where the
  # related/set_related columns short-circuit with the "semantically
  # promiscuous" message in +frontend.rb+, which is a dead-end UX. Letting
  # them rhyme is fine, but linking them is not. (Unrhymable stop words like
  # "the"/"a"/"you'll" are deleted from +word_dict+ at build time, so they
  # never reach this render path.) The +.stop-word+ CSS class below paints
  # them gray (+#bbb+); without it they'd
  # inherit the +.output_p+ container's cyan and look identical to clickable
  # links.
  is_promiscuous = semantically_promiscuous?(word)
  link_word = got_rhymes && !is_promiscuous
  # Decided here (not at +emit_relatedness_feedback_widget+'s call site) so the
  # +<nobr>+ wrapper below uses exactly the same predicate as the widget itself
  # — we never want a +<nobr>+ that wraps just the word with no thumbs to glue
  # it to. Predicate matches the original guard verbatim, plus suppression for
  # semantically promiscuous words (no meaningful relatedness vote).
  emit_thumbs = cue && !cue.to_s.empty? && cue != word && !is_promiscuous
  # +<nobr>+ keeps the word + (optional similarity span) + (optional similarity
  # %) + thumbs widget on the same display line. Without it, the inline span
  # for the word and the inline span for +.feedback-thumbs+ are independent
  # break opportunities — the browser will happily land "transparent" at the
  # end of one row and float its 👍👎 onto the next, which reads like an
  # orphan vote control. +.feedback-thumbs { white-space: nowrap }+ already
  # keeps the two thumbs glued to *each other*, so this only adds the
  # outer-tier glue between the word and the widget. +<nobr>+ over a CSS
  # +white-space: nowrap+ wrapper because the user asked for it explicitly
  # and it's understood by every shipping browser; if it ever needs swapping
  # for the standards-track equivalent, the change is span+class right here.
  cgi_print "<nobr>" if emit_thumbs
  if(link_word)
    # @todo urlencode
    cgi_print "<a href='/?word1=#{word}'>"
  end
  # Color the word by its computed relatedness_score to +focal_word+ when one
  # is supplied (e.g. +set_related+ tuples, where every slot should be related
  # to +word1+). Skipped when +focal_word+ is falsy (word lists that have no
  # single focal, or +pair_related+ tuples whose two slots use different focals).
  # Promiscuous words can never set both branches simultaneously: the
  # +set_related+ rendering path that drives +similarity_span+ short-circuits
  # before +print_word+ when +word1+ is promiscuous (see +compute_column_for_goal+),
  # and the rhymes columns that would render a promiscuous word as a result don't
  # set +focal_word+.
  similarity_span = focal_word && focal_word != "" && word != focal_word
  if similarity_span
    cgi_print "<span style='color: #{word_similarity_color(word, focal_word)}'>"
  elsif is_promiscuous
    cgi_print "<span class='stop-word'>"
  end
  display_word = word.gsub('_', ' ')
  emit_text display_word
  cgi_print "</span>" if similarity_span || is_promiscuous
  if(link_word)
    cgi_print "</a>"
  end
  if($display_word_similarities)
    print_html_percent_similarity(display_word, focal_word)
  end
  # Inline thumbs-up / thumbs-down for relatedness feedback. Suppressed when
  # +cue+ is nil (no relatedness column, e.g. plain rhymes), when the
  # rendered word is the cue itself (relatedness to self is uninteresting), or
  # when the word is semantically promiscuous (+thematically_related?+ treats those
  # pairs as trivially related, so a vote would be meaningless).
  # The data attributes carry the *underscore* surface so what we POST to
  # +/feedback+ matches the shape of +curated/related.csv+'s +cue+/+related+
  # columns; +feedback.js+ wires the click → fetch and uses +sessionStorage+
  # to persist the user's vote across navigations within the tab.
  emit_relatedness_feedback_widget(word, cue) if emit_thumbs
  cgi_print "</nobr>" if emit_thumbs
end

# Inline SVG so the icons inherit color via +fill="currentColor"+ and CSS
# can drive vote-state color (up: #00fa9a, down: #ff355e). Emoji 👍/👎 were
# rejected because their rendering is font-multicolor by default and can't
# be re-tinted to a single brand color without filter hacks.
#
# Base shapes are Google Material's +thumb_up+ / +thumb_down+ (filled),
# adopted because they're the most universally-recognized thumbs silhouette
# and stay readable at our 0.85em inline-with-text size. Both icons are
# tweaked identically: thumb elongated to stick out ~30% farther from the
# palm (9.1u vs Material's 7u), while the palm + forearm geometry stays
# exactly Material's. The viewBox is extended on the thumb-pointing side
# to give the longer tip room to render.
#
# Up-thumb edits (Material path → tweaked):
#   * viewBox +0 0 24 24+ → +0 -2 24 26+ (headroom ABOVE the icon)
#   * +l.95-4.57+ (right-side rise into tip apex) → +l.95-6.67+
#   * +L14.17 1+ (absolute thumb-tip endpoint) → +L14.17 -1.1+
#
# Down-thumb is up-thumb rotated 180° about (12, 12), so equivalent edits
# (with directions flipped) are:
#   * viewBox +0 0 24 24+ → +0 0 24 26+ (headroom BELOW the icon)
#   * +l-.95 4.57+ (right-side descent into tip apex) → +l-.95 6.67+
#   * +L9.83 23+ (absolute thumb-tip endpoint) → +L9.83 25.1+
#   * +l6.59-6.59+ (RELATIVE return from tip to palm corner) → +l6.59-8.69+
#     The return segment is relative in the down path (unlike up, which uses
#     an implicit absolute lineto after L), so its delta has to absorb the
#     additional 2.1u of thumb extension; otherwise the upper-right palm
#     corner would shift along with the tip.
#
# Everything else (forearm rectangle, palm curves, finger fold, lower wrist
# sweep) is byte-for-byte Material's, so both icons still read as the
# Material thumbs — just with more prominent thumbs.
THUMB_UP_SVG = '<svg viewBox="0 -2 24 26" width="1em" height="1em" aria-hidden="true" focusable="false">' \
  '<path fill="currentColor" d="M2 21h4V9H2v12zM23 10c0-1.1-.9-2-2-2h-6.31l.95-6.67.03-.32c0-.41-.17-.79-.44-1.06L14.17 -1.1 7.59 7.59C7.22 7.95 7 8.45 7 9v10c0 1.1.9 2 2 2h9c.83 0 1.54-.5 1.84-1.22l3.02-7.05c.09-.23.14-.47.14-.73v-2z"/>' \
  '</svg>'
THUMB_DOWN_SVG = '<svg viewBox="0 0 24 26" width="1em" height="1em" aria-hidden="true" focusable="false">' \
  '<path fill="currentColor" d="M15 3H6c-.83 0-1.54.5-1.84 1.22l-3.02 7.05C1.05 11.5 1 11.74 1 12v2c0 1.1.9 2 2 2h6.31l-.95 6.67-.03.32c0 .41.17.79.44 1.06L9.83 25.1l6.59-8.69C16.78 16.05 17 15.55 17 15V5c0-1.1-.9-2-2-2zm4 0v12h4V3h-4z"/>' \
  '</svg>'

def emit_relatedness_feedback_widget(word, cue)
  c = CGI.escape_html(cue.to_s)
  w = CGI.escape_html(word.to_s)
  # No leading whitespace before +<span>+: the gap-between-word-and-thumbs is
  # entirely controlled by +.feedback-thumbs { margin-left }+ in CSS, so a
  # textual space would stack on top of that and widen the gap unpredictably.
  cgi_print(
    "<span class='feedback-thumbs' data-cue='#{c}' data-related='#{w}'>" \
    "<button type='button' class='thumb thumb-up' aria-label='thumbs up #{w} as related to #{c}'>#{THUMB_UP_SVG}</button>" \
    "<button type='button' class='thumb thumb-down' aria-label='thumbs down #{w} as related to #{c}'>#{THUMB_DOWN_SVG}</button>" \
    "</span>"
  )
end

#
# Central dispatcher
#

def focal_word(word)
  return "\"<span class='focal_word'>#{word}</span>\""
end

def rhymecrime(word1, word2, goal, output_format='text', debug_mode=false)
  # When you enter a single word,
  #   RhymeCrime displays rhymes for that word (see find_rhyming_words), separating out the rare words (see rare?)
  #   and in a separate column, displays sets of rhyming words (see find_rhyming_tuples)
  # When you enter two words,
  #   RhymeCrime first displays rhymes for WORD1 that are thematically related to WORD2 (see related_rhymes),
  #   and in a separate column, displays pairs of rhyming words (RHYME1 / RHYME2) in which RHYME1 is related to WORD1 and RHYME2 is related to WORD2. (see find_rhyming_pairs)
  $output_format = output_format
  $debug_mode = debug_mode
  header_eol = ":<div class='results'>"
  
  result = nil
  dregs = [ ]
  result_type = :error # :words, :tuples, :bad_input, :vacuous, :error
  result_header = "Unexpected error."

  # special cases
  if(word1 == "" and word2 == "")
    return nil, :vacuous, ""
  end
  if(word1 == "" and word2 != "")
    word1, word2 = word2, word1
  end

  # main list of cases
  case goal
  when "rhymes"
    result_header = "Rhymes for " + focal_word(word1) + header_eol
    result, dregs = filter_out_rare_words(find_preferred_rhyming_words(word1))
    result_type = :words
  when "related"
    result_header = "Words related to " + focal_word(word1) + header_eol
    result, dregs = filter_out_rare_words(filter_out_rhymeless_words(find_related_words(word1, false)))
    result_type = :words
  when "set_related"
    tuples = find_rhyming_tuples(word1)
    if tuples.nil?
      # +find_rhyming_tuples+ returns +nil+ only when the computed-store
      # path is authoritative (Lambda) and the cue has no +set_related#<lemma>+
      # row. Three reasons the cue might land here, each with its own copy:
      #
      #   * +explicitly_forbidden?(word1)+ — the word is on +forbid_list.txt+,
      #     deleted from +word_dict+ at build time, and the compute pass
      #     deliberately skipped it. Curt response — we know about that word
      #     and chose not to serve it.
      #   * +unrhymable_stop_word?(word1) || semantically_promiscuous?(word1)+
      #     — the word is a function word ("the", "of") or a generic
      #     emotional/discourse term ("nice", "good") that we explicitly
      #     decline to compute relateds for. The +set_related+ goal is the
      #     one place we want the *union* of those two lists: unrhymable
      #     stop words are deleted from +word_dict+ at build (so they
      #     never get a compute row); semantically-promiscuous words
      #     are also caught upfront by +compute_column_for_goal+ in
      #     +frontend.rb+, but we keep the predicate here as the
      #     authoritative answer when callers reach +rhymecrime+ via paths
      #     that bypass the upfront filter (CLI tools, eval scripts). The
      #     message matches +promiscuous_message+ in +frontend.rb+ so the
      #     two upstream paths render identically.
      #   * otherwise — the cue is rare / outside the computed cue
      #     universe. Apologetic response; the "I'll make a note" trailer
      #     is literal — +FeedbackStore.record_uncomputed_cue!+ writes a
      #     row tagged with +UNCOMPUTED_RELATED_TOKEN+ so the next
      #     compute round can surface and add the most-asked-about
      #     uncomputed cues. Soft-fails on backend trouble (see the
      #     rescue in +FeedbackStore.record!+) so a flaky feedback writer
      #     never 500s the user-visible response.
      result_header =
        if explicitly_forbidden?(word1)
          "I don't like that word."
        elsif unrhymable_stop_word?(word1) || semantically_promiscuous?(word1)
          "\"#{word1}\" is semantically promiscuous; can't compute related words"
        else
          Rhymecrime::FeedbackStore.record_uncomputed_cue!(cue: word1)
          "Oops, I don't know what words are related to #{focal_word(word1)}, sorry! I'll make a note."
        end
      result, dregs = [], []
      result_type = :bad_input
    else
      result_header = "Rhyming word sets related to " + focal_word(word1) + header_eol
      result, dregs = filter_out_rare_tuples(tuples)
      result_type = :tuples
    end
  when "pair_related"
    if(word1 == "" or word2 == "")
      result_header = "I need two words to find rhyming pairs. For example, Word 1 = <span class='focal_word'>crime</span>, Word 2 = <span class='focal_word'>heaven</span>"
      result_type = :bad_input
    else
      result_header = "Rhyming word pairs where the first word is related to" + " " + focal_word(word1) + " and the second word is related to " + " " + focal_word(word2) + header_eol
      result, dregs = filter_out_rare_tuples(find_rhyming_pairs(word1, word2))
      result_type = :tuples
    end
  when "related_rhymes"
    if(word1 == "" or word2 == "")
      result_header = "I need two words to find related rhyming pairs. For example, Word 1 = <span class='focal_word'>please</span>, Word 2 = <span class='focal_word'>cats</span>"
      result_type = :bad_input
    else
      result_header = "Rhymes for" + " " + focal_word(word1) + " that are related to " + focal_word(word2) + header_eol
      result, dregs = filter_out_rare_words(find_related_rhymes(word1, word2))
      result_type = :words
    end
  else
    result_header = "Invalid selection."
    result_type = :bad_input
  end
  debug "result = #{result}"
  debug "result_type = #{result_type}"
  return result, dregs, result_type, result_header
end

#
# Utilities
#

def related?(word1, word2, include_self=false)
  # Is word1 thematically related to word2?
  word1 = preferred_form(word1)
  word2 = preferred_form(word2)
  not explicitly_forbidden?(word1) and not explicitly_forbidden?(word2) and thematically_related?(word1, word2)
end

