# encoding: utf-8
# UniMorph 4.0 English (corpora/unimorph/eng) loader and accessors.
#
# UniMorph treats English inflection as a curated lookup table: 399 575 lemmas /
# 579 293 unique forms / 652 477 (lemma, form, MSD) triples covering all the
# productive inflection classes plus suppletion (bad → worse, arise → arose,
# awake → awoke / awoken). Used here as a *paradigm oracle* for the morphology
# policy gates in morphology.rb: when UniMorph attests a base+kind paradigm,
# any other Inflect-generated spelling for that paradigm must clear an
# independent attestation bar (Kaikki forms_map or Zipf ≥ RARE) before it can
# inherit a lemma's frequency, otherwise it's rejected as a heuristic mistake
# (outpour → outpourred, prefer → preferrer agent-noun, mandolin → mandolined).
#
# UniMorph's MSD inventory collapses into our Inflect.match_suffix_kind tags:
#   N;PL          → :s     N;PL and V;PRS;3;SG share the same surface form for
#   V;PRS;3;SG    → :s     regular verbs (nouns: cats; verbs: walks). Our gate
#                          treats either as "kind :s attested for this base".
#   V;PST         → :ed    V;PST and V;V.PTCP;PST collapse for regular verbs
#   V;V.PTCP;PST  → :ed    (walked) and split for irregulars (broke / broken).
#   V;V.PTCP;PRS  → :ing
#   ADJ;CMPR      → :er
#   ADJ;SPRL      → :est
#
# Bare-lemma rows (form == lemma, MSD ∈ {N;SG, ADJ, V;NFIN;IMP+SBJV}) are
# skipped — they don't add a paradigm slot.
#
# Lambda runtime never needs UniMorph (the policy decisions are baked into
# generated/word_dict.txt at build time); when corpora/unimorph/eng is missing,
# every accessor returns the silent-default value so production stays unaffected.

require "set"

module UniMorph
  PATH = File.expand_path("../../../corpora/unimorph/eng", __dir__)

  MSD_TO_KIND = {
    "N;PL" => :s,
    "V;PRS;3;SG" => :s,
    "V;PST" => :ed,
    "V;V.PTCP;PST" => :ed,
    "V;V.PTCP;PRS" => :ing,
    "ADJ;CMPR" => :er,
    "ADJ;SPRL" => :est,
  }.freeze

  # UniMorph leaks noun-class tags into the form column on ~2k rows ("aba\tcountable\tN;PL",
  # "lead\tcountable\tN;PL", "rue\tuncountable\tN;PL", …). These are not English plurals;
  # ignore them at load time so they never enter by_base.
  INVALID_FORMS = Set.new(%w[countable uncountable]).freeze

  # Permissive English-orthography filter for both lemma and form columns. Excludes UniMorph's
  # Middle / Early Modern English residue (æquivalent, advaunce, capitayn, posteriour) and
  # alphanumeric IDs / Latin (4ktro, dioxindole-style chemistry runs we don't want as
  # paradigm anchors). Lowercase letters, apostrophe, and hyphen only — matches what shows up
  # in Kaikki's modern-English forms_map.
  ENGLISH_SURFACE_RE = /\A[a-z][a-z'\-]*\z/.freeze

  # by_base[lemma] = { kind_symbol => Set<form_string> }. Loaded once on first access; the
  # build process never mutates the file mid-run, so memoization is safe across phases.
  def self.by_base
    return @by_base if defined?(@by_base) && @by_base

    @by_base = {}
    return @by_base unless corpus_present?

    File.foreach(PATH, encoding: "UTF-8") do |line|
      line.chomp!
      next if line.empty?
      lemma, form, msd = line.split("\t")
      next if lemma.nil? || form.nil? || msd.nil?
      next if lemma == form
      kind = MSD_TO_KIND[msd]
      next unless kind
      next if INVALID_FORMS.include?(form)
      next unless ENGLISH_SURFACE_RE.match?(lemma)
      next unless ENGLISH_SURFACE_RE.match?(form)
      ((@by_base[lemma] ||= {})[kind] ||= Set.new).add(form)
    end
    @by_base
  end

  def self.corpus_present?
    @corpus_present = File.file?(PATH) unless defined?(@corpus_present)
    @corpus_present
  rescue StandardError
    @corpus_present = false
  end

  def self.attests_base?(base)
    by_base.key?(base)
  end

  # True when UniMorph lists at least one form of the given suffix kind (:s/:ed/:ing/:er/:est)
  # for base. Distinct from attests_base?: UniMorph may list a noun base whose paradigm only
  # contains :s (no verbal :ed/:ing) — the gate then stays silent on verbal kinds.
  def self.attests_kind?(base, kind)
    h = by_base[base]
    !h.nil? && h.key?(kind) && !h[kind].empty?
  end

  def self.attests_form?(base, form)
    h = by_base[base]
    return false if h.nil?
    h.each_value { |set| return true if set.include?(form) }
    false
  end

  # [[form, kind], ...] flat list across kinds. Same shape as Kaikki's forms_map
  # entries (form first, base/kind second), so callers can union the two sources.
  def self.forms_for_base(base)
    h = by_base[base]
    return [] if h.nil?
    h.flat_map { |kind, set| set.map { |f| [f, kind] } }
  end

  # Test-only reset hook. Build process never calls this — UniMorph data does not change
  # within a single rebuild. Tests that mutate corpora/unimorph/eng or want to exercise
  # the corpus-absent branch can wipe both memoized fields between examples.
  def self.reset_memoized_state_for_specs!
    remove_instance_variable(:@by_base) if instance_variable_defined?(:@by_base)
    remove_instance_variable(:@corpus_present) if instance_variable_defined?(:@corpus_present)
  end
end
