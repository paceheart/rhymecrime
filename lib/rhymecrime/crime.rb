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
require_relative "dict/pronunciation.rb"
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
require_relative "dynamo_store" if Rhymecrime::DataSource.dynamodb?

#
# Lexicon: file-backed (+word_dict+) or DynamoDB (+Rhymecrime::DynamoRuntime+).
#

def lexicon_word_entry(word)
  if Rhymecrime::DataSource.dynamodb?
    Rhymecrime::DynamoRuntime.fetch_word(word)
  else
    word_dict[word]
  end
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
  # word => [frequency, pronunciations]
  # pronunciations = [pronunciation1, pronunciation2 ...]
  # pronunciation = [syllable1, syllable1, ...]
  if Rhymecrime::DataSource.dynamodb?
    $word_dict ||= {}
    return $word_dict
  end
  if $word_dict.nil?
    $word_dict = load_word_dict
  end
  $word_dict
end

WORDS_NEEDED_FOR_TESTING = ['arpeggio', 'asterisk', 'blackmail', 'bobcat', 'burglar', 'burglary', 'cat', 'celebrity', 'costume', 'crime', 'doubloons', 'drumsticks', 'fanciers', 'feline', 'fortissimo', 'galaxy', 'glissando', 'halloween', 'hemiola', 'homicide', 'item', 'jaguar', 'mandolin', 'music', 'overtone', 'pianissimo', 'pirate', 'pussy', 'repertoire', 'ritardando', 'scurvy', 'star', 'thing', 'tree', 'treetop', 'trespassing', 'whiskers', 'wildcat', 'xylophone'] # include these even if they don't have any rhymes

$rdict = nil # rime (underscore ARPABET key) -> words hash
def rdict
  # rime => [rhyming_word1 rhyming_word2 ...]
  if Rhymecrime::DataSource.dynamodb?
    $rdict ||= {}
    return $rdict
  end
  if $rdict.nil?
    $rdict = load_rime_dict_as_hash
  end
  $rdict
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
# in dict.rb (build). Empty if unknown or before generated/part_of_speech.json exists.
$part_of_speech_by_word = nil
def part_of_speech_tags(word)
  w = word.to_s.downcase.strip
  return [] if w.empty?
  if $part_of_speech_by_word.nil?
    path = generated_dict_path(PART_OF_SPEECH_FILENAME)
    $part_of_speech_by_word =
      if File.exist?(path)
        JSON.parse(File.read(path, encoding: "UTF-8"))
      else
        {}
      end
  end
  tags = $part_of_speech_by_word[w]
  tags.is_a?(Array) ? tags : []
end

# Cohort for +rime+ from +rime_dict+ (dict-build keeps preferred headwords only; see +strip_dispreferred_headwords_from_rdict!+).
def rdict_lookup(rime)
  if Rhymecrime::DataSource.dynamodb?
    Rhymecrime::DynamoRuntime.fetch_rime(rime)
  else
    rdict[rime] || []
  end
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

def prefix_words(words, focal_word)
  # All words in WORDS that would share the same root as FOCAL_WORD if you removed its prefix.
  # For example, if WORDS contains "able" and "disable", the prefix_words are ["disable"].
  # But if WORDS contained "unable" and "disable", there would be no prefix_words.
  # Recursive (compound) stripping was tried but regresses +served+/+undeserved+ etc. where
  # +un+de+served+ collapses to +served+ but the user considers the pair derivationally
  # distinct. Genuine compounds like +chanted+/+disenchanted+ (dis- + en-) are handled via
  # explicit compound entries in COMMON_PREFIXES (e.g. +disen+). Opaque/etymologically-
  # prefixed words that modern speakers don't perceive as derivational (+record+ = re+cord,
  # +deserve+ = de+serve, +ajar+ = a+jar) are accepted as splash damage; see the
  # corresponding +not_working_message+ pending tests in rhyme_spec.
  focal_roots = Array.new
  focal_roots << focal_word
  for prefix in COMMON_PREFIXES
    if focal_word.start_with?(prefix)
      root = focal_word[prefix.length..-1]
      if words.include?(root)
        focal_roots << root
      end
    end
  end

  result = Array.new
  for word in words
    if focal_roots.include?(word)
      result << word
    else
      for prefix in COMMON_PREFIXES
        if word.start_with?(prefix)
          root = word[prefix.length..-1]
          if focal_roots.include?(root)
            result << word
          end
        end
      end
    end
  end
  if result
    debug "Filtering out prefix words #{result} from #{words}"
  end
  return result
end

def find_rhyming_words(word, identical_ok=true)
  # merges multiple pronunciations of WORD
  # use our compiled rime dictionary
  rhyming_words = Array.new
  unless(explicitly_forbidden?(word))
    for form in all_forms(word) # to increase the likelihood of a hit, try all spelling variants
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
  end
  return rhyming_words || [ ]
end

def identical_rhyme?(rhyme, target_pron)
  # Catches true homophones (same full pronunciation): +write+/+right+, +plain+/+plane+,
  # +symbol+/+cymbal+, +flour+/+flower+, +puffin+/+puffin'+. These would pass a
  # rime-cohort lookup but almost never count as legitimate rhymes; they're
  # "homophone / spelling-variant traps".
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
    return true if pron.phonemes == target_pron.phonemes
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
def rhyming_tuple_redundant_with?(ear, tup)
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
def condense_tuple_derived_forms(tup)
  return tup if tup.size < 2
  rsyll_set_of = {}
  tup.each do |w|
    rsyll_set_of[w] = pronunciations(w).map { |p| p.rhyme_syllables_string }.to_set
  end
  dropped = Set.new
  tup.each do |derived|
    tup.each do |base|
      next if base == derived
      next if dropped.include?(base)
      next if (rsyll_set_of[derived] & rsyll_set_of[base]).empty?
      COMMON_PREFIXES.each do |prefix|
        if derived.start_with?(prefix) && derived[prefix.length..] == base
          dropped << derived
          break
        end
      end
      break if dropped.include?(derived)
    end
  end
  return tup if dropped.empty?
  tup - dropped.to_a
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

# DynamoDB warm-up: batch-fetch every headword appearing in +relateds_lists+, then
# every rime their pronunciations reach, then every word in those rime cohorts.
# No-op when not running against Dynamo (local-dev / CMUDict path hits in-process
# hashes). Consolidates the prefetch preamble previously duplicated across the
# +_dynamo+ variants of +find_rhyming_tuples+ / +find_rhyming_pairs+.
def prefetch_dynamo_for_relateds!(*relateds_lists)
  return unless Rhymecrime::DataSource.dynamodb?
  all_relateds = relateds_lists.flat_map(&:to_a).uniq
  Rhymecrime::DynamoRuntime.batch_get_words(all_relateds)
  rimes = all_relateds.flat_map { |rel| pronunciations(rel).map(&:rime) }.uniq
  Rhymecrime::DynamoRuntime.batch_get_rimes(rimes)
  rhyme_words = rimes.flat_map { |r| rdict_lookup(r) }.uniq
  Rhymecrime::DynamoRuntime.batch_get_words(rhyme_words)
end

# True when the pair +[a, b]+ would collapse to a single member under Phase 0.5
# tuple condensation — i.e. it is a morphological +COMMON_PREFIXES+ derivation
# over matching +rhyme_syllables_string+ (+condense_tuple_derived_forms+), or a
# true same-phoneme homophone pair (+condense_tuple_homophones+). Examples:
# +[healthy, unhealthy]+ (prefix); +[flour, flower]+, +[coral, choral]+,
# +[symbol, cymbal]+ (homophones). The homophone condenser needs a +focal_word+
# to pick a winner, but for the drop-or-keep decision here we only care whether
# the cluster collapses, so any non-nil focal (we pass +a+) produces the same
# +size+ result.
def rhyming_pair_trivial?(a, b)
  return false if a == b
  condense_tuple_derived_forms([a, b]).size < 2 ||
    condense_tuple_homophones([a, b], a).size < 2
end

# Pair-mode analog of Phase 0.5 in +prune_suffix_redundant_rhyming_tuples+.
# Drops pairs whose two members +rhyming_pair_trivial?+ flags as prefix
# derivations or same-pronunciation homophones — the "rhyme" carries no
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

def prune_suffix_redundant_rhyming_tuples(tuples, focal_word = nil)
  verbose_prunes = ENV["VERBOSE"] == "1"
  debug_pruning = $debug_pruning
  # Snapshot the input so the caller's array is never mutated; the original
  # is not otherwise needed because the pruned set is populated in-place.
  _original = tuples.dup if debug_pruning

  # Phase -1: drop tuples composed entirely of stop words (e.g. +above / of+). A single
  # non-stop-word member is enough to keep the tuple alive (+above / dove / of+ survives).
  tuples = tuples.reject do |tup|
    next false unless tup.all? { |w| stop_word?(w) }
    if verbose_prunes
      puts "pruned rhyming tuple (all stop words): #{tup.join(' / ')}"
    end
    $debug_pruned_tuples << tup if debug_pruning
    !debug_pruning
  end

  # Phase 0: drop tuples whose members are all spelling variants of a single root (the tuple
  # carries no information beyond the canonical surface the renderer already emits).
  tuples = tuples.reject do |tup|
    next false unless rhyming_tuple_all_spelling_variants?(tup)
    if verbose_prunes
      puts "pruned rhyming tuple (all spelling variants of one root): #{tup.join(' / ')}"
    end
    $debug_pruned_tuples << tup if debug_pruning
    !debug_pruning
  end

  # Phase 0.5: within each tuple, condense redundant members.
  # (a) +condense_tuple_derived_forms+ drops derived forms whose base form is already
  #     present — same +rhyme_syllables_string+ plus a +COMMON_PREFIXES+ strip:
  #     +[healthy, stealthy, unhealthy] \to [healthy, stealthy]+;
  #     +[recorded, prerecorded, unrecorded, ...] \to [recorded, ...]+.
  # (b) +condense_tuple_homophones+ then breaks residual same-full-pronunciation
  #     clusters (+coral+/+choral+, +flour+/+flower+, +write+/+right+) that aren't
  #     prefix derivations of each other, keeping the member most closely related to
  #     +focal_word+ (tie-break: unigram frequency, then alphabetical). Requires a
  #     non-nil +focal_word+; otherwise this sub-pass is a no-op.
  tuples = tuples.map do |tup|
    condensed = condense_tuple_derived_forms(tup)
    condensed = condense_tuple_homophones(condensed, focal_word)
    if verbose_prunes && condensed.size < tup.size
      dropped = tup - condensed
      puts "condensed rhyming tuple (dropped #{dropped.inspect}): #{tup.join(' / ')} -> #{condensed.join(' / ')}"
    end
    if debug_pruning
      (tup - condensed).each { |w| $debug_pruned_tuples << [w] } # record each dropped member as a singleton
      tup # keep original under debug
    else
      condensed
    end
  end

  # Phase 0.6: drop tuples whose condensation collapsed them below 2 members.
  # A "rhyming tuple" with one (or zero) word is no longer a rhyme — the input
  # was a pure prefix-derivation pair like +[legitimate, illegitimate]+ or a
  # homophone cluster like +[coral, choral]+, and condense_tuple_* picked the
  # one keeper. Without this drop the singleton would survive the pruner and
  # render as a single-word "tuple". Callers (find_rhyming_tuples) already
  # filter +size < 2+ on the way out, but the unit pruner itself owes the same
  # contract so spec assertions on +prune_suffix_redundant_rhyming_tuples+
  # output match what the UI ultimately renders.
  tuples = tuples.reject do |tup|
    next false if tup.size >= 2
    if verbose_prunes
      puts "pruned rhyming tuple (collapsed below 2 members during condensation): #{tup.join(' / ')}"
    end
    $debug_pruned_tuples << tup if debug_pruning
    !debug_pruning
  end

  sorted = tuples.sort
  kept = []
  sorted.each do |tup|
    keeper = kept.find { |ear| rhyming_tuple_redundant_with?(ear, tup) }
    if keeper
      if verbose_prunes
        puts "pruned rhyming tuple (suffix-redundant): #{tup.join(' / ')}  [kept: #{keeper.join(' / ')}]"
      end
      if debug_pruning
        $debug_pruned_tuples << tup
        kept << tup
      end
      next
    end

    kept.reject! do |ear|
      redundant = rhyming_tuple_redundant_with?(tup, ear)
      next false unless redundant

      if verbose_prunes
        puts "pruned rhyming tuple (suffix-redundant): #{ear.join(' / ')}  [kept: #{tup.join(' / ')}]"
      end
      if debug_pruning
        $debug_pruned_tuples << ear
        # Retain ear (marked pruned) instead of rejecting it.
        next false
      end
      true
    end

    kept << tup
  end
  kept
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
  # Skip the cache when +$debug_pruning+ is true: the pruner side-effects
  # +$debug_pruned_tuples+ (a per-request Set consulted by +print_tuple+ for the
  # grey pruning color), and returning cached results would bypass that population,
  # leaving retained-pruned tuples un-colored. Debug requests are rare so recomputing
  # is fine. We also avoid populating the cache from debug-mode results, since those
  # include tuples that non-debug callers expect to have been dropped.
  return really_find_rhyming_tuples(input_rel1, common_only) if $debug_pruning

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
  return [] if explicitly_forbidden?(input_rel1)

  related_list = filter_related_words_to_common_preferred(
    find_related_words(input_rel1, true, false, nil, common_only: true)
  )
  relateds1 = related_list.to_set
  prefetch_dynamo_for_relateds!(related_list)

  related_rhymes = Hash.new { |h, k| h[k] = [] }
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

  tuples = []
  related_rhymes.each do |_rime, relrhymes|
    relrhymes.sort!.uniq!
    tuples.push(relrhymes.sort) if relrhymes.length > 1 && !all_identical_rhymes?(relrhymes)
  end
  # Alternate pronunciations can yield different +rime+ keys (e.g. OW_L_IY_AH_N vs OW_L_Y_AH_N) with the
  # same sorted word set — dedupe before suffix pruning so output is not repeated line-for-line.
  tuples.uniq!
  prune_suffix_redundant_rhyming_tuples(tuples, input_rel1).reject { |tup| tup.nil? || tup.size < 2 }
end

$rhyming_pair_cache = {}
def find_rhyming_pairs(input_rel1, input_rel2, common_only = false)
  # Mirrors +find_rhyming_tuples+'s caching policy: bypass the cache whenever
  # +$debug_pruning+ is true so pruning side-effects still populate.
  return really_find_rhyming_pairs(input_rel1, input_rel2, common_only) if $debug_pruning

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

  # Stop words are thematically related to everything by policy, which would otherwise flood
  # the pair output with pairs like [a, duh] / [a, the]. A 2-element pair has no room for a
  # go-word anchor when either side is a stop word, so we drop those before the rhyme cross.
  relateds1 = filter_related_words_to_common_preferred(
    find_related_words(input_rel1, true, false, nil, common_only: true)
  ).reject { |w| stop_word?(w) }
  relateds2 = filter_related_words_to_common_preferred(
    find_related_words(input_rel2, true, false, nil, common_only: true)
  ).reject { |w| stop_word?(w) }.to_set
  prefetch_dynamo_for_relateds!(relateds1, relateds2)

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
  if(got_rhymes)
    # @todo urlencode
    cgi_print "<a href='/?word1=#{word}'>"
  end
  # Color the word by its precomputed relatedness_score to +focal_word+ when one
  # is supplied (e.g. +set_related+ tuples, where every slot should be related
  # to +word1+). Skipped when +focal_word+ is falsy (word lists that have no
  # single focal, or +pair_related+ tuples whose two slots use different focals).
  similarity_span = focal_word && focal_word != "" && word != focal_word
  if similarity_span
    cgi_print "<span style='color: #{word_similarity_color(word, focal_word)}'>"
  end
  display_word = word.gsub('_', ' ')
  emit_text display_word
  cgi_print "</span>" if similarity_span
  if(got_rhymes)
    cgi_print "</a>"
  end
  if($display_word_similarities)
    print_html_percent_similarity(display_word, focal_word)
  end
  # Inline thumbs-up / thumbs-down for relatedness feedback. Suppressed when
  # +cue+ is nil (no relatedness column, e.g. plain rhymes), or when the
  # rendered word is the cue itself (relatedness to self is uninteresting).
  # The data attributes carry the *underscore* surface so what we POST to
  # +/feedback+ matches the shape of +spec/related.csv+'s +cue+/+related+
  # columns; +feedback.js+ wires the click → fetch and uses +sessionStorage+
  # to persist the user's vote across navigations within the tab.
  emit_relatedness_feedback_widget(word, cue) if cue && !cue.to_s.empty? && cue != word
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
    result_header = "Rhyming word sets related to " + focal_word(word1) + header_eol
    result, dregs = filter_out_rare_tuples(find_rhyming_tuples(word1))
    result_type = :tuples
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

