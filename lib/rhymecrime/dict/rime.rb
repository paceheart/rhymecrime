# encoding: utf-8
# Rime index: build, merge word_dict prons, rare-only bucket prune, filter_cmudict.

require_relative "utils_rhyme"
require_relative "pronunciation.rb"
require_relative "constants"

def build_rime_dict(cmudict)
  # +RimeDict+ subclasses +Hash+ and adds a per-instance pruning-active flag
  # consulted by its read methods; the +filter_word_dict_disconnected!+
  # fixed-point loop flips the flag during its inner rounds so a naive
  # +rdict[rime]+ call from a new contributor inside the window raises with
  # the caller location. Outside the window the guard is inert — a single
  # boolean check per read. See +build_entry.rb+ for the full class.
  rdict = RimeDict.new {|h,k| h[k] = [] } # hash of arrays, each element of which is a Pronunciation
  i = 0;
  for word, prons in cmudict
    for pron in prons
      rime = pron.rime
      rdict[rime].push(word)
    end
    i = i + 1;
  end
  # sort in-place and uniq in-place to avoid an extra array allocation per bucket
  for rime, words in rdict
    words.sort!
    words.uniq!
    rdict[rime] = words
  end
  print "Identified #{rdict.length} unique rimes, "
  rdict.reject!{|rime, words| words.length <= 1 }
  puts "#{rdict.length} of which are nonempty"
  return rdict
end

# Tombstoned-aware predicate: returns true for +word_dict+ entries that
# the pipeline has marked for terminal pruning (scrubs, classifier, disconnect).
# Kept as a small helper so downstream rdict / spelling-variant / rime-bucket
# passes can consistently treat pending-deleted rows as "gone" for the
# purpose of their decisions, even though the row physically lives in
# +word_dict+ until +finalize_build_entries!+ runs at the end of
# +build_word_dict+.
def word_dict_entry_tombstoned?(entry)
  return false unless entry
  return false unless defined?(BuildEntry) && entry.is_a?(BuildEntry)
  entry.tombstoned?
end

# True when +word_dict+ has a row for +key+ AND that row is not marked for
# tombstoned. This is the "baseline-parity" replacement for
# +word_dict.key?(key)+ in later build phases (spelling-variant emission,
# disconnect filter, rime pruners) that used to run against a +word_dict+
# whose scrubbed rows had been physically removed by +hash.delete+. After the
# defer-losses refactor, scrubbed rows linger with +tombstoned+ set
# until +finalize_build_entries!+, so raw +key?+ would see rows the baseline
# treated as absent; this helper restores that "absent from the live lexicon"
# semantics without forcing callers to write the two-part check inline.
def word_dict_live?(word_dict, key)
  entry = word_dict[key]
  return false if entry.nil?
  !word_dict_entry_tombstoned?(entry)
end

# Word_dict gains pronunciations from frequency phases (e.g. morph promotion) that never appear in
# cmudict; runtime rhyme lookup uses rdict, so those words must be indexed here too.
#
# Tombstoned entries are intentionally INCLUDED in rdict here (and kept
# by +strip_dispreferred_headwords_from_rdict!+ below) so that downstream
# bucket-level decisions (+rime_bucket_one_common_preferred_with_any_rare?+,
# +all_common_headwords_rich_rhyme_for_rime?+) see the same bucket
# membership they saw in the pre-refactor build, where scrubbed / classifier-
# forbidden rows lingered in rdict as stale cmudict references until the
# disconnect filter's +prune_rdict_to_headwords!+ pass at the end. Since
# +word_dict_frequency_for_rime_bucket+ returns 0 for pending-deleted entries
# (matching the baseline's +entry.nil?+ → 0 semantics), those bucket members
# contribute as "rare" for the rare-only prune but keep the count right for
# the one-common-preferred-with-any-rare check.
def merge_word_dict_pronunciations_into_rdict!(rdict, word_dict)
  word_dict.each do |word, entry|
    next if entry.nil?
    prons = entry[1]
    next if prons.nil? || prons.empty?
    prons.each do |pron|
      rime = pron.rime
      next if rime.empty?
      (rdict[rime] ||= []) << word
    end
  end
  rdict.each do |_rime, words|
    words.sort!
    words.uniq!
  end
  rdict.reject! { |_rime, words| words.length <= 1 }
  rdict
end

# When the preferred form of a hyphen / spelling variant has no prons but its
# dispreferred sibling does, copy the prons from the dispreferred form into the
# preferred form's +word_dict+ entry. The typical case is the hyphen-preferred
# canonicalization (+up-end+ from +upend+, +hand-held+ from +handheld+,
# +on-screen+ from +onscreen+, +best-seller+ from +bestseller+, …): CMU and
# Kaikki list only the unhyphenated surface, so the hyphenated entry gets a
# +word_dict+ row from spelling-variant resolution but never receives a
# pronunciation from any source.
#
# Without this inheritance, +strip_dispreferred_headwords_from_rdict!+ removes
# the dispreferred surface from its rime bucket, but the preferred form was
# never added (the prior +merge_word_dict_pronunciations_into_rdict!+ pass
# skips empty-pron entries) — the bucket loses both surfaces, so a query like
# +find_rhyming_words('pend')+ misses +up-end+/+upend+ entirely. Copying the
# prons fixes both runtime +pronunciations(preferred)+ lookup and the rdict
# membership (after a follow-up +merge_word_dict_pronunciations_into_rdict!+).
#
# Run after +emit_spelling_variants_auto!+ so the latest auto-emitted variant
# pairs are visible to +preferred_form_in_build_lexicon+, and before
# +strip_dispreferred_headwords_from_rdict!+ so the rime-bucket stripper sees
# the preferred form populated.
def inherit_prons_from_dispreferred_to_preferred!(word_dict, log: true)
  inherited = 0
  word_dict.each do |word, entry|
    next if entry.nil?
    next if word_dict_entry_tombstoned?(entry)
    prons = entry[1]
    next unless prons.is_a?(Array) && !prons.empty?
    pref = preferred_form_in_build_lexicon(word, word_dict)
    next if pref == word
    pref_entry = word_dict[pref]
    next unless pref_entry
    next if word_dict_entry_tombstoned?(pref_entry)
    pref_prons = pref_entry[1]
    next unless pref_prons.is_a?(Array) && pref_prons.empty?
    pref_entry[1] = prons.dup
    inherited += 1
    if dict_trace_word?(pref) || dict_trace_word?(word)
      dict_trace_puts(pref, "inherit_prons_from_dispreferred_to_preferred: #{pref} ← #{word} (#{prons.map(&:to_s).inspect})")
    end
  end
  if log && inherited > 0
    puts "#{inherited} preferred-form headwords inherited prons from dispreferred siblings"
  end
  inherited
end

# Drop alternate spellings / US–UK / hyphen dispreferred surfaces so +rime_dict+ lists only
# +preferred_form_in_build_lexicon+ headwords (matches runtime +preferred_form+ policy).
#
# Tombstoned entries are intentionally kept (same as +nil+ entries) —
# the disconnect filter's +prune_rdict_to_headwords!+ pass filters rdict
# down to live word_dict keys at the end, matching the pre-refactor behavior
# where scrubbed / classifier-forbidden rows lingered as stale cmudict
# references in rdict until that final pass.
def strip_dispreferred_headwords_from_rdict!(rdict, word_dict, log: true)
  dropped = 0
  before_n = rdict.values.sum(&:size)
  rdict.each do |_rime, words|
    next if words.nil? || words.empty?

    words.reject! do |w|
      entry = word_dict[w]
      next false if entry.nil?
      next false if word_dict_entry_tombstoned?(entry)

      dis = preferred_form_in_build_lexicon(w, word_dict) != w
      dropped += 1 if dis
      dis
    end
  end
  rdict.reject! { |_rime, words| words.nil? || words.length <= 1 }
  if log && dropped > 0
    after_n = rdict.values.sum(&:size)
    puts "#{rdict.length} rime buckets (#{after_n} headwords) after removing #{dropped} dispreferred cohort entries (#{before_n} before)"
  end
  dropped
end

def word_dict_frequency_for_rime_bucket(word_dict, word)
  entry = word_dict[word]
  return 0 if entry.nil?
  return 0 if word_dict_entry_tombstoned?(entry)
  entry[0].to_i
end

def word_common_preferred_headword?(word, word_dict)
  entry = word_dict[word]
  return false if entry.nil?
  return false if word_dict_entry_tombstoned?(entry)
  return false unless word_dict_frequency_for_rime_bucket(word_dict, word) > RARE_FREQ_MAX

  preferred_form_in_build_lexicon(word, word_dict) == word
end

# True when the bucket has exactly one **common preferred** headword (+preferred_form+ / spelling variants /
# US-UK / hyphen policy, frequency > +RARE_FREQ_MAX+). Mirrors the old “exactly one common” prune but
# ignores alternate spellings that map to another headword as preferred (e.g. *colour* when *color* is preferred).
# Buckets with two or more common preferred rhymes are kept (*yum* / *plum*).
def rime_bucket_one_common_preferred_with_any_rare?(words, word_dict)
  return false if words.nil? || words.length < 2

  common_pref = 0
  words.each do |w|
    common_pref += 1 if word_common_preferred_headword?(w, word_dict)
  end
  common_pref == 1
end

# Drop rime buckets where **every** headword is rare (frequency ≤ +RARE_FREQ_MAX+), or where there is
# exactly **one** common **preferred** headword (artifact size / avoid one strong anchor + clutter).
#
# When called inside the +filter_word_dict_disconnected!+ pruning window, the
# +with_reads_during_prune+ wrapper authorizes this function's rdict reads
# (length, the iteration inside +rdict.delete_if+ implicitly, and per-trace
# partner-loss lookups below). Outside the pruning window the wrapper is a
# no-op (+RimeDict+'s guard is inert when +pruning_active?+ is false).
def delete_rare_only_rime_buckets!(rdict, word_dict, log: true)
  rime_dict_with_reads_during_prune(rdict) do
    removed = 0
    round_id = rdict.respond_to?(:pruning_active?) && rdict.pruning_active? ? "prune" : "pre"
    before_n = rdict.length
    rdict.delete_if do |rime, words|
      next false if words.nil? || words.empty?
      all_rare = words.all? { |w| word_dict_frequency_for_rime_bucket(word_dict, w) <= RARE_FREQ_MAX }
      one_common_pref_mixed = rime_bucket_one_common_preferred_with_any_rare?(words, word_dict)
      drop = all_rare || one_common_pref_mixed
      if drop
        removed += 1
        rime_dict_trace_partner_loss!(rdict, rime, words, nil, reason: :rare_only_or_one_common_pref_mixed, round: round_id)
      end
      drop
    end
    if log && removed > 0
      puts "#{rdict.length} out of #{before_n} rime buckets remain after removing rare-only and one-common-preferred+mixed buckets"
    end
    removed
  end
end

def rime_bucket_common_headwords(words, word_dict)
  words.select { |w| word_dict_frequency_for_rime_bucket(word_dict, w) > RARE_FREQ_MAX }
end

# True if +a+ and +b+ have some pairing of pronunciations for +rime+ that counts as a non-rich rhyme.
def non_rich_rime_pair_exists_for_rime?(a, b, rime, word_dict)
  ea = word_dict[a]
  eb = word_dict[b]
  return false if ea.nil? || eb.nil?
  return false if word_dict_entry_tombstoned?(ea) || word_dict_entry_tombstoned?(eb)
  pr_a = ea[1]
  pr_b = eb[1]
  return false if pr_a.nil? || pr_b.nil?

  pr_a.each do |pa|
    next unless pa.rime == rime
    return true unless headword_rich_rhyme?(b, pa.rich_rime_array, rime, word_dict)
  end
  pr_b.each do |pb|
    next unless pb.rime == rime
    return true unless headword_rich_rhyme?(a, pb.rich_rime_array, rime, word_dict)
  end
  false
end

# True when there are ≥2 common headwords and every unordered pair is a rich rhyme for this +rime+.
def all_common_headwords_rich_rhyme_for_rime?(rime, words, word_dict)
  common = rime_bucket_common_headwords(words, word_dict)
  return false if common.size < 2

  common.combination(2) do |a, b|
    return false if non_rich_rime_pair_exists_for_rime?(a, b, rime, word_dict)
  end
  true
end

# After rare/mixed pruning: drop buckets where all common–common rhyme links are rich rhymes (+homophone_ok=false+
# would find no partner within the common subset). Skipped when +INCLUDE_RICH_RHYMES+ is true.
# Same rdict-reads-during-prune wrap as +delete_rare_only_rime_buckets!+.
def delete_common_rich_only_rime_buckets!(rdict, word_dict, log: true)
  return 0 if INCLUDE_RICH_RHYMES

  rime_dict_with_reads_during_prune(rdict) do
    removed = 0
    round_id = rdict.respond_to?(:pruning_active?) && rdict.pruning_active? ? "prune" : "pre"
    before_n = rdict.length
    rdict.delete_if do |rime, words|
      next false if words.nil? || words.empty?
      next false unless all_common_headwords_rich_rhyme_for_rime?(rime, words, word_dict)

      removed += 1
      rime_dict_trace_partner_loss!(rdict, rime, words, nil, reason: :common_rich_only, round: round_id)
      true
    end
    if log && removed > 0
      puts "#{rdict.length} out of #{before_n} rime buckets remain after removing common-rich-only buckets (INCLUDE_RICH_RHYMES is off)"
    end
    removed
  end
end

def filter_cmudict(cmudict, rdict)
  # filter out words that differ only in apostrophes, and pronunciations with no rhymes
  filtered_cmudict = Hash.new
  proncount = 0
  total = 0
  for word, prons in cmudict
    filtered_cmudict[word] = Array.new # we still want entries for words with no pronunciations, though, in case they have frequency data
    dict_trace_puts(word, "prons = #{prons}") if dict_trace_word?(word)
    for pron in prons
      total += 1
      rime = pron.rime
      if(!rdict[rime].empty?)
        proncount += 1
        filtered_cmudict[word].push(pron)
        dict_trace_puts(word, "#{pron} passed filters; rime bucket = #{rdict[rime]}") if dict_trace_word?(word)
      end
    end
  end
  puts "#{proncount} out of #{total} pronunciations remain in the dictionary after removing pronunciations with no rhymes"
  return filtered_cmudict
end

# Parallels +homophone_rhyme?+ in crime.rb (with rich-rime-only matching, not full-phoneme): true when every +target_rime+ pronunciation of +rhyme_word+ matches +target_rich_rime_array+,
# or when there is no such pronunciation (vacuous; candidate is filtered out for homophone_ok=false).
def headword_rich_rhyme?(rhyme_word, target_rich_rime_array, target_rime, word_dict)
  entry = word_dict[rhyme_word]
  prons = entry ? entry[1] : nil
  return true if prons.nil? || prons.empty?
  prons.each do |pron|
    next unless pron.rime == target_rime
    return false if pron.rich_rime_array != target_rich_rime_array
  end
  true
end

# True if +word+ has at least one rime-bucket partner treated as a non-rich rhyme (+find_rhyming_words(..., false)+).
# Wraps its rdict reads in +with_reads_during_prune+ so it's an authorized
# reader inside the disconnect-filter pruning window. Outside the window the
# wrapper is inert.
def headword_has_non_rich_rhyme_partner?(word, prons, rdict, word_dict)
  return false if prons.nil? || prons.empty?

  rime_dict_with_reads_during_prune(rdict) do
    word_pf = preferred_form_in_build_lexicon(word, word_dict)
    seen = {}
    prons.each do |pron|
      rime = pron.rime
      next if rime.empty?
      rich_rime_array = pron.rich_rime_array
      key = [rime, rich_rime_array]
      next if seen[key]

      seen[key] = true
      (rdict[rime] || []).each do |other|
        next if preferred_form_in_build_lexicon(other, word_dict) == word_pf
        next if headword_rich_rhyme?(other, rich_rime_array, rime, word_dict)
        return true
      end
    end
    false
  end
end

# Logical predicate: is +word+ eligible to be a compute/DDB cue (the PK of a
# +related#<lemma>+ row)?
#
# Broader than +relatedness_target_word?+: cue coverage must include every
# lemma a user might ask about at runtime (or a spec fixture references), even
# rhymeless ones (+music+, +concerto+, +algebra+, +quarterback+). Those lemmas
# can't appear as a _related_ in another cue's row (no rhyme to attach to),
# but they're perfectly valid questions on the cue side.
#
# Physical implementation today: +word_common_preferred_headword?+. Keep this
# wrapper so compute, eval scripts, and build-time stats all agree on what
# "cue" means — and so widening the cue set later (e.g. to include dispreferred
# forms a user might type) only requires a change here.
def cue_word?(word, word_dict)
  word_common_preferred_headword?(word, word_dict)
end

# Logical predicate: is +word+ eligible to appear as a related in another cue's
# row, or to be returned in a related-words response to the UI?
#
# Strict superset of +cue_word?+: every relatedness target is a valid cue, but
# some cues (rhymeless lemmas) are not targets. The extra criterion is a
# non-rich rhyme partner in +rdict+ — without one the word would never
# surface in the UI even if it were included in a list.
def relatedness_target_word?(word, word_dict, rdict)
  return false unless cue_word?(word, word_dict)
  prons = word_dict[word]&.dig(1)
  headword_has_non_rich_rhyme_partner?(word, prons, rdict, word_dict)
end

# Drop rime-bucket members not in +allowed+; remove singleton buckets (same invariant as +merge_word_dict_pronunciations_into_rdict!+).
# Runs inside the +filter_word_dict_disconnected!+ pruning window on every
# fixed-point round, so its +rdict.each+ iteration is wrapped in
# +with_reads_during_prune+ (no-op outside the window).
def prune_rdict_to_headwords!(rdict, allowed)
  allowed = allowed.to_set if allowed.is_a?(Array)
  rime_dict_with_reads_during_prune(rdict) do
    round_id = rdict.respond_to?(:pruning_active?) && rdict.pruning_active? ? "prune" : "pre"
    rdict.each do |rime, words|
      before_words = words.dup if rime_dict_bucket_has_trace_word?(words)
      words.reject! { |w| !allowed.include?(w) }
      if before_words
        dropped = before_words - words
        dropped.each do |y|
          rime_dict_trace_partner_loss!(rdict, rime, words, y, reason: :not_in_allowed_headwords, round: round_id)
        end
      end
    end
    rdict.reject! { |rime, words|
      drop = words.nil? || words.length <= 1
      if drop && words && rime_dict_bucket_has_trace_word?(words)
        rime_dict_trace_partner_loss!(rdict, rime, words, nil, reason: :singleton_bucket_after_prune, round: round_id)
      end
      drop
    }
    rdict
  end
end

# Small helper: invoke +rdict.with_reads_during_prune { block }+ when +rdict+
# is a +RimeDict+; otherwise just yield. Called by every authorized reader
# of rdict during the disconnect-filter window. Keeps the read-guard plumbing
# out of the hot-path code bodies.
def rime_dict_with_reads_during_prune(rdict)
  if rdict.respond_to?(:with_reads_during_prune)
    rdict.with_reads_during_prune { yield }
  else
    yield
  end
end

# True iff +words+ (a rime-bucket array) contains at least one +dict_trace_word?+.
# Used by the pruners below to gate per-round partner-loss logging: logging
# costs the corpus at large nothing (short-circuit on non-trace-words), and
# a contributor debugging a specific trace word gets round-by-round
# attribution of bucket changes "for free" when the word is in +DICT_TRACE_WORDS+.
def rime_dict_bucket_has_trace_word?(words)
  return false if words.nil?
  words.any? { |w| dict_trace_word?(w) }
end

# Emit a +dict_trace_puts+ line describing a per-round rdict bucket change
# (partner +y+ removed from bucket +rime+, or +y+=nil when the whole bucket
# was dropped). No-op when the bucket has no trace words in it.
def rime_dict_trace_partner_loss!(_rdict, rime, words, y, reason:, round:)
  return unless rime_dict_bucket_has_trace_word?(words)
  words.each do |w|
    next unless dict_trace_word?(w)
    if y
      dict_trace_puts(w, "rdict prune [round=#{round}]: rime=#{rime} partner=#{y} removed (reason=#{reason}); surviving=#{words.inspect}")
    else
      dict_trace_puts(w, "rdict prune [round=#{round}]: rime=#{rime} bucket dropped (reason=#{reason}); members=#{words.inspect}")
    end
  end
end
