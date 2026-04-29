# encoding: utf-8
#
# Rarity scoring (rarity-pipeline stage 2): machine-learned scorer over +RaritySignals+.
#
# Reads +generated/rarity_classifier.json+ (produced by +bin/train-rarity-classifier+)
# and maps a signals struct to one of +:common / :rare / :forbidden+ plus an integer
# freq in {0, 2, 10} that downstream preference-ordering code compares.
#
# Strict-load policy: when the classifier JSON is missing or its feature-name list
# disagrees with +LEARNED_RARITY_FEATURE_NAMES+, +rarity_classifier+ raises rather
# than silently no-op'ing. A degraded build is worse than a loud failure — the
# rule-based combiner that used to take over had ~3% lower top-line accuracy on
# +curated/rarity.csv+ and quietly shipped that delta.
#
# Two explicit bootstrap escapes for the chicken-and-egg case (the trainer reads a
# classifier dump that +./bin/dict-build+ produces, so the very first build can't
# have a classifier yet):
#
#   RHYMECRIME_RARITY_CLASSIFIER=off       no rescore (rule-based path runs)
#   RHYMECRIME_RARITY_DUMP_SIGNALS=PATH    same, plus emit a feature dump for the
#                                          trainer to consume
#
# Either one fires +rarity_classifier_disabled?+, which short-circuits the load
# before the file-existence check; any other invocation against a missing classifier
# is a hard error with a remediation hint. The standard end-to-end build script
# (+bin/build+) sets +RHYMECRIME_RARITY_DUMP_SIGNALS+ for Build Stage 1/4 and
# then runs +bin/train-rarity-classifier+ as Build Stage 2/4, so a fresh
# checkout reaches steady state without the operator having to think about
# either env var.
#
# Two supported training targets (selected at train time and stored in the JSON
# as +target+):
#
#   3class     — 3-way softmax over {common, rare, forbidden}; one-vs-rest
#                binary classifiers per class (logreg or GBT), softmax over
#                logits at inference, argmax is the label.
#   regressor  — single scalar target (0=forbidden, 2=rare, 10=common); two
#                thresholds +t_forbidden_rare+ and +t_rare_common+ partition
#                the predicted score. GBT-only (logreg has been ablated; it
#                consistently lost to 3class on cross-validated weighted
#                accuracy and isn't worth the inference path).
#
# +learned_rarity_feature_vector+ / +LEARNED_RARITY_FEATURE_NAMES+ are the same
# ordered list of feature names the trainer emits to the JSON.

require "json"
require "fileutils"
require_relative "rarity_signals"
require_relative "utils_rhyme"
require_relative "constants"

# Keep in lock-step with +bin/train-rarity-classifier+. The JSON records its own
# feature-name list so mismatches are detected at load.
LEARNED_RARITY_FEATURE_NAMES = %w[
  bias
  wordfreq_zipf
  subtlex_freqlow
  subtlex_total
  subtlex_cap_ratio_present
  subtlex_cap_ratio
  cmudict_original_flag
  conceptnet_flag
  numberbatch_flag
  usf_flag
  neol_flag
  common_words_flag
  rare_words_flag
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
    _rf(sig.cmudict_original_flag),
    _rf(sig.conceptnet_flag),
    _rf(sig.numberbatch_flag),
    _rf(sig.usf_flag),
    _rf(sig.neol_flag),
    _rf(sig.common_words_flag),
    _rf(sig.rare_words_flag),
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
RARITY_CLASSIFIER_PATH = generated_dict_path(RARITY_CLASSIFIER_FILENAME) unless defined?(RARITY_CLASSIFIER_PATH)

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
  path = RARITY_CLASSIFIER_PATH
  unless File.exist?(path)
    raise "rarity classifier not found at #{path}. Train it via:\n" \
          "  ./bin/build                                     # full four-Build-Stage pipeline (CN+NB + dump + train + relatedness)\n" \
          "or just the rarity steps manually:\n" \
          "  RHYMECRIME_RARITY_DUMP_SIGNALS=generated/rarity_signals_dump.jsonl ./bin/dict-build\n" \
          "  ./bin/train-rarity-classifier\n" \
          "Or set RHYMECRIME_RARITY_CLASSIFIER=off to skip rescore."
  end

  clf = JSON.parse(File.read(path, encoding: "UTF-8"))
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
# laid out contiguously at +base = node_index * 4+:
#   [base+0] feature index (Integer), or +-1+ to mark a leaf
#   [base+1] threshold (Float), OR leaf value when +[base+0] == -1+
#   [base+2] pre-multiplied base offset of the left child  (child_index * 4)
#   [base+3] pre-multiplied base offset of the right child (child_index * 4)
#
# The JSON-on-disk form is an Array of Hashes with string keys — fine for the trainer but
# the per-node hot-loop cost in +dict-build+ was 5 hash probes per traversal step, and
# stackprof showed +_rarity_tree_predict+ at ~46% of total CPU on a full build. Collapsing
# each tree to one flat Array with pre-multiplied child offsets means every node traversal
# does at most 3 +Array#[]+ lookups and 1 +row#[]+ lookup (no hash probes, no multiplies,
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

# Replace +model["trees"]+ with a compiled form (+model["trees_c"]+) and cache bias/lr as
# floats (+model["bias_f"]+ / +model["lr_f"]+). Idempotent. Leaves the original +"trees"+
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

# Multiclass: one-vs-rest binary classifiers per class. +probs+ is the softmax over the
# per-class raw logits; class label order matches +clf["classes"]+ (canonical:
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

# Returns +[category_symbol, integer_freq]+ for +sig+. Integer freq in {0, 2, 10}
# so downstream preference code that compares integer freqs keeps working.
#
# +:forbidden => 0+ (the rarity gate +rare?+ in +crime.rb+ treats freq <=
# +RARE_FREQ_MAX+ as rare, so 0 is "rare but deletable"; the caller deletes the
# headword). +:rare => 2+ (below +RARE_FREQ_MAX+=4). +:common => 10+ (above the
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

$rarity_usf_associations = nil
def rarity_usf_associations_for_build
  return $rarity_usf_associations unless $rarity_usf_associations.nil?
  path = generated_dict_path(USF_ASSOCIATIONS_FILENAME)
  unless File.exist?(path)
    raise "USF associations not found at #{path}. Run ./bin/setup-corpora (which calls ./bin/build-usf-associations)."
  end
  data = JSON.parse(File.read(path, encoding: "UTF-8"))
  puts "loaded #{data.size} USF cues for rarity signals from #{path}"
  $rarity_usf_associations = data
end

# Build ConceptNet adjacency for the rarity signal pass from the PREVIOUS build's
# edges file. First-ever build of a fresh clone: file is absent,
# +conceptnet_adjacency_loaded+ is false so the classifier can condition on
# "data not available" rather than "0 degree". Steady-state builds use the prior
# build's edges — degrees drift until the classifier converges.
$rarity_cn_adjacency = nil
$rarity_cn_adjacency_loaded = nil
def rarity_conceptnet_adjacency_for_build
  return [$rarity_cn_adjacency, $rarity_cn_adjacency_loaded] unless $rarity_cn_adjacency.nil?
  path = generated_dict_path(CONCEPTNET_EDGES_FILENAME)
  if File.exist?(path)
    edges = JSON.parse(File.read(path, encoding: "UTF-8"))
    adj = {}
    edges.each_key do |key|
      a, b = key.split("|", 2)
      (adj[a] ||= []) << b
      (adj[b] ||= []) << a
    end
    $rarity_cn_adjacency = adj
    $rarity_cn_adjacency_loaded = true
    puts "built prior-build ConceptNet adjacency for rarity signals: #{edges.size} edges over #{adj.size} nodes"
  else
    $rarity_cn_adjacency = {}
    $rarity_cn_adjacency_loaded = false
  end
  [$rarity_cn_adjacency, $rarity_cn_adjacency_loaded]
end

def rarity_rescore_and_dump!(hash, **ctx_kwargs)
  dump_path = ENV["RHYMECRIME_RARITY_DUMP_SIGNALS"]
  dump_enabled = !dump_path.nil? && !dump_path.empty?
  # +bin/dict-build+ +Dir.chdir+'s into +lib/rhymecrime/dict/+ before invoking
  # us, so a relative +RHYMECRIME_RARITY_DUMP_SIGNALS+ would land under
  # +lib/rhymecrime/dict/generated/+ instead of the repo's +generated/+. Anchor
  # to +REPO_ROOT+ so the path the operator passes (and the path the trainer
  # later reads — see +bin/train-rarity-classifier+) line up.
  dump_path = File.expand_path(dump_path, REPO_ROOT) if dump_enabled
  clf = rarity_classifier
  return if clf.nil? && !dump_enabled

  cn_adj, cn_loaded = rarity_conceptnet_adjacency_for_build
  ctx = RarityContext.build(
    usf_associations: rarity_usf_associations_for_build,
    conceptnet_adjacency: cn_adj,
    conceptnet_adjacency_loaded: cn_loaded,
    **ctx_kwargs,
  )
  rescored = 0
  deleted = 0
  skipped_sentinel = 0

  dump_file = nil
  if dump_enabled
    FileUtils.mkdir_p(File.dirname(dump_path))
    dump_file = File.open(dump_path, "w", encoding: "UTF-8")
  end

  begin
    hash.keys.each do |word|
      entry = hash[word]
      next unless entry

      sig = extract_rarity_signals(word, ctx)
      sig.post_propagation_freq = entry[0]
      meta = $freq_propagation_metadata && $freq_propagation_metadata[word]
      if meta
        sig.freq_source_phase = meta[:phase] || :unknown
        sig.received_donor_from_common_base_flag = !!meta[:donor_anchored]
      end

      dict_trace_puts(word, "rarity_classifier_rescore: enter freq=#{entry[0]} src=#{sig.freq_source_phase} donor_anchored=#{sig.received_donor_from_common_base_flag}") if dict_trace_word?(word)

      if dump_file
        features = learned_rarity_feature_vector(sig)
        dump_file.puts JSON.generate(
          "word" => word,
          "features" => features,
          "freq" => entry[0],
        )
      end

      next if clf.nil?

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
      if new_cat == :forbidden
        dict_trace_puts(word, "rarity_classifier_rescore: DELETE (classified :forbidden, was freq=#{entry[0]})") if dict_trace_word?(word)
        hash.delete(word)
        deleted += 1
      elsif entry[0] != new_freq
        dict_trace_puts(word, "rarity_classifier_rescore: rescored #{entry[0]} -> #{new_freq} (cat=#{new_cat})") if dict_trace_word?(word)
        entry[0] = new_freq
        rescored += 1
      else
        dict_trace_puts(word, "rarity_classifier_rescore: kept freq=#{entry[0]} (cat=#{new_cat})") if dict_trace_word?(word)
      end
    end
  ensure
    dump_file&.close
  end

  if clf
    puts "rarity classifier: rescored #{rescored} entries, deleted #{deleted} forbidden entries, skipped #{skipped_sentinel} sentinel-freq entries"
  end
  if dump_enabled
    puts "rarity signals dumped to #{dump_path}"
  end
end
