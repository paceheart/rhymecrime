# encoding: utf-8
#
# Build-time per-headword accumulator used by the rarity pipeline in
# +frequency.rb+. Replaces the legacy +[freq, prons]+ pair that +word_dict+
# used to carry during the build, so every phase that touches a headword can
# append structured tags (freq decisions, donor lineage, clamp / boost
# history, tombstoned reasons) onto the entry itself rather than
# mutating +entry[0]+ in place or calling +hash.delete+ mid-pipeline.
#
# The rest of the codebase still sees +[freq, prons, lemma]+: the terminal
# reducer (+finalize_build_entries!+) projects each surviving +BuildEntry+
# back onto that positional array right before +build_word_dict+ returns.
# During the build, positional compatibility is preserved via
# +BuildEntry#[]+ / +#dig+ / +#to_ary+ delegation so the ~hundred call sites
# that read +entry[0]+ / +entry[1]+ or destructure +freq, prons = entry+
# continue to work unmodified.
#
# Four structured records are attached to a +BuildEntry+:
#
#   FreqTag         append_freq_tag! appends one per phase that touches the
#                   running freq; records pre_freq / post_freq / donor /
#                   donor_anchored / per-gate outcomes / a metadata_only flag
#                   (phase-2 decoupled from phase-3 in morph_inherit_kaikki).
#   FreqComputation compute_frequency_structured returns one; carries the
#                   raw SUBTLEX / wordfreq / WordNet inputs, the pre-clamp
#                   subtlex_freq / wordfreq_boost values, the ordered list
#                   of ClampRecords applied, and the final integer freq.
#   ClampRecord     each clamp / boost decision inside compute_frequency
#                   becomes one entry with a symbol reason, pre value, and
#                   post value.
#   DeletionTag     mark_tombstoned! sets one (and only one — first
#                   write wins so the scrub that first noticed the headword
#                   gets credit); carries the phase, the reason, and a
#                   per-reason detail hash (stem freq for possessive scrub,
#                   WN lexnames for hyphenated-proper scrub, classifier
#                   score for :forbidden verdicts, has_rhyme + round for
#                   disconnect, …).
#
# +RimeDict+ lives in this file too: it's a +Hash+ subclass whose read
# methods consult a per-instance pruning-active flag so a naive +rdict[rime]+
# from a future contributor can't silently read the half-pruned rdict
# during +filter_word_dict_disconnected!+'s fixed-point loop. Authorized
# readers (the three rdict pruners and +headword_has_nonidentical_rhyme_partner?+)
# wrap their bodies in +rdict.with_reads_during_prune { ... }+; the
# disconnect loop itself runs inside +rdict.with_pruning_active { ... }+.
#
# See plan +defer-rarity-losses_refactor+ for the migration choreography
# and parity constraints.

require "set"

FreqTag = Struct.new(
  :phase,           # Symbol; one of the phase names below (see +RARITY_FREQ_SOURCE_PHASES+)
  :pre_freq,        # Integer; entry[0] before this phase's write
  :post_freq,       # Integer; entry[0] after this phase's write
  :donor,           # String or nil; donor surface form for morph / g-drop phases
  :donor_anchored,  # Boolean; corpus-only anchor predicate (see donor_has_corpus_anchor?)
  :gate_outcomes,   # Hash or nil; per-gate named outcomes (suffix_kind, surf_ok, …)
  :metadata_only,   # Boolean; true when phase 2 ran (lineage recorded) but phase 3 didn't (freq unchanged)
  keyword_init: true,
)

ClampRecord = Struct.new(
  :reason,  # Symbol; the named gate or clamp branch inside compute_frequency
  :pre,     # numeric or Boolean — value before the clamp
  :post,    # numeric or Boolean — value after the clamp
  keyword_init: true,
)

FreqComputation = Struct.new(
  :word,
  :subtlex_raw,                 # SUBTLEX FREQlow (Integer)
  :subtlex_total,               # SUBTLEX total across case variants (Integer)
  :zipf,                        # wordfreq Zipf (Float or Integer; 0 when OOV)
  :cap_ratio,                   # SUBTLEX capitalized ratio (Float or nil)
  :wn_in,                       # WordNet entry? (Boolean)
  :wn_synset_count,             # Integer
  :wn_all_proper,               # Boolean
  :kaikki_paradigm,             # morph_kaikki_lists_surface_as_inflected_nonlemma? (Boolean)
  :subtlex_freq_pre,            # subtlex_frequency before clamps (Integer)
  :wordfreq_boost_pre,          # wordfreq_boost before clamps (Integer)
  :applied_clamps,              # Array[ClampRecord]; ordered by application
  :final_freq,                  # Integer; what compute_frequency returns
  keyword_init: true,
)

DeletionTag = Struct.new(
  :phase,    # Symbol; one of +:possessive_scrub+, +:invariant_plural_scrub+,
             # +:hyphenated_proper_scrub+, +:forbidden_scrub+, +:unrhymable_scrub+,
             # +:gdrop_strip+, +:edge_hyphen_scrub+, +:disconnect+, +:classifier+
  :reason,   # Symbol; more granular than phase (e.g. +:stem_freq_zero+,
             # +:no_rhyme_partner_no_rescue+, +:forbidden_verdict+, +:shadowed_by_apostrophe_form+)
  :detail,   # Hash or nil; per-reason context (stem_freq, lexnames, classifier_score,
             # has_rhyme, round, …)
  keyword_init: true,
)

# Integer marker for the "no freq yet" state used as the initial +pre_freq+
# of the first FreqTag a fresh BuildEntry receives. Chosen to sort below any
# real freq; derive_freq never observes it (the first tag's post_freq
# supersedes it immediately).
BUILD_ENTRY_INITIAL_FREQ = 0

class BuildEntry
  attr_reader :word, :freq_tags, :tombstoned
  attr_accessor :prons, :lemma, :freq_computation, :rarity_signals

  # Constructed once per headword. Freq starts at 0; the first phase that
  # touches the entry (CMU seed, SUBTLEX expansion, common-list floor, …)
  # appends a FreqTag that bumps +@derived_freq+ to its +post_freq+.
  def initialize(word:, freq: BUILD_ENTRY_INITIAL_FREQ, prons: [], lemma: nil)
    @word = word
    @prons = prons
    @lemma = lemma
    @derived_freq = freq.to_i
    @freq_tags = []
    @freq_computation = nil
    @rarity_signals = nil
    @tombstoned = nil
  end

  # Running freq after the most recent non-metadata-only FreqTag. Kept as a
  # field rather than a scan-the-tags computation because every phase reads
  # the freq on every other headword (donor freqs) in its hot loop; scanning
  # the tag list on each read would be O(n_tags) per read and change the
  # asymptotics of the build.
  def derived_freq
    @derived_freq
  end

  # Positional accessor used by the hundred-ish legacy call sites that read
  # +entry[0]+ / +entry[1]+ / +entry[2]+ / +entry.dig(0)+ / +entry.dig(1)+.
  # Keeps the BuildEntry drop-in for the existing +[freq, prons, lemma]+
  # shape during the phase-by-phase migration.
  def [](i)
    case i
    when 0 then @derived_freq
    when 1 then @prons
    when 2 then @lemma
    end
  end

  # Legacy-compat writer. Kept for the small set of in-build code that still
  # writes +entry[0] = X+ directly (e.g. corpus_variants.rb surface-emission
  # pron-attachment branches that land on BuildEntry values during build).
  # Does NOT append a FreqTag — phases that run through +add_frequency_info+
  # should always call +append_freq_tag!+ for that. +entry[1] = prons+ and
  # +entry[2] = lemma+ are routine during the build.
  def []=(i, v)
    case i
    when 0 then @derived_freq = v.to_i
    when 1 then @prons = v
    when 2 then @lemma = v
    else raise ArgumentError, "BuildEntry positional index out of range: #{i}"
    end
  end

  # +#dig+ for the +entry&.dig(1)+ style used heavily in rime.rb and
  # corpus_variants.rb. Delegates through +[](i)+ so callers can then dig
  # into the prons array or lemma string.
  def dig(*args)
    idx, *rest = args
    v = self[idx]
    return v if rest.empty?
    return nil if v.nil?
    v.respond_to?(:dig) ? v.dig(*rest) : nil
  end

  # +#to_a+ / +#to_ary+ enable +freq, prons = entry+ destructuring and
  # +word_dict.each do |word, (freq, _)|+ nested-block destructuring. Must
  # mirror the legacy +[freq, prons, lemma]+ array for positional parity.
  def to_a
    [@derived_freq, @prons, @lemma]
  end
  alias_method :to_ary, :to_a

  def first
    self[0]
  end

  def last
    to_a.last
  end

  # Append a structured FreqTag for a phase that just touched this headword.
  # Updates +@derived_freq+ to +post_freq+ unless +metadata_only+ is set, in
  # which case the tag records the donor lineage but the running freq stays
  # put (matches the phase-2/phase-3 split in +morph_inherit_kaikki+ where a
  # surface can have its lineage recorded without its freq changing).
  def append_freq_tag!(phase:, post_freq:, pre_freq: nil, donor: nil, donor_anchored: false, gate_outcomes: nil, metadata_only: false)
    pre = pre_freq.nil? ? @derived_freq : pre_freq.to_i
    tag = FreqTag.new(
      phase: phase,
      pre_freq: pre,
      post_freq: post_freq.to_i,
      donor: donor,
      donor_anchored: !!donor_anchored,
      gate_outcomes: gate_outcomes,
      metadata_only: !!metadata_only,
    )
    @freq_tags << tag
    @derived_freq = post_freq.to_i unless metadata_only
    tag
  end

  # First writer wins: the earliest scrub / filter / classifier pass that
  # decided the headword should come out sets the DeletionTag. Later passes
  # that also want to delete leave the original reason intact (their visit
  # shows up in +freq_tags+ / trace output but doesn't overwrite the "who
  # first claimed this row" provenance). Returns +self+ for chaining.
  def mark_tombstoned!(phase:, reason:, detail: nil)
    @tombstoned ||= DeletionTag.new(phase: phase, reason: reason, detail: detail)
    self
  end

  def tombstoned?
    !@tombstoned.nil?
  end

  # Latest non-metadata-only FreqTag's phase, for consumers that want the
  # provenance slot that +record_freq_propagation!+ used to write. Falls
  # back to +:unknown+ when no non-metadata-only tag exists, matching the
  # default initializer used by +RaritySignals+.
  def latest_freq_source_phase
    (@freq_tags.reverse.find { |t| !t.metadata_only } || @freq_tags.last)&.phase || :unknown
  end

  # Latest donor (if any). Same policy as +latest_freq_source_phase+.
  def latest_donor
    @freq_tags.reverse.find { |t| !t.metadata_only && t.donor }&.donor
  end

  # True iff any FreqTag on this entry fires +donor_anchored+. Matches the
  # semantics of the legacy +received_donor_from_common_base_flag+ feature
  # (once set, stays set — multiple inheritance passes don't unset).
  def any_donor_anchored?
    @freq_tags.any? { |t| t.donor_anchored }
  end

  # Debug / trace hook — never called in the hot path.
  def inspect
    "#<BuildEntry word=#{@word.inspect} freq=#{@derived_freq} prons=#{@prons&.size} tags=#{@freq_tags.size} pending=#{@tombstoned&.reason.inspect}>"
  end
end

# +RimeDict+: a +Hash+ subclass that refuses unauthorized reads during a
# +with_pruning_active { ... }+ window. "Read" means +[]+, +fetch+, +dig+,
# +key?+ / +has_key?+ / +include?+ / +member?+, iteration (+each+,
# +each_pair+, +each_key+, +each_value+), keys / values extraction (+keys+,
# +values+, +values_at+, +to_a+, +to_h+), functional operations (+select+,
# +map+, +reduce+, +any?+, +all?+, +none?+, +count+, +find+, +detect+,
# +filter+, +sum+), and size queries (+size+, +length+, +empty?+).
#
# Mutations (+[]=+, +delete+, +delete_if+, +reject!+, +select!+, +clear+,
# +merge!+, +replace+) are intentionally NOT guarded — the three pruners
# inside +filter_word_dict_disconnected!+ need to mutate, and Ruby's
# mutating-method C implementations don't always route through +[]+ / +each+
# anyway. The guard's purpose is to catch a naive new caller that reads
# rdict during the window without realizing it's in an inconsistent
# intermediate state; mutations from outside the pruning window aren't in
# scope for this refactor (rdict has existing mutation points before and
# after the disconnect loop — +build_rime_dict+,
# +merge_word_dict_pronunciations_into_rdict!+,
# +strip_dispreferred_headwords_from_rdict!+, the two pre-disconnect
# bucket pruners, and +prune_obsolete_alt_of_only_headwords!+ post-build —
# and all of them run with +pruning_active?+ false).
class RimeDict < Hash
  READ_METHODS_GUARDED = %i[
    [] fetch dig
    key? has_key? include? member?
    each each_pair each_key each_value
    keys values values_at
    to_a to_h
    select map collect filter reduce inject
    any? all? none? count
    find detect
    size length empty?
    sum min max min_by max_by sort sort_by group_by partition
    first flat_map take drop each_with_index each_with_object
  ].freeze

  def initialize(*args, &default)
    super
    @pruning_active = false
    @reads_during_prune_depth = 0
  end

  def pruning_active?
    @pruning_active
  end

  # Scope block for the disconnect filter's fixed-point loop. Any read from
  # outside +with_reads_during_prune+ raises while this block is running.
  # Raises on re-entry so we can't accidentally nest two "I am pruning" contexts.
  def with_pruning_active
    raise "RimeDict pruning already active (re-entered)" if @pruning_active
    @pruning_active = true
    yield self
  ensure
    @pruning_active = false
    @reads_during_prune_depth = 0
  end

  # Scope block for an authorized reader inside the pruning window (the
  # three pruners and +headword_has_nonidentical_rhyme_partner?+). Stackable
  # (nested opt-ins are fine — the counter increments / decrements).
  def with_reads_during_prune
    @reads_during_prune_depth += 1
    yield self
  ensure
    @reads_during_prune_depth -= 1
  end

  READ_METHODS_GUARDED.each do |m|
    define_method(m) do |*args, &blk|
      __rimedict_read_guard__(m)
      super(*args, &blk)
    end
  end

  private

  def __rimedict_read_guard__(method_name)
    return unless @pruning_active
    return if @reads_during_prune_depth > 0
    loc = caller_locations(2, 1).first
    site = loc ? "#{loc.path}:#{loc.lineno} in `#{loc.label}`" : "(unknown)"
    raise(
      "RimeDict##{method_name} called during the disconnect-filter pruning window " \
      "without rdict.with_reads_during_prune { ... } opt-in — rdict state is " \
      "intentionally inconsistent mid-loop. Caller: #{site}. If this is an " \
      "authorized reader, wrap its body in with_reads_during_prune; if it's " \
      "a new contributor adding an rdict read inside the window, consider " \
      "whether rdict's post-pruning state is what you really want and defer " \
      "the read until after filter_word_dict_disconnected! returns."
    )
  end
end

# Wrap +rdict_or_hash+ (a plain +Hash+) in a +RimeDict+ carrying the same
# entries. Used at the +build_rime_dict+ boundary so the rest of the build
# sees a guarded +rdict+. No-op when the input is already a +RimeDict+.
def wrap_as_rime_dict(rdict_or_hash)
  return rdict_or_hash if rdict_or_hash.is_a?(RimeDict)
  out = RimeDict.new
  out.replace(rdict_or_hash)
  out
end

# Terminal reducer: projects every surviving +BuildEntry+ in +hash+ back
# onto the legacy +[freq, prons, lemma]+ array shape that +save_word_dict+,
# +save_word_dict_msgpack!+, and the downstream +rebuild_rhymecrime_dictionaries+
# steps expect. Drops entries whose +tombstoned+ has been set.
#
# Emits a single consolidated summary of counts-by-reason, replacing the
# scattered per-phase "puts" lines (which are non-contractual; nothing
# downstream parses them).
def finalize_build_entries!(hash)
  deletion_counts = Hash.new(0)
  kept = 0
  pending_keys = []
  hash.each_pair do |word, entry|
    if entry.is_a?(BuildEntry) && entry.tombstoned?
      del = entry.tombstoned
      key = [del.phase, del.reason]
      deletion_counts[key] += 1
      pending_keys << word
    else
      kept += 1
    end
  end
  pending_keys.each { |w| hash.delete(w) }
  hash.each_pair do |word, entry|
    if entry.is_a?(BuildEntry)
      hash[word] = entry.to_a
    end
  end
  if deletion_counts.any?
    puts "finalize_build_entries!: #{pending_keys.size} tombstoned entries removed (#{kept} kept):"
    deletion_counts
      .sort_by { |(phase, reason), _| [phase.to_s, reason.to_s] }
      .each do |(phase, reason), n|
        puts "  - #{phase}/#{reason}: #{n}"
      end
  end
  hash
end

# Convenience helper: returns the live set of headword keys in +word_dict+,
# excluding entries whose +tombstoned+ is set. Used by the disconnect
# loop and its rdict pruners during the tag-deferred deletion window (when
# entries are still in +word_dict+ but logically gone).
def live_word_dict_keys(word_dict)
  out = []
  word_dict.each_pair do |word, entry|
    next if entry.is_a?(BuildEntry) && entry.tombstoned?
    out << word
  end
  out
end
