# encoding: utf-8
# Loads Wiktionary data from kaikki.org/wiktextract filtered English JSONL.
# Provides POS-aware pronunciation loading and inflected form maps.

require 'json'
require 'zlib'
require 'set'
require_relative 'ipa_to_arpabet'
require_relative 'pronunciation'

# Kaikki extract (large; often gitignored) under corpora/wiktionary/.
WIKTIONARY_DATA_PATH = File.expand_path("../../../corpora/wiktionary/kaikki-english-filtered.jsonl.gz", __dir__)

SKIP_FORM_TAGS = Set.new(%w[
  alternative obsolete dialectal nonstandard archaic
  rare misspelling Eye-dialect Latinization
])

INFLECTION_TAGS = {
  "noun" => [["plural"]],
  "verb" => [
    ["past"],
    ["participle", "past"],
    ["participle", "present"],
    ["present", "singular", "third-person"],
  ],
  "adj" => [["comparative"], ["superlative"]],
}

# Empty Kaikki verb morphology (see +load_wiktionary+ fourth return value).
def empty_kaikki_verb_morphology
  {
    past_surfaces: Set.new,
    lemmas_with_present_participle: Set.new,
    verb_paradigm_forms: Hash.new { |h, k| h[k] = Set.new },
    # Surfaces that appear as a non-lemma form in some verb paradigm whose lemma has an explicit
    # present participle in Kaikki — Inflect *-ing* from that surface is redundant (*snuck*→*snucking*).
    non_lemma_surfaces_in_pp_paradigm: Set.new
  }
end

# Load kaikki.org filtered JSONL.
# Returns [pron_hash, forms_map, pos_map, kaikki_verb_morph, kaikki_capitalized_only,
#          kaikki_variant_map, kaikki_obsolete_alt_of_only]
#   pron_hash: { word => [Pronunciation, ...] }  (same format as load_cmudict)
#   forms_map: { base_word => [[inflected_form, base_word], ...] }
#   pos_map: { word => Set<String> } union of Kaikki "pos" per lemma (Layer A ∩ WordNet in dict.rb)
#   kaikki_verb_morph: Hash with :past_surfaces (Set), :lemmas_with_present_participle (Set),
#     :verb_paradigm_forms (lemma => Set of attested inflected surfaces), and
#     :non_lemma_surfaces_in_pp_paradigm (Set) for morph gating.
#   kaikki_capitalized_only: Set<String> of lowercased headwords that never appeared with a
#     lowercase headword in Kaikki (proper-noun signal for the Wiktionary floor / compute_frequency).
#   kaikki_variant_map: { variant_headword => Set<{ target:, source:, tags: }> }
#     One entry per sense that carries an +alt_of+ pointer, or whose gloss/tags identify the
#     headword as a spelling variant, misspelling, or obsolete/archaic/dialectal form of another
#     headword. Consumed by +corpus_variants.rb+ to emit +generated/spelling_variants_auto.txt+.
#   kaikki_obsolete_alt_of_only: { headword => target_headword } for Kaikki records whose every
#     JSONL row was purely +alt-of obsolete/archaic/dated → target+. Paradigm contributions
#     (forms_map, pron_hash, pos_map, verb_morph) are already suppressed in this loader; dict.rb
#     additionally prunes the headword from +word_dict+ when the target survives the build.
def load_wiktionary
  path = WIKTIONARY_DATA_PATH
  unless File.exist?(path)
    puts "Wiktionary data not found at #{path}; skipping."
    m = empty_kaikki_verb_morphology
    return [{}, {}, {}, m, Set.new, {}, {}]
  end

  pron_hash = Hash.new { |h, k| h[k] = [] }
  forms_map = Hash.new { |h, k| h[k] = [] }
  pos_map = {}
  verb_morph = empty_kaikki_verb_morphology
  kaikki_has_capitalized = Set.new
  kaikki_has_lowercase = Set.new
  variant_map = Hash.new { |h, k| h[k] = [] }
  # Kaikki splits multi-POS words across rows (e.g. +asse+ has an "Obsolete spelling of ass"
  # noun row AND a "Cape fox" rare-noun row). A word is classified obsolete-only iff _every_
  # row for it was obsolete-only. We maintain that as: +obsolete_only_candidate[word] = target+
  # on the first obsolete-only row, and retract + +obsolete_only_blocked.add(word)+ the moment
  # any non-obsolete row shows up (or two obsolete rows disagree on target).
  obsolete_only_candidate = {}
  obsolete_only_blocked = Set.new
  total = 0; converted = 0; skipped = 0

  Zlib::GzipReader.open(path, encoding: 'UTF-8') do |gz|
    gz.each_line do |line|
      obj = JSON.parse(line) rescue next

      word_raw = obj["word"].to_s.strip
      word = word_raw.downcase
      next if word.empty? || word.match?(/\d/) || word.start_with?("'") || word.include?(" ")

      # Record case of the headword before any pos-based skipping: "name"-tagged and capitalized
      # "noun" entries (Modena, Batavia, Cabot, Srebrenica) are the proper-noun signal we want.
      if word_raw == word
        kaikki_has_lowercase.add(word)
      else
        kaikki_has_capitalized.add(word)
      end

      pos = obj["pos"].to_s
      next if pos == "name"

      # Detect "Kaikki ghost" rows: Early Modern English spellings (+appeare+, +blesse+,
      # +ladie+, …) whose only sense is +alt-of obsolete/archaic/dated+ → modern canonical.
      # Their paradigms (+appeared+, +appearing+, +appeares+) are mirrors of the modern
      # lemma's paradigm, so letting them seed +forms_map+ / +pron_hash+ / +verb_morph+
      # causes +$inflection_base_words+ last-write-wins to mis-route +appeared → appeare+
      # in +compute_lemma_map+ Source A. Suppress the paradigm contribution here and let
      # +prune_obsolete_alt_of_only_headwords!+ in dict.rb drop the ghost from word_dict.
      # +collect_variant_senses+ still runs below so the evidence is available to
      # +corpus_variants.rb+ (harmless; its +headwords_share_full_pron?+ gate already filters).
      obsolete_target = kaikki_record_obsolete_alt_of_only_target(obj, word)
      if obsolete_target && !obsolete_only_blocked.include?(word)
        existing = obsolete_only_candidate[word]
        if existing && existing != obsolete_target
          obsolete_only_candidate.delete(word)
          obsolete_only_blocked.add(word)
        else
          obsolete_only_candidate[word] = obsolete_target
        end
        collect_variant_senses(obj, word, variant_map)
        next
      end

      # Non-obsolete-only row: this row carries a real definitional meaning (or an
      # active alt-of / misspelling / regional variant). Retract any prior obsolete
      # candidacy for +word+ and block future obsolete rows from re-establishing one
      # so we don't prune a headword that has a live sense. Blocking unconditionally
      # (not only when a candidate already exists) covers the case where the live
      # rows for +word+ arrive before the obsolete row — e.g. *I*'s personal-pronoun
      # +pos: "pron"+ + ego +pos: "noun"+ + letter +pos: "character"+ rows precede the
      # +pos: "intj"+ row whose only sense is "Obsolete spelling of aye." Without the
      # unconditional block, the late obsolete row would set a fresh candidate that
      # +prune_obsolete_alt_of_only_headwords!+ then deletes from word_dict.
      obsolete_only_candidate.delete(word) if obsolete_only_candidate.key?(word)
      obsolete_only_blocked.add(word)

      (pos_map[word] ||= Set.new).add(pos) unless pos.empty?

      # Variant senses are worth recording even for entries with no pronunciation
      # (many of the "Alternative spelling of X" stubs have no IPA of their own),
      # so we process them before the sounds gate.
      collect_variant_senses(obj, word, variant_map)

      sounds = obj["sounds"]
      if sounds && !sounds.empty?
        total += 1

        ipa_strings = pick_ga_sounds(sounds)
        unless ipa_strings.empty?
          added = false
          ipa_strings.each do |ipa|
            arpabet = IpaToArpabet.convert(ipa)
            next if arpabet.nil? || arpabet.empty?

            pron = Pronunciation.new(arpabet)
            next if pron.empty?

            unless pron_hash[word].any? { |existing| existing.phonemes == pron.phonemes }
              pron_hash[word] << pron
              added = true
            end
          end

          if added
            converted += 1
          else
            skipped += 1
          end
        end
      end

      collect_inflected_forms(obj, word, pos, forms_map, verb_morph)
    end
  end

  verb_morph[:lemmas_with_present_participle].each do |lemma|
    verb_morph[:verb_paradigm_forms][lemma].each do |form|
      verb_morph[:non_lemma_surfaces_in_pp_paradigm].add(form) if form != lemma
    end
  end

  puts "Wiktionary: #{total} entries with pronunciation, #{converted} converted, #{skipped} skipped"
  puts "Wiktionary: #{pron_hash.size} unique words, #{forms_map.size} words with inflected forms"
  kaikki_capitalized_only = kaikki_has_capitalized - kaikki_has_lowercase
  puts "Wiktionary: #{kaikki_capitalized_only.size} headwords only ever capitalized (proper-noun signal)"
  puts "Wiktionary: #{variant_map.size} headwords with alt-spelling / variant pointers"
  puts "Wiktionary: #{obsolete_only_candidate.size} obsolete-only alt-of headwords (suppressed paradigm, queued for word_dict prune)"
  [pron_hash, forms_map, pos_map, verb_morph, kaikki_capitalized_only, variant_map, obsolete_only_candidate]
end

# Sense-tag whitelist / blacklist for classifying +alt_of+ pointers as genuine spelling
# variants. Calibrated against Kaikki English dump tag-combo frequencies:
#
#   Accept when the sense carries any of +VARIANT_ACCEPT_TAGS+ (alternative, archaic,
#   obsolete, dated, rare, nonstandard, misspelling, eye-dialect, or a regional dialect
#   tag like UK / US / British / Commonwealth / Australian / Irish / etc.).
#
#   Reject outright if the sense carries any of +VARIANT_REJECT_TAGS+ because those senses
#   point at a semantically different word: abbreviations (+cat+ ≠ +catapult+), clippings,
#   initialisms, contractions, morpheme-templates (+hex- → hexa-+), misconstructions
#   (+tenant → tenet+, a malapropism, not a spelling variant), and pronunciation-spellings
#   (+gonna → going to+, eye dialect rendering, not a canonical alternate).
VARIANT_ACCEPT_TAGS = Set.new(%w[
  alternative alt-form altform alt-spelling
  archaic obsolete dated rare nonstandard informal misspelling
  UK US British American Commonwealth Australian Canadian Irish Scottish
  New-Zealand South-African GenAm GA RP
  eye-dialect dialectal dialect regional
])
VARIANT_REJECT_TAGS = Set.new(%w[
  abbreviation acronym initialism clipping contraction ellipsis symbol
  morpheme misconstruction pronunciation-spelling
  Internet transliteration romanization
])

# Region words that Wiktionary editors use as prose prefixes in variant glosses. Used both
# to recognize gloss patterns like "Commonwealth standard spelling of X" and to extract
# an implicit regional tag from such glosses (the sense itself often has +tags: []+).
VARIANT_GLOSS_REGION_WORDS = [
  "British", "American", "UK", "US", "Commonwealth",
  "Australia", "Australian", "Canada", "Canadian", "Ireland", "Irish",
  "Scotland", "Scottish",
  "New Zealand", "New-Zealand",
  "South Africa", "South-Africa", "South African", "South-African",
  "Welsh", "Indian", "Pakistani", "European", "Hiberno", "Hiberno-English"
].freeze

VARIANT_GLOSS_REGION_RE = Regexp.union(VARIANT_GLOSS_REGION_WORDS).freeze

# Canonical region-tag form (spaces collapsed to hyphens) for each recognized region word.
# Used to gate +Synonym of X+ glosses: we only trust the synonym phrasing when the sense
# is explicitly marked regional. Kept in sync with +extract_region_tags_from_gloss+.
VARIANT_GLOSS_REGION_TAG_SET = Set.new(VARIANT_GLOSS_REGION_WORDS.map { |w| w.gsub(/\s/, "-") }).freeze
# Region list: "Commonwealth", "Australia, British, Canada", "Commonwealth and Ireland", etc.
VARIANT_GLOSS_REGION_LIST_RE = /
  (?:#{VARIANT_GLOSS_REGION_RE})
  (?:\s*,\s*(?:#{VARIANT_GLOSS_REGION_RE}))*
  (?:\s*,?\s*and\s+(?:#{VARIANT_GLOSS_REGION_RE}))?
/ix.freeze

VARIANT_GLOSS_QUALIFIER_RE = /
  Alternative|Alternate|Alt\.|Archaic|Obsolete|Dated|Dialectal|Dialect|
  Nonstandard|Non-standard|Standard|Common|Rare|Eye-dialect|Eye\ dialect
/ix.freeze

VARIANT_GLOSS_TARGET_RE = /["'\u2018\u201C]?([a-zA-Z][a-zA-Z\-']{0,40})["'\u2019\u201D]?(?:[.,;:\s\(]|\z)/.freeze

# Gloss patterns used when a Kaikki sense has no structured +alt_of+ pointer but does say
# "Alternative spelling of X" in prose. Patterns are anchored at gloss start and must name a
# spelling-variant qualifier and/or a regional prefix so we don't hallucinate pairings from
# substrings of unrelated glosses. Ordered most-to-least specific so the earliest match wins.
VARIANT_GLOSS_PATTERNS = [
  # "Misspelling of X", "Common misspelling of X". Keep separate so we can record
  # source=:misspelling (target is always canonical; frequency doesn't override).
  [:misspelling, /
    \A\s*
    (?:Common\s+|Rare\s+)?Misspelling
    \s+of\s+
    #{VARIANT_GLOSS_TARGET_RE}
  /ix],
  # "<Region list> <qualifier> spelling of X", e.g.
  #   "Commonwealth standard spelling of gray."
  #   "Australia, British, Canada, Ireland, New Zealand, and South Africa standard spelling of center."
  [:alt_of_gloss, /
    \A\s*
    (#{VARIANT_GLOSS_REGION_LIST_RE})
    \s+(?:#{VARIANT_GLOSS_QUALIFIER_RE}\s+)?
    (?:form|spelling|capitalisation|capitalization|variant)\s+of\s+
    #{VARIANT_GLOSS_TARGET_RE}
  /ix],
  # "<Qualifier> [<region>] spelling of X", e.g. "Alternative spelling of center",
  # "Archaic form of X", "Obsolete spelling of X".
  [:alt_of_gloss, /
    \A\s*
    (?:#{VARIANT_GLOSS_QUALIFIER_RE})
    \s+(?:(#{VARIANT_GLOSS_REGION_LIST_RE})\s+)?
    (?:form|spelling|capitalisation|capitalization|variant)\s+of\s+
    #{VARIANT_GLOSS_TARGET_RE}
  /ix],
  # "<Region list> spelling of X" with no qualifier, e.g. "Commonwealth spelling of mold".
  [:alt_of_gloss, /
    \A\s*
    (#{VARIANT_GLOSS_REGION_LIST_RE})
    \s+(?:form|spelling|capitalisation|capitalization|variant)\s+of\s+
    #{VARIANT_GLOSS_TARGET_RE}
  /ix],
  # "Synonym of X" - too promiscuous on its own (would pair car/vehicle, etc.), so we only
  # fire this if the sense's own tags mark it regional; that gate lives in the caller.
  [:synonym_of, /
    \A\s*Synonym\s+of\s+
    #{VARIANT_GLOSS_TARGET_RE}
  /ix],
]

def collect_variant_senses(obj, word, variant_map)
  senses = obj["senses"]
  return if senses.nil? || senses.empty?
  seen = Set.new  # dedupe (target, source) pairs per headword
  senses.each do |s|
    next unless s.is_a?(Hash)
    tags = s["tags"] || []
    next if tags.any? { |t| VARIANT_REJECT_TAGS.include?(t) }

    alt_of = s["alt_of"] || []
    form_of = s["form_of"] || []
    gloss = (s["glosses"] || []).first.to_s

    # Kaikki distinguishes _spelling variance_ from _morphological inflection_ via the
    # +alt-of+ vs +form-of+ sense tags. A sense tagged +form-of+ without +alt-of+ means
    # "this is an inflected form" (+baddest → bad+, +backpedalled → backpedal+) -- not a
    # spelling variant, even when the sense carries +rare+/+archaic+/+UK+/etc. Gating on
    # +alt-of+/+misspelling+ excludes inflections cleanly; the regional/rarity tags are
    # still recorded in +VARIANT_ACCEPT_TAGS+ so we can use them as secondary evidence
    # in +resolve_wiktionary_variant_winner+ later.
    is_alt_sense = tags.include?("alt-of")
    is_misspelling = tags.include?("misspelling")
    has_spelling_variant_tag = is_alt_sense || is_misspelling

    source_hint = is_misspelling ? :misspelling : :alt_of

    if has_spelling_variant_tag
      # Kaikki occasionally mis-parses a templated alt-of into a list that mixes a word
      # with a prose sense-narrowing qualifier:
      #   +wicked | alt_of=[{word: "wick"}, {word: "as applying to inanimate objects only"}]+
      # The phrase entry is a strong tell that the list is narrowing a single niche sense,
      # not declaring a canonical spelling pointer; drop the whole alt_of list in that case.
      alt_of_words = alt_of.map { |x| x.is_a?(Hash) ? x["word"].to_s : x.to_s }
      if alt_of_words.none? { |w| w.include?(" ") || w.empty? }
        alt_of_words.each do |target|
          add_variant_evidence(variant_map, word, target, source_hint, tags, seen)
        end
      end
      # We only follow +form_of+ pointers when the sense also carries +alt-of+ (i.e.,
      # Kaikki marked it as _both_ an inflection and a spelling variant; rare but real).
      if is_alt_sense
        form_of_words = form_of.map { |x| x.is_a?(Hash) ? x["word"].to_s : x.to_s }
        if form_of_words.none? { |w| w.include?(" ") || w.empty? }
          form_of_words.each do |target|
            add_variant_evidence(variant_map, word, target, source_hint, tags, seen)
          end
        end
      end
    end

    # Gloss-only fallback for entries that carry the textual signal but no structured
    # tags. Skip when the structured path already fired on this sense.
    next if has_spelling_variant_tag && (alt_of.any? || form_of.any?)
    next if gloss.empty?
    VARIANT_GLOSS_PATTERNS.each do |source, pattern|
      m = pattern.match(gloss)
      next unless m
      # When the pattern captured a regional prefix list ("Commonwealth", "Australia, British,
      # Canada, ..."), tokenize it into individual region tags and merge with the sense tags.
      # This lets gloss-derived pairs satisfy the regional-evidence gate in
      # +wiktionary_pair_is_useful?+ even when the sense itself had no tags.
      captures = m.captures
      region_prefix = captures[0..-2].compact.first
      target = captures.last
      synthetic_tags = tags | extract_region_tags_from_gloss(region_prefix)
      add_variant_evidence(variant_map, word, target, source, synthetic_tags, seen)
      break
    end
  end
end

# Split a Wiktionary-style regional prefix list ("Australia, British, Canada, Ireland, New
# Zealand, and South Africa") into individual canonical region tags that match
# +REGIONAL_VARIANT_TAGS+ in +corpus_variants.rb+. Returns [] for nil/empty input.
def extract_region_tags_from_gloss(text)
  return [] if text.nil? || text.empty?
  # Split on commas, "and", or conjunctive "&".
  parts = text.split(/\s*(?:,|&|\band\b)\s*/i).map(&:strip).reject(&:empty?)
  parts.map do |p|
    p.gsub(/[\s]/, "-")  # "New Zealand" → "New-Zealand", "South Africa" → "South-Africa"
  end
end

# Subset of +VARIANT_ACCEPT_TAGS+ that mark an +alt-of+ sense as a _historical_ pointer
# (Early Modern English spelling, obsolete typography) rather than a still-active regional
# or orthographic variant. Same list as +STRUCTURED_ALT_OF_DECAY_TAGS+ in corpus_variants.rb;
# kept as a local copy so +load_wiktionary+ can classify senses without a cross-file constant
# dependency. When every sense of a record is an obsolete/archaic/dated +alt-of+ pointer at a
# single modern target, the whole record is a Kaikki "ghost" we want to suppress from
# +forms_map+ / +pron_hash+ and prune from the final +word_dict+.
OBSOLETE_DECAY_TAGS = Set.new(%w[archaic obsolete dated])

# Gloss-prefix qualifiers that mark a sense as "Obsolete/Archaic/Dated (form|spelling) of X".
# Matches the decay arm of +VARIANT_GLOSS_QUALIFIER_RE+ in +collect_variant_senses+.
OBSOLETE_GLOSS_QUALIFIER_RE = /Archaic|Obsolete|Dated/i.freeze

# Whole-gloss pattern: "Obsolete spelling of appear.", "Archaic form of bless", etc.
# Narrower than +VARIANT_GLOSS_PATTERNS+ (doesn't allow Alternative/Dialectal/Nonstandard/etc.
# prefixes, because those are live variants that the +corpus_variants+ pipeline still wants
# to emit and we must not prune).
OBSOLETE_GLOSS_PATTERN = /
  \A\s*
  (?:#{OBSOLETE_GLOSS_QUALIFIER_RE})
  \s+(?:form|spelling|capitalisation|capitalization|variant)\s+of\s+
  #{VARIANT_GLOSS_TARGET_RE}
/ix.freeze

# Classify a single sense for the obsolete-only detector. Returns:
#   [:decay, target]  — sense is a historical +alt-of+ or "Obsolete/Archaic/Dated spelling of X"
#                       gloss pointing at +target+ (!= headword).
#   :skip             — sense is empty / pure-inflection +form-of+ / reject-tagged; doesn't
#                       disqualify the record but doesn't contribute a target either.
#   :other            — sense carries meaning that isn't obsolete-alt-of (definitional gloss,
#                       live +alt-of+ without decay tag, modern regional variant, misspelling).
#                       A single +:other+ sense disqualifies the whole record.
def classify_sense_for_obsolete_detector(sense, word)
  return :skip unless sense.is_a?(Hash)
  tags = sense["tags"] || []
  return :other if tags.any? { |t| VARIANT_REJECT_TAGS.include?(t) }

  alt_of = sense["alt_of"] || []
  form_of = sense["form_of"] || []
  gloss = (sense["glosses"] || []).first.to_s
  is_alt = tags.include?("alt-of")
  is_misspelling = tags.include?("misspelling")
  has_decay = tags.any? { |t| OBSOLETE_DECAY_TAGS.include?(t) }

  # Misspelling is a live canonicalization hint, not a historical one. Leave these to the
  # corpus_variants pipeline; don't let a +misspelling+ sense make the record "obsolete-only".
  return :other if is_misspelling

  if is_alt && has_decay
    targets = alt_of.map { |x| x.is_a?(Hash) ? x["word"].to_s.downcase.strip : x.to_s.downcase.strip }
    targets.reject! { |t| t.empty? || t.include?(" ") || t == word }
    return [:decay, targets.first] if targets.size == 1
    return :other
  end

  if is_alt && !has_decay
    return :other
  end

  # Pure inflection (+form-of+ without +alt-of+) — doesn't signal meaning either way.
  return :skip if tags.include?("form-of")

  if gloss.empty?
    return :skip if tags.empty? && alt_of.empty? && form_of.empty?
    return :other
  end

  if (m = OBSOLETE_GLOSS_PATTERN.match(gloss))
    target = m.captures.last.to_s.downcase.strip
    return [:decay, target] if !target.empty? && !target.include?(" ") && target != word
    return :other
  end

  :other
end

# Returns the single canonical target T when every sense of +obj+ is an obsolete/archaic/dated
# +alt-of+ pointer (or "Obsolete spelling of T" gloss) pointing at the same T, with T != word.
# Returns nil for records that carry any non-obsolete meaning (definitional gloss, live
# regional variant, misspelling, mixed targets). Caller is expected to additionally verify
# T is in +cmudict+ / +word_dict+ before acting on the result — we don't want to suppress a
# headword whose only canonical target isn't even in the lexicon.
def kaikki_record_obsolete_alt_of_only_target(obj, word)
  senses = obj["senses"]
  return nil if senses.nil? || senses.empty?
  target = nil
  saw_decay = false
  senses.each do |s|
    result = classify_sense_for_obsolete_detector(s, word)
    case result
    when :skip
      next
    when :other
      return nil
    when Array # [:decay, t]
      t = result[1]
      return nil if t.nil? || t.empty?
      if target.nil?
        target = t
        saw_decay = true
      elsif target != t
        return nil
      end
    end
  end
  saw_decay ? target : nil
end

def add_variant_evidence(variant_map, word, target, source, tags, seen)
  target = target.to_s.downcase.strip
  return if target.empty? || target == word || target.include?(" ") || target.match?(/\d/)
  # Apostrophes turn up on contractions (+y'know+), deliberately-punctuated
  # lexicographic renderings (+i's+), and clitic pseudo-lemmas. None of these belong in
  # a preferred-spelling mapping the web UI will normalize against.
  return if word.include?("'") || target.include?("'")
  # Single-letter "words" are almost always Kaikki abbreviation noise that slipped past
  # the tag blacklist (+a ay+, +c see+, +f fuck+); reject by length so we don't pollute
  # the variants file with them.
  return if word.length < 2 || target.length < 2
  return if word.include?("-") && (word.start_with?("-") || word.end_with?("-"))
  return if target.include?("-") && (target.start_with?("-") || target.end_with?("-"))
  key = [target, source]
  return if seen.include?(key)
  seen.add(key)
  variant_map[word] << { target: target, source: source, tags: tags }
end

def pick_ga_sounds(sounds)
  ga = []
  unspecified = []
  other = []

  sounds.each do |s|
    ipa = s["ipa"]
    next if ipa.nil? || ipa.empty?
    tags = s["tags"] || []

    if tags.any? { |t| t.include?("General-American") || t.include?("US") || t.include?("GenAm") }
      ga << ipa
    elsif tags.empty?
      unspecified << ipa
    else
      other << ipa
    end
  end

  result = ga.empty? ? (unspecified.empty? ? other : unspecified) : ga
  result.uniq
end

def collect_inflected_forms(obj, base_word, pos, forms_map, verb_morph = nil)
  forms = obj["forms"]
  return if forms.nil? || forms.empty?

  valid_tag_sets = INFLECTION_TAGS[pos]
  return if valid_tag_sets.nil?

  forms.each do |f|
    form = f["form"].to_s.downcase.strip
    next if form.empty? || form.include?(" ") || form == base_word
    tags = f["tags"] || []

    next if tags.any? { |t| SKIP_FORM_TAGS.include?(t) }

    next unless valid_tag_sets.any? { |required| required.all? { |rt| tags.include?(rt) } }

    if verb_morph && pos == "verb"
      if tags.include?("past") || (tags.include?("participle") && tags.include?("past"))
        verb_morph[:past_surfaces].add(form)
      end
      verb_morph[:lemmas_with_present_participle].add(base_word) if tags.include?("participle") && tags.include?("present")
      verb_morph[:verb_paradigm_forms][base_word].add(form)
    end

    unless forms_map[base_word].any? { |existing_form, _| existing_form == form }
      forms_map[base_word] << [form, base_word]
    end
  end
end
