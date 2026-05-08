# encoding: utf-8
#
# Rarity scoring (rarity-pipeline stage 2): machine-learned scorer over RaritySignals.
#
# Reads generated/rarity_classifier.json (produced by bin/train-rarity-classifier)
# and maps a signals struct to one of :common / :rare / :forbidden plus an integer
# freq in {0, 2, 10} that downstream preference-ordering code compares.
#
# Strict-load policy: when the classifier JSON is missing or its feature-name list
# disagrees with LEARNED_RARITY_FEATURE_NAMES, rarity_classifier raises rather
# than silently no-op'ing. A degraded build is worse than a loud failure — the
# rule-based combiner that used to take over had ~3% lower top-line accuracy on
# curated/rarity.csv and quietly shipped that delta.
#
# Two explicit bootstrap escapes for the chicken-and-egg case (the trainer reads a
# classifier dump that ./bin/dict-build produces, so the very first build can't
# have a classifier yet):
#
#   RHYMECRIME_RARITY_CLASSIFIER=off       no rescore (rule-based path runs)
#   RHYMECRIME_RARITY_DUMP_SIGNALS=PATH    same, plus emit a feature dump for the
#                                          trainer to consume
#
# Either one fires rarity_classifier_disabled?, which short-circuits the load
# before the file-existence check; any other invocation against a missing classifier
# is a hard error with a remediation hint. The standard end-to-end build script
# (bin/build) sets RHYMECRIME_RARITY_DUMP_SIGNALS for Build Stage 1/4 and
# then runs bin/train-rarity-classifier as Build Stage 2/4, so a fresh
# checkout reaches steady state without the operator having to think about
# either env var.
#
# Two supported training targets (selected at train time and stored in the JSON
# as target):
#
#   3class     — 3-way softmax over {common, rare, forbidden}; one-vs-rest
#                binary classifiers per class (logreg or GBT), softmax over
#                logits at inference, argmax is the label.
#   regressor  — single scalar target (0=forbidden, 2=rare, 10=common); two
#                thresholds t_forbidden_rare and t_rare_common partition
#                the predicted score. GBT-only (logreg has been ablated; it
#                consistently lost to 3class on cross-validated weighted
#                accuracy and isn't worth the inference path).
#
# learned_rarity_feature_vector / LEARNED_RARITY_FEATURE_NAMES are the same
# ordered list of feature names the trainer emits to the JSON.

require "json"
require "fileutils"
require_relative "rarity_signals"
require_relative "rarity_curated_overrides"
require_relative "build_utils"
require_relative "constants"

# Keep in lock-step with bin/train-rarity-classifier. The JSON records its own
# feature-name list so mismatches are detected at load.
#
# common_words_flag and rare_words_flag are intentionally NOT in this list
# even though RaritySignals still computes them: they're sourced from the same
# curated/rarity.csv rows the trainer turns into labels, so feeding them as
# features made the classifier a label-leak lookup table (5-fold CV at 99.7%
# with GBT and logreg posting byte-identical fold scores). The flags remain on
# RaritySignals for any non-classifier consumers; the trainer just doesn't
# get to see them.
LEARNED_RARITY_FEATURE_NAMES = %w[
  bias
  wordfreq_zipf
  subtlex_freqlow
  subtlex_total
  subtlex_cap_ratio_present
  subtlex_cap_ratio
  pronunciation_map_original_flag
  conceptnet_flag
  numberbatch_flag
  usf_flag
  neol_flag
  semantically_promiscuous_flag
  wiktionary_words_flag
  wn_entry_flag
  wn_synset_count
  wn_lemma_count
  wn_all_proper_flag
  wn_has_noun_flag
  wn_has_verb_flag
  wn_has_adj_flag
  usf_out_degree
  cn_degree
  cn_adjacency_loaded_flag
  word_len
  two_letter_alpha_flag
  four_letter_alpha_flag
  likely_proper_noun_by_case_flag
  pos_tag_count
  pos_has_noun_flag
  pos_has_verb_flag
  pos_has_adj_flag
  pos_has_intj_flag
  pos_all_function_word_flag
  post_propagation_freq
  log_post_propagation_freq
  is_rare_by_freq_flag
  freq_source_phase_index
  received_donor_from_common_base_flag
].freeze

def _rf(b)
  b ? 1.0 : 0.0
end

def learned_rarity_feature_vector(sig)
  cap_ratio_present = !sig.subtlex_cap_ratio.nil?
  cap_ratio_val = cap_ratio_present ? sig.subtlex_cap_ratio.to_f : 0.0

  ppf = (sig.post_propagation_freq || 0).to_f
  log_ppf = Math.log10(ppf + 1.0)
  is_rare_by_freq = ppf > 0 && ppf <= RARE_FREQ_MAX

  [
    1.0,
    sig.wordfreq_zipf.to_f,
    sig.subtlex_freqlow.to_f,
    sig.subtlex_total.to_f,
    _rf(cap_ratio_present),
    cap_ratio_val,
    _rf(sig.pronunciation_map_original_flag),
    _rf(sig.conceptnet_flag),
    _rf(sig.numberbatch_flag),
    _rf(sig.usf_flag),
    _rf(sig.neol_flag),
    _rf(sig.semantically_promiscuous_flag),
    _rf(sig.wiktionary_words_flag),
    _rf(sig.wn_entry_flag),
    sig.wn_synset_count.to_f,
    sig.wn_lemma_count.to_f,
    _rf(sig.wn_all_proper_flag),
    _rf(sig.wn_has_noun_flag),
    _rf(sig.wn_has_verb_flag),
    _rf(sig.wn_has_adj_flag),
    sig.usf_out_degree.to_f,
    sig.cn_degree.to_f,
    _rf(sig.cn_adjacency_loaded_flag),
    sig.word_len.to_f,
    _rf(sig.two_letter_alpha_flag),
    _rf(sig.four_letter_alpha_flag),
    _rf(sig.likely_proper_noun_by_case_flag),
    sig.pos_tag_count.to_f,
    _rf(sig.pos_has_noun_flag),
    _rf(sig.pos_has_verb_flag),
    _rf(sig.pos_has_adj_flag),
    _rf(sig.pos_has_intj_flag),
    _rf(sig.pos_all_function_word_flag),
    ppf,
    log_ppf,
    _rf(is_rare_by_freq),
    rarity_freq_source_to_index(sig.freq_source_phase).to_f,
    _rf(sig.received_donor_from_common_base_flag),
  ]
end

RARITY_CLASSIFIER_FILENAME = "rarity_classifier.json"

# Prefer runtime/ (canonical after bin/build cp), then bootstrap/ (trainer output),
# then generated/current/ for pre-stamped checkouts.
def rarity_classifier_json_path
  bd = rhymecrime_build_dir
  if bd
    rt = generated_runtime_path(RARITY_CLASSIFIER_FILENAME)
    return rt if File.exist?(rt)
    boot = generated_bootstrap_path(RARITY_CLASSIFIER_FILENAME)
    return boot if File.exist?(boot)
  end
  generated_dict_path(RARITY_CLASSIFIER_FILENAME)
end

$rarity_classifier = nil
$rarity_classifier_loaded = false

def rarity_classifier_disabled?
  v = ENV["RHYMECRIME_RARITY_CLASSIFIER"]
  return true if v && %w[off 0 false no disabled].include?(v.downcase)
  # Bootstrap mode: dumping signals to feed the trainer. The classifier doesn't
  # exist yet by definition, so suppress the strict-load error.
  dump = ENV["RHYMECRIME_RARITY_DUMP_SIGNALS"]
  return true if dump && !dump.empty?
  false
end

def rarity_classifier
  return $rarity_classifier if $rarity_classifier_loaded
  $rarity_classifier_loaded = true
  return nil if rarity_classifier_disabled?
  path = rarity_classifier_json_path
  unless File.exist?(path)
    raise "rarity classifier not found at #{path}. Train it via:\n" \
          "  ./bin/build                                     # full four-Build-Stage pipeline (dump + train + relatedness)\n" \
          "or just the rarity steps manually:\n" \
          "  RHYMECRIME_RARITY_DUMP_SIGNALS=<path> ./bin/dict-build\n" \
          "  ./bin/train-rarity-classifier\n" \
          "Or set RHYMECRIME_RARITY_CLASSIFIER=off to skip rescore."
  end

  clf = JSON.parse(BuildIo.read(path, encoding: "UTF-8", hint: "rarity_classifier"))
  got = clf["feature_names"]
  expected = LEARNED_RARITY_FEATURE_NAMES
  unless got == expected
    raise "rarity classifier feature-name mismatch in #{path}: got=#{got.inspect} expected=#{expected.inspect}. " \
          "Retrain via ./bin/train-rarity-classifier."
  end

  _rarity_compile_classifier!(clf)

  $rarity_classifier = clf
  type = clf["model_type"] || "unknown"
  target = clf["target"] || "unknown"
  puts "loaded rarity classifier from #{path} (target=#{target} type=#{type})"
  $rarity_classifier
end

def _rarity_tree_predict(nodes, row)
  idx = 0
  loop do
    n = nodes[idx]
    return n["v"] if n.key?("v")
    idx = row[n["f"]] <= n["t"] ? n["l"] : n["r"]
  end
end

# Compiled representation of one GBT tree: a single flat Array with 4 slots per node,
# laid out contiguously at base = node_index * 4:
#   [base+0] feature index (Integer), or -1 to mark a leaf
#   [base+1] threshold (Float), OR leaf value when +[base+0] == -1+
#   [base+2] pre-multiplied base offset of the left child  (child_index * 4)
#   [base+3] pre-multiplied base offset of the right child (child_index * 4)
#
# The JSON-on-disk form is an Array of Hashes with string keys — fine for the trainer but
# the per-node hot-loop cost in dict-build was 5 hash probes per traversal step, and
# stackprof showed _rarity_tree_predict at ~46% of total CPU on a full build. Collapsing
# each tree to one flat Array with pre-multiplied child offsets means every node traversal
# does at most 3 Array#[] lookups and 1 row#[] lookup (no hash probes, no multiplies,
# no per-call destructuring).
def _rarity_compile_tree(nodes)
  n = nodes.length
  flat = Array.new(n * 4)
  nodes.each_with_index do |h, i|
    b = i * 4
    if h.key?("v")
      flat[b]     = -1
      flat[b + 1] = h["v"].to_f
      flat[b + 2] = 0
      flat[b + 3] = 0
    else
      flat[b]     = h["f"].to_i
      flat[b + 1] = h["t"].to_f
      flat[b + 2] = h["l"].to_i * 4
      flat[b + 3] = h["r"].to_i * 4
    end
  end
  flat
end

def _rarity_tree_predict_compiled(flat, row)
  b = 0
  loop do
    f = flat[b]
    return flat[b + 1] if f < 0
    b = row[f] <= flat[b + 1] ? flat[b + 2] : flat[b + 3]
  end
end

# Replace model["trees"] with a compiled form (model["trees_c"]) and cache bias/lr as
# floats (model["bias_f"] / model["lr_f"]). Idempotent. Leaves the original "trees"
# intact so introspection / re-serialization still works.
def _rarity_maybe_compile_gbt_model!(model)
  return unless model.is_a?(Hash)
  return unless model["trees"].is_a?(Array)
  return if model["trees_c"]
  model["bias_f"]  = model["bias"].to_f
  model["lr_f"]    = model["lr"].to_f
  model["trees_c"] = model["trees"].map { |t| _rarity_compile_tree(t) }
end

# Walk a loaded classifier and compile every GBT model we'll evaluate in the hot path.
def _rarity_compile_classifier!(clf)
  type = clf["model_type"]
  case clf["target"]
  when "3class"
    return unless type == "gbt"
    per_class = clf["models"] || {}
    per_class.each_value { |m| _rarity_maybe_compile_gbt_model!(m) }
  when "regressor"
    _rarity_maybe_compile_gbt_model!(clf)
  end
end

def _rarity_logreg_binary_margin(feats, model)
  means = model["means"]
  stds  = model["stds"]
  w     = model["weights"]
  z = 0.0
  feats.each_with_index do |v, i|
    if i.zero?
      x = v
    else
      s = stds[i]
      x = s > 1e-12 ? (v - means[i]) / s : 0.0
    end
    z += w[i] * x
  end
  z
end

def _rarity_gbt_binary_margin(feats, model)
  trees_c = model["trees_c"]
  if trees_c
    score = model["bias_f"]
    lr = model["lr_f"]
    trees_c.each { |t| score += lr * _rarity_tree_predict_compiled(t, feats) }
    score
  else
    score = model["bias"].to_f
    lr = model["lr"].to_f
    model["trees"].each { |t| score += lr * _rarity_tree_predict(t, feats) }
    score
  end
end

def _rarity_gbt_regression(feats, model)
  trees_c = model["trees_c"]
  if trees_c
    score = model["bias_f"]
    lr = model["lr_f"]
    trees_c.each { |t| score += lr * _rarity_tree_predict_compiled(t, feats) }
    score
  else
    score = model["bias"].to_f
    lr = model["lr"].to_f
    model["trees"].each { |t| score += lr * _rarity_tree_predict(t, feats) }
    score
  end
end

# Multiclass: one-vs-rest binary classifiers per class. probs is the softmax over the
# per-class raw logits; class label order matches clf["classes"] (canonical:
# ["forbidden", "rare", "common"]).
def _rarity_multiclass_probs(feats, clf)
  classes = clf["classes"]
  type = clf["model_type"]
  logits = classes.map do |c|
    case type
    when "logreg"
      m = clf["models"][c]
      _rarity_logreg_binary_margin(feats, m)
    when "gbt"
      _rarity_gbt_binary_margin(feats, clf["models"][c])
    else
      raise "unknown rarity model_type: #{type.inspect}"
    end
  end
  mx = logits.max
  exps = logits.map { |z| Math.exp(z - mx) }
  sum = exps.sum
  exps.map { |e| e / sum }
end

# Returns [category_symbol, integer_freq] for sig. Integer freq in {0, 2, 10}
# so downstream preference code that compares integer freqs keeps working.
#
# :forbidden => 0 (the rarity gate rare? in query.rb treats freq <=
# RARE_FREQ_MAX as rare, so 0 is "rare but deletable"; the caller deletes the
# headword). :rare => 2 (below RARE_FREQ_MAX=4). :common => 10 (above the
# cutoff). Extend this mapping if the build needs more resolution in the common
# band.
def rarity_classify(sig)
  clf = rarity_classifier
  return nil if clf.nil?

  feats = learned_rarity_feature_vector(sig)
  target = clf["target"]

  cat = case target
        when "3class"
          probs = _rarity_multiclass_probs(feats, clf)
          classes = clf["classes"]
          classes[probs.each_with_index.max_by { |v, _| v }[1]].to_sym
        when "regressor"
          score = _rarity_gbt_regression(feats, clf)
          t_fr = (clf["t_forbidden_rare"] || 1.0).to_f
          t_rc = (clf["t_rare_common"] || 6.0).to_f
          if score < t_fr
            :forbidden
          elsif score < t_rc
            :rare
          else
            :common
          end
        else
          raise "unknown rarity target: #{target.inspect}"
        end

  freq = case cat
         when :forbidden then 0
         when :rare      then 2
         when :common    then 10
         end
  [cat, freq]
end

# Rescoring freqs that exceed this are treated as "structural sentinels"
# (semantically_promiscuous 999999, common_words 99, neol 98) and NOT touched
# by the classifier — a classifier that fires :forbidden on a promiscuous
# word is almost certainly wrong and we'd rather leak some rescore
# opportunities than lose promiscuous headwords. Headwords at or below this
# still get rescored.
RARITY_CLASSIFIER_RESCORE_MAX_FREQ = 90

# Phase symbols that only fire when the donor base is in common_words (i.e.
# rarity.csv's common / common_ish rows): morph_inherit_listed comes
# from morph_inherit_listed in frequency.rb and morph_expand_listed from
# morph_expand_listed — both branches gate on common_words.include?(base)
# before recording propagation. Encoding either as a categorical feature
# (freq_source_phase_index) lets the classifier back-derive the curated
# label from the lemma's CSV row, same shape of leak the common_words_flag /
# rare_words_flag direct features used to introduce. We mask them to
# :unknown on the dump side only — the runtime rescore path in
# rarity_rescore_and_dump! keeps the precise phase symbol on sig so
# dict_trace output and downstream consumers stay informative; we only mask
# the parallel dump_sig used to write the JSONL training rows. Train/test
# asymmetry on these two phases is small in practice because both listed
# branches push entry[0] to the 99 sentinel, which the runtime rescore
# already short-circuits via RARITY_CLASSIFIER_RESCORE_MAX_FREQ before the
# classifier even sees the row.
RARITY_DUMP_LEAKY_FREQ_SOURCE_PHASES = Set[
  :morph_inherit_listed,
  :morph_expand_listed,
].freeze

$rarity_usf_associations = nil
def rarity_usf_associations_for_build
  return $rarity_usf_associations unless $rarity_usf_associations.nil?
  path = generated_root_path(USF_ASSOCIATIONS_FILENAME)
  unless File.exist?(path)
    raise "USF associations not found at #{path}. Run ./bin/setup-corpora (which calls ./bin/build-usf-associations)."
  end
  data = JSON.parse(BuildIo.read(path, encoding: "UTF-8", hint: "rarity_usf_associations_for_build"))
  puts "loaded #{data.size} USF cues for rarity signals from #{path}"
  $rarity_usf_associations = data
end

# Build ConceptNet adjacency for the rarity signal pass by streaming the
# corpus mirror at generated/conceptnet_edges.msgpack and filtering /
# canonicalizing against the in-memory word_dict being rebuilt (passed via
# dict_set) plus the prior build's word_lemma_map.msgpack from runtime/
# (loaded lazily into $word_to_lemma). First-ever build of a fresh clone has
# no corpus mirror yet; we surface that via cn_adjacency_loaded=false so the
# classifier can condition on "data not available" rather than "0 degree".
# Outside dict-build, missing edges are fatal (silent degradation in
# relatedness training was the bug that motivated this strictness).
$rarity_cn_adjacency = nil
$rarity_cn_adjacency_loaded = nil
def rarity_conceptnet_adjacency_for_build(dict_set:)
  return [$rarity_cn_adjacency, $rarity_cn_adjacency_loaded] unless $rarity_cn_adjacency.nil?
  path = generated_root_path(CONCEPTNET_EDGES_FILENAME)
  unless File.exist?(path)
    if ENV["RHYMECRIME_BUILD_MODE"].to_s.empty?
      raise "ConceptNet edges not found at #{path} for rarity signal build. " \
            "Run ./bin/setup-corpora before train-rarity-classifier."
    end
    puts "rarity_conceptnet_adjacency_for_build: no prior #{path} — first-ever build, " \
         "cn_adjacency_loaded=false (cn_degree_* features will be marked unavailable)"
    $rarity_cn_adjacency = {}
    $rarity_cn_adjacency_loaded = false
    return [$rarity_cn_adjacency, $rarity_cn_adjacency_loaded]
  end
  load_word_to_lemma! if $word_to_lemma.nil?
  edges = load_conceptnet_edges_streaming(
    path,
    dict_set: dict_set,
    lemma_lookup: $word_to_lemma || {},
  )
  if edges.empty?
    raise "ConceptNet edges file at #{path} produced 0 in-dict edges for rarity signals — " \
          "would silently zero out cn_degree_*."
  end
  adj = {}
  edges.each_key do |key|
    a, b = key.split("|", 2)
    (adj[a] ||= []) << b
    (adj[b] ||= []) << a
  end
  $rarity_cn_adjacency = adj
  $rarity_cn_adjacency_loaded = true
  puts "built ConceptNet adjacency for rarity signals: #{edges.size} edges over #{adj.size} nodes (filtered to #{dict_set.size} dict words)"
  [$rarity_cn_adjacency, $rarity_cn_adjacency_loaded]
end

# Mark a word for tombstoned (BuildEntry) or delete it outright
# (legacy [freq, prons] array). Used by rarity_rescore_and_dump! so the
# classifier's :forbidden verdicts become deferred tags that
# finalize_build_entries! drops in one terminal pass, alongside a recorded
# classifier score for the audit log.
def classifier_mark_or_delete!(hash, word, entry, phase:, reason:, detail: nil)
  if entry.is_a?(BuildEntry)
    return if entry.tombstoned?
    entry.mark_tombstoned!(phase: phase, reason: reason, detail: detail)
  else
    hash.delete(word)
  end
end

# Set a new freq on the entry from a classifier decision. Appends a
# FreqTag (phase: :classifier) so provenance stays attached; for legacy
# [freq, prons] entries falls back to the direct entry[0] = freq write.
def classifier_set_freq!(entry, new_freq:, verdict:, reason:)
  if entry.is_a?(BuildEntry)
    entry.append_freq_tag!(
      phase: :classifier,
      post_freq: new_freq,
      gate_outcomes: { verdict: verdict, reason: reason },
    )
  else
    entry[0] = new_freq
  end
end

def rarity_rescore_and_dump!(hash, **ctx_kwargs)
  dump_path = ENV["RHYMECRIME_RARITY_DUMP_SIGNALS"]
  dump_enabled = !dump_path.nil? && !dump_path.empty?
  # bin/dict-build Dir.chdir's into lib/rhymecrime/build/ before invoking
  # us, so a relative RHYMECRIME_RARITY_DUMP_SIGNALS would land under
  # lib/rhymecrime/build/generated/ instead of the repo's generated/. Anchor
  # to REPO_ROOT so the path the operator passes (and the path the trainer
  # later reads — see bin/train-rarity-classifier) line up.
  dump_path = File.expand_path(dump_path, REPO_ROOT) if dump_enabled
  clf = rarity_classifier
  return if clf.nil? && !dump_enabled

  # Load + announce the curated/rarity.csv overrides before the rescore loop
  # so the per-word override lookup is a single hash probe and the operator
  # sees the override coverage in the build log alongside the classifier
  # rescore counts. Skipped entirely when the classifier itself is disabled
  # (nothing to override) — the dump-only path doesn't need or use overrides.
  overrides = clf ? rarity_curated_overrides : {}
  announce_rarity_curated_overrides! if clf

  cn_adj, cn_loaded = rarity_conceptnet_adjacency_for_build(dict_set: hash.keys.to_set)
  ctx = RarityContext.build(
    usf_associations: rarity_usf_associations_for_build,
    conceptnet_adjacency: cn_adj,
    conceptnet_adjacency_loaded: cn_loaded,
    **ctx_kwargs,
  )
  rescored = 0
  deleted = 0
  skipped_sentinel = 0
  override_applied = 0
  override_rescored = 0
  override_deleted = 0
  dump_main = 0
  dump_forbidden = 0

  # dump_file has to be declared BEFORE the write_dump_row lambda below or
  # Ruby parses the dump_file inside the closure body as a method call on
  # main (local-variable scoping is fixed at parse time, so a later
  # assignment doesn't promote the name to a captured local). nil here is
  # just a placeholder; the actual handle is assigned a few lines down when
  # dump_enabled is true.
  dump_file = nil
  if dump_enabled
    FileUtils.mkdir_p(File.dirname(dump_path))
    dump_file = BuildIo.open(dump_path, "w", encoding: "UTF-8", hint: "rarity_rescore_signals_dump")
  end

  # The dump path replaces the seeded/propagated entry[0] with a corpus-only
  # compute_frequency result so post_propagation_freq can't read the
  # curated-list label off its own input. Without this, common_words rows
  # land at the freq=99 sentinel set in add_frequency_info's seed loop and
  # rare_words rows at freq=0 — both downstream of the very same CSV that
  # the trainer turns into labels. Runtime rescore still uses the live
  # entry[0]; only the JSONL dump shifts to corpus-only.
  kaikki_cap_only = ctx_kwargs[:kaikki_capitalized_only]
  dump_corpus_only_freq = lambda do |word|
    compute_frequency(
      word, ctx.subtlex_hash, ctx.wordfreq_hash,
      subtlex_total_hash: ctx.subtlex_total_hash,
      kaikki_capitalized_only: kaikki_cap_only,
      pos_map: ctx.pos_map,
    )
  end

  write_dump_row = lambda do |word, sig, freq_for_log|
    features = learned_rarity_feature_vector(sig)
    dump_file.puts JSON.generate(
      "word" => word,
      "features" => features,
      "freq" => freq_for_log,
    )
  end

  begin
    hash.keys.each do |word|
      entry = hash[word]
      next unless entry
      # Scrubs earlier in add_frequency_info now mark rows with
      # mark_tombstoned! instead of hash.delete; skip those so the
      # classifier doesn't rescore them (their verdict is already sealed by
      # the scrub and would just be overwritten by finalize_build_entries!).
      next if entry.is_a?(BuildEntry) && entry.tombstoned?

      # Prefer the accumulated signals carried on the BuildEntry (the pipeline
      # now builds them incrementally rather than re-deriving from raw corpora
      # at the last minute). Fall back to extract_rarity_signals for the
      # initial migration window where the accumulator isn't populated yet
      # — functional parity: both code paths read from the same corpora.
      sig = (entry.is_a?(BuildEntry) && entry.rarity_signals) || extract_rarity_signals(word, ctx)
      sig.post_propagation_freq = entry[0]
      # Prefer the BuildEntry's own freq-tag history (single source of truth)
      # over the legacy global side-table; the two agree under parity-preserving
      # semantics but the per-entry view will continue to carry information
      # through future migrations where the global is retired.
      if entry.is_a?(BuildEntry) && !entry.freq_tags.empty?
        sig.freq_source_phase = entry.latest_freq_source_phase
        sig.received_donor_from_common_base_flag = entry.any_donor_anchored?
      else
        meta = $freq_propagation_metadata && $freq_propagation_metadata[word]
        if meta
          sig.freq_source_phase = meta[:phase] || :unknown
          sig.received_donor_from_common_base_flag = !!meta[:donor_anchored]
        end
      end

      dict_trace_puts(word, "rarity_classifier_rescore: enter freq=#{entry[0]} src=#{sig.freq_source_phase} donor_anchored=#{sig.received_donor_from_common_base_flag}") if dict_trace_word?(word)

      if dump_file
        # Build a parallel dump-only signals struct so we don't disturb the
        # rescore path's view of the same word (which still wants the seeded
        # entry[0] for its sentinel-skip and rescore decisions).
        dump_sig = sig.dup
        dump_sig.post_propagation_freq = dump_corpus_only_freq.call(word)
        if RARITY_DUMP_LEAKY_FREQ_SOURCE_PHASES.include?(dump_sig.freq_source_phase)
          dump_sig.freq_source_phase = :unknown
        end
        write_dump_row.call(word, dump_sig, dump_sig.post_propagation_freq)
        dump_main += 1
      end

      next if clf.nil?

      # Curated override: short-circuit the classifier when the word has an
      # unambiguous verdict in curated/rarity.csv (see
      # rarity_curated_overrides.rb). Bypasses both the sentinel-freq skip
      # (the CSV is authoritative — if a curator marked a sentinel-freq word
      # rare, we trust that more than the 99 floor that put it there) and
      # the classifier itself.
      if (verdict = overrides[word])
        override_applied += 1
        new_freq = CURATED_RARITY_OVERRIDE_FREQ[verdict]
        if verdict == :forbidden
          dict_trace_puts(word, "rarity_classifier_rescore: DELETE (curated override :forbidden, was freq=#{entry[0]})") if dict_trace_word?(word)
          classifier_mark_or_delete!(hash, word, entry, phase: :classifier, reason: :curated_override_forbidden, detail: { was_freq: entry[0], verdict: verdict })
          deleted += 1
          override_deleted += 1
        elsif entry[0] != new_freq
          dict_trace_puts(word, "rarity_classifier_rescore: curated override #{entry[0]} -> #{new_freq} (cat=#{verdict})") if dict_trace_word?(word)
          classifier_set_freq!(entry, new_freq: new_freq, verdict: verdict, reason: :curated_override)
          rescored += 1
          override_rescored += 1
        else
          dict_trace_puts(word, "rarity_classifier_rescore: curated override kept freq=#{entry[0]} (cat=#{verdict})") if dict_trace_word?(word)
        end
        next
      end

      if entry[0] > RARITY_CLASSIFIER_RESCORE_MAX_FREQ
        skipped_sentinel += 1
        dict_trace_puts(word, "rarity_classifier_rescore: skip (sentinel freq=#{entry[0]} > #{RARITY_CLASSIFIER_RESCORE_MAX_FREQ})") if dict_trace_word?(word)
        next
      end

      result = rarity_classify(sig)
      if result.nil?
        dict_trace_puts(word, "rarity_classifier_rescore: classify returned nil") if dict_trace_word?(word)
        next
      end

      new_cat, new_freq = result

      # Auth-pron protection: a hand-curated entry in
      # authoritative_pronunciations.txt is explicit curator intent that the
      # word should be reachable. Veto a :forbidden verdict by clamping to
      # :rare so the headword survives the rescore. The auto spelling-variant
      # detectors in corpus_variants.rb (e.g. silent_e_drop_corpus_pairs
      # for rueing/ruing via the rue base, us_uk_er_re_pair for
      # megameter/megametre) gate on word_dict_includes_pronounced_headword?
      # for both halves of a pair, so silently deleting the auth-pron half
      # would prevent the pair from being detected at all. Only :forbidden
      # gets vetoed — :rare / :common classifier verdicts are honored.
      if new_cat == :forbidden && authoritative_pronunciation_words.include?(word)
        dict_trace_puts(word, "rarity_classifier_rescore: VETO :forbidden -> :rare (auth pron, was freq=#{entry[0]})") if dict_trace_word?(word)
        new_cat = :rare
        new_freq = CURATED_RARITY_OVERRIDE_FREQ[:rare]
      end

      if new_cat == :forbidden
        dict_trace_puts(word, "rarity_classifier_rescore: DELETE (classified :forbidden, was freq=#{entry[0]})") if dict_trace_word?(word)
        classifier_mark_or_delete!(hash, word, entry, phase: :classifier, reason: :forbidden_verdict, detail: { was_freq: entry[0], classifier_score: new_freq })
        deleted += 1
      elsif entry[0] != new_freq
        dict_trace_puts(word, "rarity_classifier_rescore: rescored #{entry[0]} -> #{new_freq} (cat=#{new_cat})") if dict_trace_word?(word)
        classifier_set_freq!(entry, new_freq: new_freq, verdict: new_cat, reason: :classifier_rescore)
        rescored += 1
      else
        dict_trace_puts(word, "rarity_classifier_rescore: kept freq=#{entry[0]} (cat=#{new_cat})") if dict_trace_word?(word)
      end
    end

    # Forbidden-list pass (dump only). explicitly_forbidden words have already
    # been removed from word_dict by the forbidden_scrub in
    # add_frequency_info before we get here, so the main loop never sees
    # them. Without an explicit dump for these rows, the trainer hits its
    # "missing from dump → all-zero features" branch, which fingerprints
    # forbidden labels as "every feature is exactly 0" — a perfect predictor
    # the trainer trivially learns. Dumping them with real corpus signals
    # forces the model to learn the actual forbidden ↔ corpus-feature
    # relationship.
    if dump_file
      # Scrubs defer deletion via mark_tombstoned!, so hash.key?(word)
      # is no longer the right "already dumped" test: a forbidden_scrub entry
      # is still in hash but already in the dump loop above. Honor that by
      # treating pending-deleted entries as "already dumped" here too — the
      # dump row we wrote up top carries the real rescore signals.
      rarity_csv_forbidden_words.each do |word|
        entry = hash[word]
        next if entry && !(entry.is_a?(BuildEntry) && entry.tombstoned?)
        sig = extract_rarity_signals(word, ctx)
        sig.post_propagation_freq = dump_corpus_only_freq.call(word)
        write_dump_row.call(word, sig, sig.post_propagation_freq)
        dump_forbidden += 1
      end
    end
  ensure
    dump_file&.close
  end

  if clf
    puts "rarity classifier: rescored #{rescored} entries, deleted #{deleted} forbidden entries, skipped #{skipped_sentinel} sentinel-freq entries"
    if override_applied > 0
      puts "rarity classifier: of those, #{override_applied} came from curated/rarity.csv overrides (#{override_rescored} rescored, #{override_deleted} deleted)"
    end
  end
  if dump_enabled
    puts "rarity signals dumped to #{dump_path} (#{dump_main} live word_dict rows + #{dump_forbidden} curated-forbidden rows; freqs are corpus-only via compute_frequency)"
  end
end
