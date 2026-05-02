#!/usr/bin/env ruby
# encoding: utf-8
#
# RhymeCrime dictionary compiler entrypoint: CMU + Wiktionary/Kaikki + frequency phases → <repo>/generated/*.
# Prefer: ./bin/dict-build from the repo root (loads this file with cwd = this directory, then runs rebuild).
#
# Implementation is split under this directory by concern:
#
#   Dependency direction (load order):
#     constants     — paths, thresholds, export headers
#       → phonology — CMU + ARPAbet + syllabification + Wiktionary pronunciation merge
#       → lexical   — WordNet + POS layers (+ inflect Zipf probes for POS pruning)
#       → morphology — inflection policy + Kaikki-derived surface pronunciations
#       → rime      — rime index build / merge / rare-bucket prune / filter_cmudict
#       → frequency — SUBTLEX + wordfreq + compute_frequency + add_frequency_info + build_word_dict
#         (build_word_dict merges pronunciations into rdict, strips dispreferred spellings from cohorts,
#          prunes weak rime buckets, drops freq==0 orphans
#          per disconnect: wordfreq TSV row ⇒ keep; strict OOV ⇒ Kaikki/SUBTLEX rescue only, not rhyme-alone)
#          Rare headword omission for export runs in +rebuild_rhymecrime_dictionaries+ after hyphen-map keys snapshot.)
#     this file     — rebuild_rhymecrime_dictionaries only
#
# Corpus inputs live under <repo>/corpora/. Invoked by bin/dict-build.
# ConceptNet lemma cache under generated/ is created by setup.sh after downloading assertions, or
# automatically at the start of this rebuild if it is missing or older than assertions.gz.
#
# Fast-iteration default: bin/dict-build skips the slow ConceptNet edge-map and
# Numberbatch vector exports at the end (hyphen map and word_dict still run).
# Use bin/build (the full pipeline orchestrator) — or set
# RHYMECRIME_DICT_BUILD_CONCEPTNET_NUMBERBATCH=1 explicitly — when those exports
# need to be refreshed alongside the rhyming dict.

require "rwordnet"
require "json"
require "set"
require_relative "utils_rhyme"
require_relative "phoneme.rb"
require_relative "pronunciation.rb"
require_relative "wiktionary"
require_relative "varcon"
require_relative "inflect"

require_relative "constants"
require_relative "phonology"
require_relative "lexical"
require_relative "morphology"
require_relative "rime"
require_relative "frequency"
require_relative "corpus_variants"

$inflection_base_words = {}

# Per-headword frequency-propagation provenance, populated by the morph
# inheritance / expansion / g-drop branches in +frequency.rb+ and consumed by
# +rarity_rescore_and_dump!+ in +rarity_classifier.rb+ to fill the corresponding
# +RaritySignals+ fields. Cleared at the top of each +load_word_dict+ rebuild (no
# cross-build leakage).
#
# Shape: +{ surface => { phase: Symbol, donor: String, donor_anchored: Boolean } }+.
# +phase+ ∈ +RARITY_FREQ_SOURCE_PHASES+.
#
# +donor_anchored+ records whether the donor base carried independent CORPUS /
# LEXICAL evidence (WordNet entry, neol membership, or Zipf ≥
# +WORDFREQ_COMMON_ZIPF+). Membership in +common_words+ (i.e. +rarity.csv+'s
# +common+/+common_ish+ rows) is INTENTIONALLY NOT one of the anchor predicates
# here, even though it IS one in the inheritance-gate predicates of
# +morph_inherit_kaikki+ / +morph_expand_subtlex+ (where it controls whether
# inheritance happens at all). Reason: the rarity-classifier feature
# +received_donor_from_common_base_flag+ is read off this Boolean. If
# +common_words.include?(base)+ flowed into +donor_anchored+, every inflected
# form of every +common+ row in +rarity.csv+ would set the flag, and the
# trainer would relearn the curated label through the lemma — exactly the kind
# of leak that was hiding behind the 99.7% CV with +common_words_flag+ /
# +rare_words_flag+ as direct features. See +donor_has_corpus_anchor?+ below
# for the canonical predicate; gate sites combine it with
# +common_words.include?(base)+ for the broader "should we inherit at all"
# decision.
$freq_propagation_metadata = {}

def record_freq_propagation!(surface, phase:, donor:, donor_anchored:)
  return unless surface
  $freq_propagation_metadata[surface] = {
    phase: phase,
    donor: donor,
    donor_anchored: !!donor_anchored,
  }
end

# Canonical leak-free anchor predicate for +donor_anchored+ (and by extension
# the rarity-classifier feature +received_donor_from_common_base_flag+). Pure
# corpus / lexical evidence — deliberately excludes +common_words+ membership.
# See the long comment on +$freq_propagation_metadata+ above.
def donor_has_corpus_anchor?(base, wordfreq_hash, neol_words)
  return true if wn_has_entry?(base)
  return true if neol_words && neol_words.include?(base)
  zipf = (wordfreq_hash && wordfreq_hash[base]) || 0
  zipf >= WORDFREQ_COMMON_ZIPF
end

# Lazy path -> frozen Hash of 8-digit synset offset string -> full data-file line (+wn_synset_line_for_offset+).
$wn_synset_line_index_by_path = nil

def include_conceptnet_numberbatch_dict_exports?
  v = ENV["RHYMECRIME_DICT_BUILD_CONCEPTNET_NUMBERBATCH"]
  v && !v.empty? && %w[1 true yes on].include?(v.downcase)
end

# True when +word+ and +base+ share at least one WordNet synset (any POS).
def wn_share_synset?(word, base)
  word_offsets = Set.new
  [word, hyphens_to_underscores(word), word.tr("_", "-")].uniq.each do |f|
    wn_lemma_find_all_cached(f).each do |lem|
      lem.synsets.each { |s| word_offsets.add([s.pos, s.pos_offset]) }
    end
  end
  return false if word_offsets.empty?

  [base, hyphens_to_underscores(base), base.tr("_", "-")].uniq.each do |f|
    wn_lemma_find_all_cached(f).each do |lem|
      lem.synsets.each { |s| return true if word_offsets.include?([s.pos, s.pos_offset]) }
    end
  end
  false
end

# Same-lexeme check for dict lemmas: shared synset; cheap suffix-specific checks; then 1-hop derivation
# (file-based, 3.1-safe). Derivation is last and walks WN data for +word+ when earlier checks fail.
def wn_accept_inflection_lemma_pair?(word, base)
  wn_share_synset?(word, base) ||
    wn_verb_stem_via_morphy?(word, base) ||
    wn_noun_plural_via_morphy?(word, base) ||
    wn_productive_affix_lemma_pair?(word, base) ||
    wn_derivationally_related_to_base?(word, base)
end

# Sentinel-region cutoff for +independent_ing_adj_surface?+'s freq-differential
# gate. Real corpus frequencies in +word_dict+ top out below ~25 (log2 of the
# SUBTLEX corpus size); anything above this is a curated structural sentinel
# (+999999+ semantically promiscuous, +99+ +rarity.csv+ common, +98+ neol). The
# differential heuristic was designed to compare CORPUS frequencies — a
# surface sitting at the curated-common sentinel is not real evidence that the
# adjective use dominates over the verb base. Mirrors the same separator used
# by +RARITY_CLASSIFIER_RESCORE_MAX_FREQ+ in +rarity_classifier.rb+, kept as a
# local constant to avoid cross-file coupling between the lemma builder and
# the rarity rescore path.
LEMMA_HEURISTIC_MAX_REAL_SURFACE_FREQ = 90

# Suppress collapsing +-ing+ adjectives that have gained independent semantic
# weight onto their verbal base. WN often lists them as adj-only senses, but
# the morphology-aware fallback in +compute_lemma_map+ would still happily map
# +cloying → cloy+ and lose the adjective register at runtime. Heuristic:
#   * surface ends in +-ing+,
#   * surface has a WN entry,
#   * none of the surface's WN POSes is +"v"+ (so adjectival sense is dominant),
#   * surface freq is in the corpus-realistic range (not a curated sentinel —
#     see +LEMMA_HEURISTIC_MAX_REAL_SURFACE_FREQ+ for why),
#   * a candidate +-ing+ base exists in word_dict and passes the WN gate,
#   * surface is at least 5 freq buckets below the candidate base — i.e. the
#     adjective use is the dominant living surface (wide enough margin that
#     pure verb-form drift like +running+/+run+ doesn't qualify).
# Returns +true+ to short-circuit the lemma assignment (keeps surface as a
# self-lemma).
def independent_ing_adj_surface?(word, word_dict)
  return false unless word.end_with?("ing")
  return false unless wn_has_entry?(word)
  poses = wn_lemma_find_all_cached(word).map(&:pos).uniq
  return false if poses.empty? || poses.include?("v")
  surface_entry = word_dict[word]
  return false unless surface_entry
  surface_freq = surface_entry[0]
  # +making+ (WN POSes = ["n"], +rarity.csv+ +common+ → freq=99) used to
  # qualify here because +99 - make_freq+ trivially exceeded the +>=5+
  # differential, suppressing +making → make+ in the lemma map. The real
  # heuristic only makes sense when both sides are corpus-derived.
  return false if surface_freq > LEMMA_HEURISTIC_MAX_REAL_SURFACE_FREQ
  candidate_bases = Inflect.raw_candidate_bases_for_inflected(word).to_a
  ka_base = $inflection_base_words[word]
  candidate_bases << ka_base if ka_base && !candidate_bases.include?(ka_base)
  candidate_bases.any? do |b|
    next false if b == word
    next false unless word_dict.key?(b)
    next false unless Inflect.send(:match_suffix_kind, b, word) == :ing
    next false unless wn_accept_inflection_lemma_pair?(word, b)
    (surface_freq - word_dict[b][0]) >= 5
  end
end

# Funnel a chosen lemma target through +preferred_form+ so the on-disk lemma
# map stores the canonical American spelling even when the inflectional path
# produced a British / variant base. +fulfilled → fulfil → fulfill+ is the
# canonical case; without this hop the map would point users at the variant
# spelling that may not have downstream artifacts (NB vector, CN edges).
def canonicalize_lemma_target(base, word_dict)
  pref = preferred_form(base)
  return base unless pref && pref != base && word_dict.key?(pref)
  pref
end

# Build a hash mapping each word_dict headword to its base/lemma form.
# Source A: $inflection_base_words (Kaikki forms_map — populated earlier in rebuild).
# Source B: Inflect.each_candidate_base_for_inflected picks the best base already in word_dict.
# Words with a WordNet entry and an :er/:est suffix keep themselves (singer, faster are standalone).
# For Source B, if the word has a WordNet entry then the candidate base must pass
# +wn_accept_inflection_lemma_pair?+ (shared synset, 1-hop derivation pointers, guarded -ly/-ful,
# or unique verbal morphy for Inflect *-ed* / *-ing*). This blocks false stems like crew→crow when
# no link matches.
# Fallback: self-lemma (word is its own base).
# Derivational suffixes used by +compute_semantic_base_map+. Each entry is
# +{ suffix: <derived-side ending>, base_suffix: <base-side ending> }+; the
# rule fires when +source = stem + suffix+ and +candidate = stem + base_suffix+.
# Order matters: longer suffixes come first so +-ically+ wins over +-ly+.
#
# Curated to cover the recurring derivational families in +word_dict+. Every
# rule must also pass a WordNet derivation pointer (+wn_derivation_target_lemmas_for_word+)
# at runtime, so an over-broad allowlist won't synthesize spurious mappings —
# the WN gate is the safety net.
SEMANTIC_BASE_SUFFIX_RULES = [
  { suffix: "ically", base_suffix: "ic" },
  { suffix: "ication", base_suffix: "ic" },
  { suffix: "ication", base_suffix: "ify" },
  { suffix: "ication", base_suffix: "y" },
  { suffix: "ization", base_suffix: "" },
  { suffix: "ization", base_suffix: "ize" },
  { suffix: "isation", base_suffix: "" },
  { suffix: "isation", base_suffix: "ise" },
  { suffix: "ation", base_suffix: "" },
  { suffix: "ation", base_suffix: "e" },
  { suffix: "ation", base_suffix: "ate" },
  { suffix: "tion", base_suffix: "" },
  { suffix: "tion", base_suffix: "te" },
  { suffix: "tion", base_suffix: "t" },
  { suffix: "sion", base_suffix: "se" },
  { suffix: "sion", base_suffix: "d" },
  { suffix: "ility", base_suffix: "ile" },
  { suffix: "ility", base_suffix: "le" },
  { suffix: "bility", base_suffix: "ble" },
  { suffix: "ity", base_suffix: "" },
  { suffix: "ity", base_suffix: "e" },
  { suffix: "ical", base_suffix: "y" },
  { suffix: "ical", base_suffix: "" },
  { suffix: "atic", base_suffix: "a" },
  { suffix: "etic", base_suffix: "y" },
  { suffix: "etic", base_suffix: "" },
  { suffix: "ic", base_suffix: "" },
  { suffix: "ic", base_suffix: "y" },
  { suffix: "ic", base_suffix: "e" },
  { suffix: "ize", base_suffix: "" },
  { suffix: "ize", base_suffix: "e" },
  { suffix: "ize", base_suffix: "y" },
  { suffix: "ise", base_suffix: "" },
  { suffix: "ise", base_suffix: "e" },
  { suffix: "ise", base_suffix: "y" },
  { suffix: "ify", base_suffix: "" },
  { suffix: "ify", base_suffix: "y" },
  { suffix: "able", base_suffix: "" },
  { suffix: "able", base_suffix: "e" },
  { suffix: "ible", base_suffix: "" },
  { suffix: "ible", base_suffix: "e" },
  { suffix: "ness", base_suffix: "" },
  { suffix: "iness", base_suffix: "y" },
  { suffix: "ment", base_suffix: "" },
  { suffix: "ement", base_suffix: "e" },
  { suffix: "er", base_suffix: "" },
  { suffix: "er", base_suffix: "e" },
  { suffix: "or", base_suffix: "" },
  { suffix: "or", base_suffix: "e" },
  { suffix: "or", base_suffix: "ate" },
  { suffix: "eer", base_suffix: "" },
  { suffix: "eer", base_suffix: "y" },
  { suffix: "ery", base_suffix: "" },
  { suffix: "ery", base_suffix: "e" },
  { suffix: "ry", base_suffix: "" },
  { suffix: "al", base_suffix: "" },
  { suffix: "al", base_suffix: "e" },
  { suffix: "ial", base_suffix: "" },
  { suffix: "ial", base_suffix: "y" },
  { suffix: "orial", base_suffix: "or" },
  { suffix: "orial", base_suffix: "" },
  { suffix: "ous", base_suffix: "" },
  { suffix: "ous", base_suffix: "y" },
  { suffix: "ance", base_suffix: "ant" },
  { suffix: "ance", base_suffix: "" },
  { suffix: "ence", base_suffix: "ent" },
  { suffix: "ence", base_suffix: "" },
  { suffix: "y", base_suffix: "" },
  { suffix: "th", base_suffix: "" },
  { suffix: "ly", base_suffix: "" },
].freeze

# Floor on source-word length: below 6 chars the +-y+, +-ly+, +-al+, +-ic+
# rules start firing on coincidences (+ally+ -> +all+, +ily+ -> +i+).
SEMANTIC_BASE_MIN_SOURCE_LEN = 6
# Floor on candidate-base length: stops degenerate strips like +pity+ -> +p+.
SEMANTIC_BASE_MIN_BASE_LEN = 3
# Shared-prefix floor: discriminates the WN gate from accidental targets that
# happen to be in word_dict but share no surface morphology with the source.
SEMANTIC_BASE_MIN_SHARED_PREFIX = 3
# Frequency guard: derived may be at most this many freq buckets MORE common
# than the candidate base. Catches drift like +cloying+ (freq 10) vs +cloy+
# (freq 2). Asymmetric — base may be arbitrarily more common than derived.
SEMANTIC_BASE_MAX_FREQ_RISE = 4
# Minimum Numberbatch cosine between source and base for the derivation to be
# accepted. Catches semantic-shift cases that pass every surface filter but
# the words have drifted apart (presentation/present, waiter/wait). Only
# enforced when the caller passes +nb_vectors:+ to +compute_semantic_base_map+;
# if either side has no NB vector the guard is silently bypassed.
SEMANTIC_BASE_MIN_NB_COSINE = 0.50

def semantic_base_shared_prefix_len(a, b)
  n = [a.bytesize, b.bytesize].min
  i = 0
  i += 1 while i < n && a.getbyte(i) == b.getbyte(i)
  i
end

def semantic_base_classify_suffix(source, candidate)
  return nil if source == candidate
  return nil if source.length < SEMANTIC_BASE_MIN_SOURCE_LEN
  return nil if candidate.length < SEMANTIC_BASE_MIN_BASE_LEN

  SEMANTIC_BASE_SUFFIX_RULES.each do |rule|
    suf = rule[:suffix]
    bsuf = rule[:base_suffix]
    next unless source.end_with?(suf)
    base_part = source[0...source.length - suf.length]
    if bsuf.empty?
      next unless candidate == base_part
    else
      next unless candidate == base_part + bsuf
    end
    return bsuf.empty? ? "+#{suf}" : "-#{bsuf}/+#{suf}"
  end
  nil
end

def semantic_base_safe_derivation?(source, candidate, source_freq, candidate_freq)
  return false if candidate.length >= source.length
  return false if semantic_base_shared_prefix_len(source, candidate) < SEMANTIC_BASE_MIN_SHARED_PREFIX
  return false if (source_freq - candidate_freq) > SEMANTIC_BASE_MAX_FREQ_RISE

  semantic_base_classify_suffix(source, candidate)
end

# +nb_vectors+ when non-nil maps +hyphens_to_underscores(word) -> Array<Float>+
# (or +Numo::SFloat+; both produce a scalar dot). Returns +nil+ when either
# side is missing — caller treats +nil+ as "guard bypassed".
def semantic_base_nb_cosine(nb_vectors, a, b)
  return nil unless nb_vectors
  va = nb_vectors[hyphens_to_underscores(a)]
  vb = nb_vectors[hyphens_to_underscores(b)]
  return nil unless va && vb
  if va.respond_to?(:dot) && !va.is_a?(Array)
    va.dot(vb).to_f
  else
    sum = 0.0
    i = 0
    n = va.length
    while i < n
      sum += va[i] * vb[i]
      i += 1
    end
    sum
  end
end

def best_semantic_base_target(source, source_freq, word_dict, nb_vectors: nil)
  targets = wn_derivation_target_lemmas_for_word(source)
  return nil if targets.nil? || targets.empty?

  best = nil
  targets.each do |t|
    next unless word_dict.key?(t)
    next if t == source
    entry = word_dict[t]
    next unless entry

    candidate_freq = entry[0]
    transform = semantic_base_safe_derivation?(source, t, source_freq, candidate_freq)
    next unless transform

    cos = semantic_base_nb_cosine(nb_vectors, source, t)
    next if cos && cos < SEMANTIC_BASE_MIN_NB_COSINE

    rank = [-candidate_freq, t.length, t]
    if best.nil? || (rank <=> best[:rank]) < 0
      best = { target: t, transform: transform, rank: rank, cos: cos }
    end
  end
  best
end

# Build the +word -> derivational_base+ map used by +semantic_base+ in the
# relatedness pipeline (R3). Composes on top of +compute_lemma_map+: only
# self-lemma headwords (+lemma(w) == w+) get an entry, since inflected
# surfaces resolve through the lemma layer first at runtime. Walks WordNet
# +wn_derivation_target_lemmas_for_word+ pointers and applies the curated
# suffix allowlist + frequency / length / shared-prefix gates above.
#
# +nb_vectors:+ enables the cosine guard (see +SEMANTIC_BASE_MIN_NB_COSINE+).
# Pass the unpacked +numberbatch_vectors.msgpack+ — keys must already be
# +hyphens_to_underscores+'d, values may be +Array<Float>+ or +Numo::SFloat+.
#
# Returns +[map, transforms]+ where +map+ is +word -> base+ and +transforms+
# is +word -> "+suffix"+/etc. for the audit dump.
def compute_semantic_base_map(word_dict, lemma_map, nb_vectors: nil)
  map = {}
  transforms = {}
  rejected_by_cosine = 0
  begin
    word_dict.each_key do |w|
      next if lemma_map.key?(w) && lemma_map[w] != w

      source_freq = word_dict[w][0]
      best = best_semantic_base_target(w, source_freq, word_dict, nb_vectors: nb_vectors)
      unless best
        if nb_vectors
          fallback = best_semantic_base_target(w, source_freq, word_dict, nb_vectors: nil)
          rejected_by_cosine += 1 if fallback
        end
        next
      end

      map[w] = best[:target]
      transforms[w] = best[:transform]
    end
  ensure
    $wn_synset_line_index_by_path = nil
  end

  guard_note = nb_vectors ? " (NB cosine guard enforced; #{rejected_by_cosine} candidates rejected for cos < #{SEMANTIC_BASE_MIN_NB_COSINE})" : " (no NB cosine guard)"
  puts "Semantic-base map: #{map.size} word -> derivational_base entries#{guard_note}"
  [map, transforms]
end

def compute_lemma_map(word_dict)
  lemma_map = {}
  begin
    word_dict.each_key do |word|
      # +independent_ing_adj_surface?+ skips lemma assignment for adj-only +-ing+
      # surfaces that have drifted from their verbal root (cloying, harrowing, …)
      # — see helper docs above for the gate.
      if independent_ing_adj_surface?(word, word_dict)
        next
      end

      # Source A: Kaikki-derived base (Wiktionary explicitly lists the relationship).
      # When the word has a WN entry, require +wn_accept_inflection_lemma_pair?+ — Kaikki can link
      # archaic/dialectal inflections (crew→crow, feed→fee) that mislead the common-sense lemma.
      kaikki_base = $inflection_base_words[word]
      if kaikki_base && kaikki_base != word && word_dict.key?(kaikki_base)
        if !wn_has_entry?(word) || wn_accept_inflection_lemma_pair?(word, kaikki_base)
          chosen = canonicalize_lemma_target(kaikki_base, word_dict)
          lemma_map[word] = chosen if chosen != word
          next
        end
      end

      word_in_wn = wn_has_entry?(word)

      # Source B: Inflect candidate bases present in word_dict (skip when no morphological suffix shape).
      raw_bases = Inflect.raw_candidate_bases_for_inflected(word)
      next if raw_bases.empty?

      best_base = nil
      best_freq = -1
      raw_bases.each do |base|
        next unless word_dict.key?(base)
        next unless Inflect.inflection_of_base?(base, word)

        kind = Inflect.send(:match_suffix_kind, base, word)
        next if kind.nil?

        # -er/-est words with their own WordNet entry are standalone (singer, faster)
        if (kind == :er || kind == :est) && word_in_wn
          best_base = nil
          break
        end

        # If word is in WordNet, base must share a synset (crew≠crow, ring≠re, thing≠the).
        # If word is NOT in WordNet, base must at least be in WordNet (tran, sacre, etc. are not).
        if word_in_wn
          next unless wn_accept_inflection_lemma_pair?(word, base)
        else
          next unless wn_has_entry?(base)
        end

        base_freq = word_dict[base][0]
        if best_base.nil? || base_freq > best_freq || (base_freq == best_freq && base.length < best_base.length)
          best_base = base
          best_freq = base_freq
        end
      end

      if best_base && best_base != word
        chosen = canonicalize_lemma_target(best_base, word_dict)
        lemma_map[word] = chosen if chosen != word
      end
    end

    # Lemma-side g-drop pass — mirror of the freq-side +gdrop+ pass in
    # +frequency.rb+ that gives +failin'+ / +makin'+ / +poopin'+ their
    # +-ing+-base frequency. Without this, +lemma("makin'") = "makin'"+ and
    # +lemma("poopin'") = "poopin'"+ because Sources A/B don't recognize the
    # apostrophe variant: Kaikki has no +makin' → make+ entry, and Inflect's
    # suffix table doesn't know +-in'+ as an inflectional ending. The dialect
    # surface should resolve to the same lemma as its standard +-ing+ form
    # (+poopin' → poop+, not +poopin' → pooping+) so it inherits the verb's
    # rarity / relatedness behavior at runtime.
    gdrop_lemmas = 0
    word_dict.each_key do |word|
      next unless word.end_with?("in'") || word.end_with?("in\u2019")
      next if lemma_map.key?(word)
      ing_form = word.sub(/in['\u2019]\z/, "ing")
      next unless word_dict.key?(ing_form)
      ing_lemma = lemma_map[ing_form] || ing_form
      next if ing_lemma == word
      lemma_map[word] = ing_lemma
      gdrop_lemmas += 1
    end
    puts "#{gdrop_lemmas} -in' g-drop surfaces inherited lemma from -ing form" if gdrop_lemmas > 0
  ensure
    $wn_synset_line_index_by_path = nil
  end

  self_n = word_dict.size - lemma_map.size
  puts "Lemma map: #{lemma_map.size} inflected → base, #{self_n} self-lemmas"
  lemma_map
end

# Drop Kaikki "obsolete-only" ghost headwords (+appeare+, +blesse+, +ladie+, +maide+,
# +cherrie+, +saile+, +wolfe+, +eate+, +businesse+, …) from +word_dict+ and +rdict+ when
# their modern canonical target survives the build.
#
# These leak into +word_dict+ via +wordfreq.tsv+ Zipf rows (Project Gutenberg / KJV /
# Shakespeare-era corpora list them in running text) even though +load_wiktionary+ now
# suppresses their paradigm contribution. Without a post-build prune, +compute_lemma_map+
# Source B would still consider them as valid bases for shared inflected forms, and
# runtime +related?+ / UI paths would surface them as dict-headword suggestions.
#
# Safe ordering: must run after +build_word_dict+ (word_dict is frozen at that point) and
# before +compute_lemma_map+ (so Source A's +word_dict.key?(kaikki_base)+ gate correctly
# falls through to the modern canonical). Only drop when the +target+ is itself in word_dict;
# if the canonical didn't survive (e.g. a rare archaic pair whose modern form is also missing),
# leaving the obsolete headword gives runtime _something_ to resolve to.
def prune_obsolete_alt_of_only_headwords!(word_dict, rdict, obsolete_alt_of_only)
  return 0 if obsolete_alt_of_only.nil? || obsolete_alt_of_only.empty?
  dropped = 0
  dropped_pron_orphans = 0
  obsolete_alt_of_only.each do |ghost, target|
    next unless word_dict.key?(ghost)
    next unless word_dict.key?(target)

    dict_trace_puts(ghost, "prune_obsolete_alt_of: DELETE (target=#{target})") if dict_trace_word?(ghost)
    dropped_pron_orphans += 1 if word_dict[ghost][1].nil? || word_dict[ghost][1].empty?
    word_dict.delete(ghost)
    dropped += 1
  end

  if dropped > 0
    before_rdict_n = rdict.values.sum(&:size)
    rdict.each_value do |words|
      next if words.nil? || words.empty?
      words.reject! { |w| obsolete_alt_of_only.key?(w) && !word_dict.key?(w) }
    end
    rdict.delete_if { |_rime, words| words.nil? || words.empty? }
    after_rdict_n = rdict.values.sum(&:size)
    stripped = before_rdict_n - after_rdict_n
    puts "Pruned #{dropped} Kaikki obsolete-alt-of ghost headwords from word_dict " \
         "(#{dropped_pron_orphans} pronunciation-less), stripped #{stripped} from rdict"
  end
  dropped
end

# Phonemes that satisfy the orthographic-+r+/rhotic-final invariant.
# +ER0/1/2+ are kept here defensively even though +apply_shared_arphabet_phoneme_string_normalizations+
# splits +ER+ into +AH + R+ — some inputs (Inflect-derived prons, Kaikki forms) are constructed
# token-by-token and bypass that string-level pass, so they may still arrive ER-final at this point.
RHOTIC_FINAL_PHONEMES = %w[R ER0 ER1 ER2].to_set.freeze

# When a headword's spelling ends in +r+ but a pronunciation's last non-boundary phoneme isn't
# rhotic, append +R+ so the entry rhymes with its canonical-rhotic siblings (dasher / masher,
# butter / brother, bar / upbar). The mismatch is overwhelmingly imported BrE non-rhotic Wiktionary
# transcriptions where final +-r+ surfaces as schwa (+M AE1 . SH AH0+); the codebase's convention
# (see +phonology.rb+'s +ER0 → AH0 R+ rewrite) is +vowel + R+, so a trailing +R+ is what's missing.
#
# Mutates +pron_hash+ (a +{word => [Pronunciation]}+ map: +cmudict+ before +build_rime_dict+, then
# +word_dict+ entries +[freq, prons, ...]+ before +merge_word_dict_pronunciations_into_rdict!+).
# Returns the number of pronunciations that were patched.
def append_r_to_orthographic_r_pronunciations!(pron_hash, label:)
  fixed_words = 0
  fixed_prons = 0
  pron_hash.each do |word, entry|
    next unless word.end_with?("r")
    prons = entry.is_a?(Array) && entry.first.is_a?(Pronunciation) ? entry : entry[1]
    next if prons.nil? || prons.empty?
    word_changed = false
    prons.each_with_index do |pron, idx|
      next if pron.nil? || pron.empty?
      last = pron.phonemes.reverse.find { |p| !p.syllable_boundary? }
      next if last.nil? || RHOTIC_FINAL_PHONEMES.include?(last)
      prons[idx] = Pronunciation.new(pron.phonemes + ["R"])
      fixed_prons += 1
      word_changed = true
      dict_trace_puts(word, "append_r: #{pron} → #{prons[idx]}") if dict_trace_word?(word)
    end
    fixed_words += 1 if word_changed
  end
  if fixed_prons > 0
    puts "Appended R to #{fixed_prons} pronunciations across #{fixed_words} -r-final headwords (#{label})"
  end
  fixed_prons
end

# Identify the +-r+/+-re+-final stem of an +-ed+/+-d+ inflection by trying three peelings in order
# and accepting the first one whose stem is a known headword in +pron_hash+. Returns
# +[stem, rule]+ where +rule+ is one of +:stem_a+ (peel +-ed+, e.g. +jabbered+ → +jabber+),
# +:stem_b+ (peel +-d+, e.g. +abjured+ → +abjure+), or +:stem_c+ (peel +-Xed+ for an
# orthographic doubled-consonant past tense, e.g. +barred+ → +bar+); +nil+ if none match.
# The headword-presence gate is what blocks the false-positive cohort that pure
# orthographic +"ends in red"+ matching falls into: +bred+ / +cred+ / +shred+ / +fred+ /
# +dred+ / +red+ / +infrared+ / +interbred+ / +purebred+ / +thoroughbred+ / +unbred+ /
# +antired+ / +wilfred+ / +winfred+ — none of their candidate stems (+br+, +cr+, +shr+,
# +infrar+, +wilfr+, …) appear in the lexicon, so we never mistake them for past tenses
# of an +-r+-stem verb. The +:stem_c+ peel still admits +cor+ from +corded+ (false
# positive: the actual stem is +cord+, not +cor+); +stem_c_pron_aligns?+ in
# +insert_r_before_final_d_for_red_pronunciations!+ is the per-pronunciation backstop
# that rejects those by checking the inflected pron actually decomposes as +stem-pron + D+.
def red_inflection_r_stem(word, pron_hash)
  return nil unless word.length >= 5
  return nil unless word.end_with?("d")
  if word.end_with?("ed")
    stem_a = word[0..-3]
    return [stem_a, :stem_a] if stem_a.length >= 3 && stem_a.end_with?("r") && pron_hash.key?(stem_a)
    stem_c = word[0..-4]
    return [stem_c, :stem_c] if stem_c.length >= 3 && stem_c.end_with?("r") && pron_hash.key?(stem_c)
  end
  stem_b = word[0..-2]
  return [stem_b, :stem_b] if stem_b.length >= 3 && stem_b.end_with?("re") && pron_hash.key?(stem_b)
  nil
end

# +-s+/+-es+ analog of +red_inflection_r_stem+. Returns the +-r+/+-re+-final stem of an +-s+ inflection
# (+jabbers+ → +jabber+, +goitres+ → +goitre+, +abjures+ → +abjure+) or +nil+. No double-+r+ doubling
# occurs before +-s+ (+stirs+ / +purrs+ inherit the doubling from their bare stems), so there's no
# +rule-C+ peel — only +chomp("s")+ ending in +r+ or +re+. Headword-presence gate excludes loanword
# plurals whose orthography happens to end in +rs+ but whose stem isn't lexicalized (+wilfreds+,
# hypothetical +screds+, etc.).
def s_plural_r_stem(word, pron_hash)
  return nil unless word.length >= 4
  return nil unless word.end_with?("s")
  return nil if word.end_with?("ss") # mass nouns / adjectives, not -s plurals
  stem = word[0..-2]
  return nil if stem.length < 3
  return stem if (stem.end_with?("r") || stem.end_with?("re")) && pron_hash.key?(stem)
  nil
end

# Shared inner: locate the last non-boundary phoneme of +phs+ (must equal +final+, e.g. +"D"+ for +-ed+
# or +%w[S Z]+ for +-s+), confirm the second-to-last is non-rhotic, AND confirm no +R+ appears in the
# last 3 non-boundary phonemes. The K=3 +R+-lookback rejects loanword plurals like +halteres+, +flores+,
# +mores+, +rivieres+, +torres+, +libres+, +entendres+, +oeuvres+, +louvres+ whose orthographic stem
# ends in +-re+ but whose CMU pronunciation already exposes the stem's +R+ before a final +Z+ via an
# unstressed vowel insertion (+R IY0 Z+, +R EY2 Z+, +R AH0 Z+); inserting another +R+ before the
# +Z+ would produce a doubly-rhotic phoneme tail. The same guard incidentally fires on +jared+ in the
# +-red+ helper (last 3 = +R AH0 D+), kicking out a known false positive of +red_inflection_r_stem+'s
# rule A.
#
# Returns the index in +phs+ where +R+ should be inserted, or +nil+ to skip.
def r_insertion_index_before_final(phs, final)
  finals = final.is_a?(Array) ? final : [final]
  last_idx = nil
  prev_idx = nil
  third_idx = nil
  (phs.length - 1).downto(0) do |k|
    next if phs[k].syllable_boundary?
    if last_idx.nil?
      last_idx = k
    elsif prev_idx.nil?
      prev_idx = k
    else
      third_idx = k
      break
    end
  end
  return nil if last_idx.nil?
  return nil unless finals.include?(phs[last_idx])
  return nil if prev_idx && RHOTIC_FINAL_PHONEMES.include?(phs[prev_idx])
  return nil if prev_idx && phs[prev_idx] == "R"
  return nil if third_idx && phs[third_idx] == "R"
  last_idx
end

# Per-pronunciation backstop for +red_inflection_r_stem+'s +:stem_c+ peel: confirm the inflected
# pron actually decomposes as +stem-pron + D+, optionally with the stem's final +R+ dropped (the
# BrE rhotic-drop case the rule exists to repair). Differentiates legitimate doubled-consonant
# past tenses like +barred+ (+B AA1 R+ + +D+ ✓) from +corded+, where the +-Xed+ peel happens to
# yield an +-r+-final string (+cor+) that is also a lexicon entry but is not the actual stem
# (the real stem is +cord+ +K AO1 R D+). +corded+'s pron is +K AO1 R . D AH0 D+, whose tail
# after +K AO1 R+ is +D AH0 D+ — three phonemes, not a valid +-ed+ suffix shape. Without this
# gate the rule incorrectly inserts an R into +corded+'s pron and makes it rhyme with
# +quartered+. Only applied to the +:stem_c+ branch; +:stem_a+ relies on the +-r+-final stem
# matching by orthography + presence (+jabber+ → +jabbered+) and would reject the BrE-drop
# inflected pron the rule exists to fix if it required the stem's R to be present.
def stem_c_pron_aligns?(inflected_pron, stem_prons)
  return false if stem_prons.nil? || stem_prons.empty?
  inf_phs = inflected_pron.phonemes.reject(&:syllable_boundary?)
  stem_prons.any? do |sp|
    next false if sp.nil? || sp.empty?
    sp_phs = sp.phonemes.reject(&:syllable_boundary?)
    last = sp_phs.last
    next false unless RHOTIC_FINAL_PHONEMES.include?(last)
    next true if inf_phs == sp_phs + ["D"]
    # BrE rhotic-drop applies only to literal +R+; +ERn+ is itself vowel+rhotic, not droppable.
    next true if last == "R" && inf_phs == sp_phs[0..-2] + ["D"]
    false
  end
end

# When a headword is the +-ed+/+-d+ inflection of a known +-r+/+-re+-final stem (+jabber+ → +jabbered+,
# +abjure+ → +abjured+, +debar+ → +debarred+) but a pronunciation lacks the rhotic right before the
# final +D+, splice +R+ in. The mismatch comes from the same BrE / non-rhotic Wiktionary import that
# produces +-r+-final schwa drops (+jabbered+ → +JH AE1 . B AH0 D+); the canonical past-tense form is
# +stem-pronunciation + D+, e.g. +JH AE1 . B AH0 R D+ to match +jabber+ +(JH AE1 . B AH0 R)+.
#
# Mutates +pron_hash+ entries +(cmudict: word => [Pronunciation], word_dict: word => [freq, prons, …])+.
# Independent of the +-r+-final pass: stem identification keys off orthography + presence in the hash,
# not off any pron's phoneme content. The +:stem_c+ branch additionally requires per-pronunciation
# alignment (+stem_c_pron_aligns?+) since the orthographic peel admits same-prefix lookalikes
# like +cor+ from +corded+ where the actual stem is +cord+, not +cor+.
def insert_r_before_final_d_for_red_pronunciations!(pron_hash, label:)
  fixed_words = 0
  fixed_prons = 0
  pron_hash.each do |word, entry|
    rule_result = red_inflection_r_stem(word, pron_hash)
    next if rule_result.nil?
    stem, rule = rule_result
    prons = entry.is_a?(Array) && entry.first.is_a?(Pronunciation) ? entry : entry[1]
    next if prons.nil? || prons.empty?
    if rule == :stem_c
      stem_entry = pron_hash[stem]
      stem_prons = stem_entry.is_a?(Array) && stem_entry.first.is_a?(Pronunciation) ? stem_entry : stem_entry[1]
    end
    word_changed = false
    prons.each_with_index do |pron, idx|
      next if pron.nil? || pron.empty?
      if rule == :stem_c && !stem_c_pron_aligns?(pron, stem_prons)
        dict_trace_puts(word, "insert_r_before_d: skip (stem_c=#{stem} pron does not align with #{pron})") if dict_trace_word?(word)
        next
      end
      ins = r_insertion_index_before_final(pron.phonemes, "D")
      next if ins.nil?
      new_phs = pron.phonemes.dup
      new_phs.insert(ins, "R")
      prons[idx] = Pronunciation.new(new_phs)
      fixed_prons += 1
      word_changed = true
      dict_trace_puts(word, "insert_r_before_d: #{pron} → #{prons[idx]}") if dict_trace_word?(word)
    end
    fixed_words += 1 if word_changed
  end
  if fixed_prons > 0
    puts "Inserted R before final D in #{fixed_prons} pronunciations across #{fixed_words} -ed-after-r-stem headwords (#{label})"
  end
  fixed_prons
end

# +-s+ counterpart of +insert_r_before_final_d_for_red_pronunciations!+. When a headword is the +-s+
# plural / 3sg of an +-r+/+-re+-final stem (+jabber+ → +jabbers+, +goitre+ → +goitres+, +abjure+ →
# +abjures+) but a pronunciation lacks the rhotic right before the final +S+/+Z+, splice +R+ in. The
# canonical post-fix form is +stem-pronunciation + Z+ (e.g. +JH AE1 . B AH0 R Z+ matching +jabber+
# +(JH AE1 . B AH0 R)+).
#
# Same K=3 +R+-lookback as the +-red+ helper rejects internal-+R+ loanword plurals (+halteres+,
# +flores+, +mores+, +rivieres+, +torres+, +libres+, +entendres+, +oeuvres+, +louvres+, +abares+,
# +bures+ when its first variant is already +B EH1 R Z+).
def insert_r_before_final_sibilant_for_s_pronunciations!(pron_hash, label:)
  fixed_words = 0
  fixed_prons = 0
  pron_hash.each do |word, entry|
    next if s_plural_r_stem(word, pron_hash).nil?
    prons = entry.is_a?(Array) && entry.first.is_a?(Pronunciation) ? entry : entry[1]
    next if prons.nil? || prons.empty?
    word_changed = false
    prons.each_with_index do |pron, idx|
      next if pron.nil? || pron.empty?
      ins = r_insertion_index_before_final(pron.phonemes, %w[S Z])
      next if ins.nil?
      new_phs = pron.phonemes.dup
      new_phs.insert(ins, "R")
      prons[idx] = Pronunciation.new(new_phs)
      fixed_prons += 1
      word_changed = true
      dict_trace_puts(word, "insert_r_before_s: #{pron} → #{prons[idx]}") if dict_trace_word?(word)
    end
    fixed_words += 1 if word_changed
  end
  if fixed_prons > 0
    puts "Inserted R before final S/Z in #{fixed_prons} pronunciations across #{fixed_words} -s-after-r-stem headwords (#{label})"
  end
  fixed_prons
end

def rebuild_rhymecrime_dictionaries()
  clear_wordnet_lemma_cache!
  ensure_conceptnet_lemma_cache_for_build!
  cmudict = load_cmudict
  original_cmudict_headwords = cmudict.keys.each_with_object(Set.new) { |k, s| s.add(k) }
  wordfreq_hash = load_wordfreq
  wiktionary_prons, forms_map, pos_map, kaikki_verb_morph, kaikki_capitalized_only, kaikki_variant_map, kaikki_obsolete_alt_of_only = load_wiktionary
  varcon_variant_map = load_varcon
  wiktionary_headwords = wiktionary_prons.keys
  apply_lexical_pos_layer_a!(pos_map)
  wn_seed_pos_map_for_cmudict_gaps!(pos_map, cmudict)
  apply_lexical_pos_layer_b!(pos_map, wordfreq_hash)
  save_part_of_speech_map(pos_map)
  merge_wiktionary!(cmudict, wiktionary_prons)
  wiktionary_prons.clear
  wiktionary_prons = nil
  merge_inflected_forms!(cmudict, forms_map)
  merge_gdropped_in_apostrophe_forms!(cmudict, forms_map)
  subtlex_hash, subtlex_total_hash = load_subtlex
  # Track which words are inflected forms for frequency inheritance
  forms_map.each do |base_word, form_pairs|
    form_pairs.each do |inflected_word, base|
      $inflection_base_words[inflected_word] = base if cmudict.key?(inflected_word)
    end
  end
  # Build set of all words with Wiktionary presence (for existence floor)
  wiktionary_words = Set.new(wiktionary_headwords)
  forms_map.each do |base_word, form_pairs|
    wiktionary_words.add(base_word)
    form_pairs.each do |inflected_word, _|
      wiktionary_words.add(inflected_word) if cmudict.key?(inflected_word)
    end
  end
  delete_explicitly_forbidden_keys_from_hash(cmudict)
  delete_unrhymable_stop_words_from_hash(cmudict)
  hyp_cmudict_edge = delete_headwords_with_edge_hyphen!(cmudict)
  puts "Removed #{hyp_cmudict_edge} cmudict headwords with a leading or trailing '-'" if hyp_cmudict_edge > 0
  append_r_to_orthographic_r_pronunciations!(cmudict, label: "cmudict")
  insert_r_before_final_d_for_red_pronunciations!(cmudict, label: "cmudict")
  insert_r_before_final_sibilant_for_s_pronunciations!(cmudict, label: "cmudict")
  rdict = build_rime_dict(cmudict)
  word_dict = build_word_dict(cmudict, rdict, subtlex_hash, subtlex_total_hash, wordfreq_hash, wiktionary_words, pos_map, forms_map, kaikki_verb_morph, original_cmudict_headwords, kaikki_capitalized_only, kaikki_variant_map, varcon_variant_map)
  prune_obsolete_alt_of_only_headwords!(word_dict, rdict, kaikki_obsolete_alt_of_only)
  hyphen_fold_build_keys = word_dict.keys
  lemma_map = compute_lemma_map(word_dict)
  save_string_hash(rdict, generated_dict_path_under_dict_dir(RIME_DICT_FILENAME), RIME_DICT_HEADER)
  save_word_dict(word_dict, lemma_map)
  save_word_lemma_map!(word_dict, lemma_map)
  # Runtime-canonical msgpack mirrors of the two +.txt+ artifacts above.
  # +word_dict()+ / +rdict()+ in +crime.rb+ load these in BOTH local-dev and
  # Lambda mode; the +.txt+ files are kept on disk for human inspection only.
  # See the +WORD_DICT_MSGPACK_FILENAME+ doc comment in +utils_rhyme.rb+ for
  # the storage format and the rationale behind retiring the DDB +word#+ /
  # +rime#+ partitions.
  save_word_dict_msgpack!(word_dict, lemma_map)
  save_rime_dict_msgpack!(rdict)
  save_hyphen_variant_map!(hyphen_fold_build_keys, exported_keys: word_dict.keys)
  if include_conceptnet_numberbatch_dict_exports?
    rel_bases = relatedness_export_base_headwords(word_dict.keys, lemma_map)
    save_conceptnet_edge_map!(word_dict.keys, lemma_map)
    save_numberbatch_vectors!(rel_bases)
  else
    puts "Skipping ConceptNet edge map and Numberbatch vectors " \
         "(set RHYMECRIME_DICT_BUILD_CONCEPTNET_NUMBERBATCH=1 to rebuild, or run ./bin/build)"
  end

  # Build the semantic base map AFTER Numberbatch is on disk so the cosine
  # guard in +compute_semantic_base_map+ has data to consult. First-run
  # bootstrap (no prior NB msgpack) is fine: when the file is missing the
  # guard silently no-ops and we get the surface-only filtered map; the next
  # build will tighten it.
  nb_vectors_for_guard = load_numberbatch_vectors_for_semantic_base_guard
  semantic_base_map, semantic_base_transforms = compute_semantic_base_map(word_dict, lemma_map, nb_vectors: nb_vectors_for_guard)
  save_word_semantic_base_map!(word_dict, semantic_base_map, transform_for: semantic_base_transforms)

  common_n = 0
  common_base_forms = Set.new
  word_dict.each do |word, (freq, _)|
    next unless freq > RARE_FREQ_MAX

    common_n += 1
    base = lemma_map.fetch(word, word)
    common_base_forms.add(base)
  end
  cue_n = 0
  target_n = 0
  common_base_forms.each do |base|
    next unless cue_word?(base, word_dict)

    cue_n += 1
    target_n += 1 if relatedness_target_word?(base, word_dict, rdict)
  end
  puts "word_dict: #{word_dict.size} entries"
  puts "  - #{common_n} common"
  puts "  - #{common_base_forms.size} common base forms"
  puts "  - #{cue_n} cue words (compute row PKs)"
  puts "  - #{target_n} relatedness-target words (eligible to appear in a related list)"
end
