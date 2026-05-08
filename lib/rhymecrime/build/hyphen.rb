# frozen_string_literal: true


def load_hyphen_multi_fold_map_from_disk
  return nil if bootstrap_mode?

  path = generated_dict_path(HYPHEN_VARIANT_MAP_FILENAME)
  return nil unless File.exist?(path)
  raw = JSON.parse(BuildIoUtils.read(path, encoding: "UTF-8", hint: "load_hyphen_multi_fold_map_from_disk"))
  out = {}
  raw.each do |fold, arr|
    out[fold] = arr.freeze
  end
  out.freeze
rescue Errno::ENOENT
  # File was removed between the exist? check and the read (e.g. another build
  # invalidated the symlink). Caller falls back to rebuilding from $word_dict.
  # JSON::ParserError used to be rescued here too, but a corrupt cache should
  # halt instead of silently regenerating.
  nil
end

# Two distinct contexts call this:
#   1. Runtime / tests: $word_dict is the runtime-loaded msgpack, never swapped. The
#      saved JSON cache (hyphen_variant_map.json) is the source of truth — load it
#      once and reuse forever (~50 KB read; tens of thousands of calls per spec run).
#   2. dict-build: $word_dict is the in-flight hash set by with_word_dict. Build from
#      the live key-set so tombstone_dispreferred_spelling_headwords! and
#      preferred_form() see the current build's headword population rather than the
#      one-build-stale on-disk map. Without this, consecutive builds oscillate: stale
#      map is missing tombstone pairs from the previous run (e.g. non-plussed) → those
#      words escape tombstoning → they survive into the next saved map → they get
#      tombstoned in that run → saved map is missing the pair again → infinite flip.
#
# We distinguish the two via RHYMECRIME_BUILD_MODE (set by bin/build for both bootstrap
# and final dict-build invocations). The presence of $word_dict alone is not a reliable
# in-build signal: crime.rb populates $word_dict at runtime too, on the first call to
# word_dict() from any spec.
#
# Cache key:
#   - runtime: the constant :runtime — populate once from disk, never invalidate.
#   - build: $word_dict.object_id — invalidates whenever with_word_dict swaps the live
#     hash, so a nested build pass with a different dict instance gets a fresh build.
# Memoization is GLOBAL ($-prefixed) on purpose. A top-level @ivar would attach to
# whichever self called this — fresh per RSpec ExampleGroup instance — so the cache
# never persists across examples and every test pays a ~0.5 s rebuild against
# $word_dict.keys (~430k entries). That was a 14+ minute regression on the suite.
$hyphen_multi_fold = nil
$hyphen_multi_fold_cache_key = nil
def hyphen_multi_fold_map
  in_build = ENV["RHYMECRIME_BUILD_MODE"] && $word_dict.is_a?(Hash) && !$word_dict.empty?
  cache_key = in_build ? $word_dict.object_id : :runtime
  if $hyphen_multi_fold_cache_key != cache_key
    $hyphen_multi_fold_cache_key = cache_key
    $hyphen_multi_fold =
      if in_build
        build_hyphen_multi_fold_map($word_dict.keys)
      else
        load_hyphen_multi_fold_map_from_disk || build_hyphen_multi_fold_map
      end
  end
  $hyphen_multi_fold
end

# Frequency lookup that works in both runtime and build contexts. Runtime
# (crime.rb loaded) defers to word_dict's lazy loader; build time
# (bin/dict-build, where crime.rb is not on the load path) reads the
# $word_dict global pinned by preferred_form_in_build_lexicon. Calling
# frequency(word) directly would NameError during the build because
# crime.rb is the only place it's defined.
def preferred_form_frequency_lookup(word)
  return 0 if word.nil?
  wd = defined?(word_dict) ? word_dict : $word_dict
  return 0 if wd.nil?
  entry = wd[word]
  return 0 if entry.nil?
  return 0 if defined?(BuildEntry) && entry.is_a?(BuildEntry) && entry.tombstoned?
  (entry[0] || 0).to_i
end

def preferred_among_hyphen_equivalents(forms)
  n = forms.length
  return forms[0] if n <= 1
  # Closed "nonplussed"/"nonprofit"/… beats editorial "non-plussed"/"non-profit"
  # when both share a hyphen-fold (delete "-" groups them). The legacy branch
  # below collected only "non-*" hyphenated forms and returned nons.min, which
  # wrongly preferred "non-plussed" over "nonplussed" (the solid form never
  # matched NON_HYPHEN_PREF_RE, so it was ignored).
  forms_set = forms.each_with_object({}) { |x, h| h[x] = true }
  twinned_solids = forms.select do |f|
    next false if f.include?("-")
    fd = f.downcase
    next false unless fd.start_with?("non") && fd.length > 3
    stem = fd.byteslice(3..-1)
    next false if stem.empty?
    forms_set["non-#{stem}"]
  end
  if twinned_solids.any?
    return twinned_solids.min_by { |f| [-preferred_form_frequency_lookup(f), f.downcase] }
  end
  nons = []
  i = 0
  while i < n
    f = forms[i]
    nons << f if NON_HYPHEN_PREF_RE.match?(f)
    i += 1
  end
  return nons.min if nons.any?
  parts = []
  i = 0
  while i < n
    f = forms[i]
    parts << f if PARTICLE_HYPHEN_PREF_RE.match?(f)
    i += 1
  end
  unless parts.empty?
    # Particle-prefix compounds (off-stage, on-line, in-box) default to
    # keeping the hyphen ONLY when the solid alternative is absent or has
    # strictly lower corpus frequency. Tied or solid-wins falls through
    # to the orthographic default below, picking up verbal lexicalizations
    # like 'offset' (vs 'off-set') where modern usage has collapsed the
    # hyphen. Cases like 'in-laws' (different stress from 'inlaws') are
    # filtered out earlier by the pron-compatibility guard in
    # preferred_form, so this rule never sees them.
    hyph_pick = parts.min
    solid_alt = forms.find { |f| !f.include?("-") }
    if solid_alt.nil? || preferred_form_frequency_lookup(solid_alt) < preferred_form_frequency_lookup(hyph_pick)
      return hyph_pick
    end
    # else fall through to solid-form-wins fallback below
  end
  redups = []
  i = 0
  while i < n
    f = forms[i]
    redups << f if hyphen_redup_prefers_hyphenated_form?(f)
    i += 1
  end
  return redups.min if redups.any?
  # Corpus-frequency override before the default fewer-hyphens-wins rule:
  # when one form is strictly more frequent, prefer it. Catches foreign
  # loanword phrases like 'avant-garde' (freq 10) vs 'avantgarde' (freq 2)
  # where the hyphenated spelling is the standard English rendering and
  # the dehyphenated form is a rare back-formation. When all forms are
  # tied (or zero-frequency), fall through to the orthographic default.
  freqs = forms.map { |f| [f, preferred_form_frequency_lookup(f)] }
  max_pair = freqs.max_by { |pair| pair[1] }
  if max_pair && max_pair[1] > 0
    second_max = freqs.reject { |p| p == max_pair }.map { |p| p[1] }.max || 0
    return max_pair[0] if max_pair[1] > second_max
  end
  forms.min_by { |f| [f.count("-"), f.downcase] }
end

# Filter forms (a hyphen-fold equivalence class containing word) down to
# those that share at least one pronunciation with word. Different stress
# patterns or phoneme sequences mean the forms are different lexemes that
# happen to share an orthographic fold ('inlaws' /IH1 N L AA2 Z/ is stressed
# differently from 'in-laws' /IH2 N L AA1 Z/), so they shouldn't be grouped
# as spelling variants. Returns the input forms unchanged when prons are
# unavailable on either side, so this never breaks pron-less builds.
def hyphen_fold_pron_compatible_forms(word, forms)
  word_prons = pronunciation_phonemes_for_compat(word)
  return forms if word_prons.empty?
  forms.select do |f|
    next true if f == word
    f_prons = pronunciation_phonemes_for_compat(f)
    next true if f_prons.empty?
    f_prons.any? { |fp| word_prons.include?(fp) }
  end
end

def pronunciation_phonemes_for_compat(word)
  prons = pronunciations(word)
  return [] if prons.nil? || prons.empty?
  prons.map do |p|
    raw = p.respond_to?(:phonemes) ? p.phonemes : p
    normalize_phonemes_for_hyphen_fold_compat(raw)
  end
rescue StandardError
  []
end

# Normalize a phoneme list so two prons that differ only in secondary or
# unstressed vowel marks ('B AE1 K HH AE2 N D' vs 'B AE1 K HH AE0 N D' for
# 'backhand' / 'back-hand') compare equal, while a real primary-stress
# shift ('IH1 N L AA2 Z' for 'inlaws' vs 'IH2 N L AA1 Z' for 'in-laws')
# stays distinct. Strips trailing '0' and '2' from each phoneme but keeps
# the '1' marker so the position of the primary stress is preserved.
def normalize_phonemes_for_hyphen_fold_compat(phonemes)
  phonemes.map do |ph|
    case ph
    when /\A(.+?)[02]\z/ then ::Regexp.last_match(1)
    else ph
    end
  end
end

def preferred_form(word)
  vf = variants[word]
  if vf
    dict_utils_debug "The preferred form of '#{word}' is '#{vf[0]}'" unless vf[0] == word
    return vf[0]
  end
  morph = us_uk_morphology_pair(word)
  if morph
    return morph[0]
  end
  forms = hyphen_multi_fold_map[spelling_variant_hyphen_fold(word)]
  return word if forms.nil? || forms.length < 2
  compatible = hyphen_fold_pron_compatible_forms(word, forms)
  return word if compatible.length < 2
  preferred_among_hyphen_equivalents(compatible)
end

# Run block with $word_dict pointing at hash, restoring the previous
# value on exit (success or raise). Used by build-time call sites that need
# helpers in this file (preferred_form, word_dict_includes_headword?,
# the wiktionary_*_overplural predicates, …) to read the in-flight build
# hash instead of the runtime-loaded msgpack: those helpers consult
# $word_dict unconditionally, so without this swap they'd see either
# nil (pre-runtime) or a stale prior-build dict during bin/dict-build.
# Idempotent on nested calls (each call stashes/restores its own previous).
def with_word_dict(hash)
  previous = $word_dict
  $word_dict = hash
  yield
ensure
  $word_dict = previous
end

# Like preferred_form, but US/UK / hyphen resolution consults word_dict (the build-time hash) via
# $word_dict so rime-bucket pruning sees the correct preferred surface before export.
def preferred_form_in_build_lexicon(word, word_dict)
  with_word_dict(word_dict) { preferred_form(word) }
end

def all_forms(word)
  vf = variants[word]
  forms = hyphen_multi_fold_map[spelling_variant_hyphen_fold(word)]
  if forms && forms.length >= 2
    compat = hyphen_fold_pron_compatible_forms(word, forms)
    forms = compat.length >= 2 ? compat : nil
  else
    forms = nil
  end
  morph = us_uk_morphology_variant_forms(word)
  if vf
    unless forms
      if morph
        merged = vf.dup
        morph.each { |x| merged << x unless merged.include?(x) }
        return merged.uniq
      end
      return vf
    end
    merged = vf.dup
    morph&.each { |x| merged << x unless merged.include?(x) }
    forms.each { |x| merged << x unless merged.include?(x) }
    return merged.uniq
  end
  if morph
    unless forms
      return morph
    end
    merged = morph.dup
    forms.each { |x| merged << x unless merged.include?(x) }
    return merged.uniq
  end
  if forms
    pref = preferred_among_hyphen_equivalents(forms)
    rest = forms.reject { |w| w == pref }.sort
    return [pref] + rest
  end
  [word]
end
