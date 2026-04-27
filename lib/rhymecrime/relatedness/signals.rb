#!/usr/bin/env ruby
# coding: utf-8
#
# relatedness/signals.rb — offline signal gathering for the relatedness pipeline.
#
# Holds every knowledge-base loader and per-pair raw-feature extractor needed to
# compute +relatedness_score+: Numberbatch vectors, ConceptNet graph, USF
# free-association norms, MPNet contextualized embeddings, WordNet glosses. This
# is the *seed-time* side of the codebase: loaded by +bin/precompute-relatedness+,
# +bin/train-relatedness-classifier+, related specs, and the local-dev escape
# hatch in +lib/rhymecrime/related.rb+ when no precomputed data is available.
#
# Not required at Lambda runtime. Every offline tunable, data loader, and the
# +PairSignals+ class live here so the runtime graph can stay free of the
# hundreds of MB of data files these modules pull in.
#
# Callers are expected to have already loaded +rhymecrime/frontend+ (or
# +rhymecrime/crime+) so helpers like +lemma+, +stop_word?+, +frequency+,
# +rare?+, +word_dict_includes_headword?+, and +part_of_speech_tags+ are
# available.
#

require "json"
require "msgpack"
require "numo/narray"
require "rwordnet"
require "set"
require_relative "../pace_utils"
require_relative "../dict/utils_rhyme"

WordNet::DB.path = File.join(REPO_ROOT, "corpora", "wordnet", "3.1") unless defined?(WordNet::DB) && WordNet::DB.path

CONCEPTNET_EDGES_PATH = generated_dict_path(CONCEPTNET_EDGES_FILENAME) unless defined?(CONCEPTNET_EDGES_PATH)
NUMBERBATCH_VEC_PATH = generated_dict_path(NUMBERBATCH_VECTORS_FILENAME) unless defined?(NUMBERBATCH_VEC_PATH)
USF_ASSOCIATIONS_PATH = generated_dict_path(USF_ASSOCIATIONS_FILENAME) unless defined?(USF_ASSOCIATIONS_PATH)

# --- Tunable parameters (optimized via anneal.rb / parameter sweeps) ---

$SIMILARITY_THRESHOLD = 10
$CONCEPTNET_EDGE_BONUS = 7
$SENSE_VECTOR_THRESHOLD = 10
$SENSE_VECTOR_MIN_FLOOR = 5
$SENSE_VECTOR_MORPHY_FLOOR = 13
$SENSE_VECTOR_MIN_BASE = 6
$SENSE_VECTOR_MAX_SENSES = 4
# Asymmetric sense-vector bypass: when one direction is very strong (e.g. one word's
# WordNet definitions clearly describe the other) the reverse direction is often
# diluted by polysemy. Accept as related when +sv_max >= ASYMMETRIC_MAX+ and
# +sv_min >= ASYMMETRIC_MIN+, as long as the regular +SENSE_VECTOR_MIN_BASE+ gate
# is satisfied. The non-zero +ASYMMETRIC_MIN+ keeps pure noise out.
$SENSE_VECTOR_ASYMMETRIC_MAX = 18
$SENSE_VECTOR_ASYMMETRIC_MIN = 1
$USF_TWOHOP_BOOST = 10
$USF_MIN_BRIDGE_COS = 8
# Skip USF graph work when primary score is below this (0 = same as pre-filter behavior).
$USF_MIN_BASE = 0

# Co-occurrence combiner: additive contribution that fires when several weak signals
# line up even though no single hard-gated rule is satisfied. This is the main lever
# the 3-phase design unlocks — gates on individual rules are already tuned, but pairs
# with (e.g.) below-threshold +base+ *and* two-sided sense-vector agreement *and* a
# validated USF bridge are clearly related despite no single gate passing. Weights
# tuned on +curated/related.csv+ via grid search over a broad plateau (see
# +spec/related_weighted_accuracy.rb+). Contribution is +base * w + sv_min * w +
# max(0, sv_max - floor) * w + (usf ? w : 0)+, each term capped so one runaway
# signal can't dominate.
$COOCCUR_BASE_WEIGHT = 3.0
$COOCCUR_BASE_CAP = 15
$COOCCUR_SV_MIN_WEIGHT = 2.0
$COOCCUR_SV_MIN_CAP = 15
$COOCCUR_SV_MAX_WEIGHT = 1.5
$COOCCUR_SV_MAX_FLOOR = 5
$COOCCUR_SV_MAX_CAP = 20
$COOCCUR_USF_WEIGHT = 10

# Cheap gate for the expensive MPNet sense-sense and directional-sense cosines.
# When +model_headword_cosine+ (one 768-dim dot product, already needed for the
# classifier's +model_cos_pct+ feature) is below this threshold, both
# +model_sense_sense_max_cosine+ and +model_directional_sense_cosines+
# short-circuit to 0. Cutoff is on the raw cosine (-1..1), not the
# +model_cos_pct+ centile.
#
# Rationale: a 768-dim unit-vector dot product near 0 means the two words live
# in nearly-orthogonal regions of the MPNet embedding space. Sense vectors are
# variants of the headword vector (built from gloss contexts), so when the
# heads are near-orthogonal the per-sense cosines are almost always below the
# classifier's threshold and the expensive K_a*K_b*768 inner loop is wasted.
# Pairs that would have squeaked through via a polysemous sense are rare
# enough that the overall predicate is essentially unchanged; the retrained
# classifier absorbs the small residual by leaning harder on +model_cos_pct+
# (which remains uncapped).
#
# In the +pirate+ one-cue profile, ~41% of wall time was inside these two
# functions (see +notes/todo.md+ perf log). Raising the gate from 0 to 0.10
# skips the vast majority of the ~20k-candidate scan inner loops.
#
# Override with +RHYMECRIME_MODEL_SENSE_GATE=0.05+ etc. Negative / blank
# disables the gate.
$MODEL_SENSE_COSINE_GATE = (ENV["RHYMECRIME_MODEL_SENSE_GATE"] || "0.10").to_f

def similarity_threshold
  $SIMILARITY_THRESHOLD
end

# --- ConceptNet edge map ---
# Keys are "word1|word2" (alphabetically sorted), values are edge weights.

$conceptnet_edges = nil
def conceptnet_edges
  return $conceptnet_edges unless $conceptnet_edges.nil?
  path = CONCEPTNET_EDGES_PATH
  if File.exist?(path)
    $conceptnet_edges = JSON.parse(File.read(path, encoding: "UTF-8"))
    puts "loaded #{$conceptnet_edges.size} ConceptNet edges from #{path}"
  else
    $conceptnet_edges = {}
  end
  $conceptnet_edges
end

# Expects dictionary-lemma spellings (see +similarity+). Keys match +save_conceptnet_edge_map!+ export.
def conceptnet_edge_weight(word1, word2)
  key = [hyphens_to_underscores(word1), hyphens_to_underscores(word2)].sort.join("|")
  conceptnet_edges[key] || 0.0
end

# Adjacency index over +conceptnet_edges+: +{node => Set[neighbor, ...]}+. Built once
# the first time it's needed (~1s for ~300k edges). Underscore-keyed (matches the
# edge-map keys directly).
$conceptnet_adjacency = nil
def conceptnet_adjacency
  return $conceptnet_adjacency unless $conceptnet_adjacency.nil?
  adj = {}
  conceptnet_edges.each_key do |key|
    a, b = key.split("|", 2)
    (adj[a] ||= Set.new) << b
    (adj[b] ||= Set.new) << a
  end
  $conceptnet_adjacency = adj
  puts "built ConceptNet adjacency index: #{adj.size} nodes"
  adj
end

# Maximum shortest-path distance considered "meaningful" in the ConceptNet graph.
# BFS is clipped here and distances >= CN_MAX_HOPS are coded in-band (see
# +conceptnet_shortest_hops+). Exposed at top level so the source-cache helpers
# below can reference it without forward-referring to +PairSignals+.
CN_MAX_HOPS = 4 unless defined?(CN_MAX_HOPS)

# Source-fixed BFS cache. When a scan loop is about to evaluate thousands of pairs
# against a single cue, it can call +prepare_cn_hops_source!(cue)+ to precompute the
# full distance table from the cue once (single-source BFS, ~50ms) and then
# +conceptnet_shortest_hops+ short-circuits to a hash lookup for any pair where one
# endpoint is that cue. Scoped to the current process; +clear_cn_hops_source!+ or
# replacing with +nil+ disables the fast path.
$cn_hops_source = nil

# Precompute and cache the shortest-path distance from +cue+ to every ConceptNet
# node reachable within +max_hops+. Idempotent: replaces any previously cached
# source. Safe to call when +cue+ has no ConceptNet node (the cache is cleared so
# the fast path is skipped and the generic BFS still returns +max_hops + 2+).
def prepare_cn_hops_source!(cue, max_hops = ::CN_MAX_HOPS)
  adj = conceptnet_adjacency
  key = hyphens_to_underscores(cue)
  if adj[key].nil?
    $cn_hops_source = nil
    return
  end
  table = { key => 0 }
  frontier = [key]
  depth = 0
  while depth < max_hops && !frontier.empty?
    depth += 1
    next_frontier = []
    frontier.each do |node|
      adj[node]&.each do |neigh|
        next if table.key?(neigh)
        table[neigh] = depth
        next_frontier << neigh
      end
    end
    frontier = next_frontier
  end
  $cn_hops_source = { cue: key, table: table, max_hops: max_hops }
end

def clear_cn_hops_source!
  $cn_hops_source = nil
end

# Shortest path length in the undirected ConceptNet graph between two words, clipped
# at +max_hops+. 1 = direct edge, 2 = one bridge, etc. +max_hops + 1+ means "not
# reachable within +max_hops+". +max_hops + 2+ means at least one endpoint has no
# node in the graph at all — distinct from "reachable but far" so the classifier can
# condition on data availability the way it does with +model_both_in_vocab?+.
# Bidirectional BFS: alternately expands the smaller frontier, so worst-case work
# scales like +degree**(max_hops/2)+ instead of +degree**max_hops+. When a source
# cache built by +prepare_cn_hops_source!+ is active and one endpoint matches the
# cached cue, the BFS is replaced by a single hash lookup.
def conceptnet_shortest_hops(word1, word2, max_hops = 4)
  adj = conceptnet_adjacency
  a = hyphens_to_underscores(word1)
  b = hyphens_to_underscores(word2)
  return max_hops + 2 if adj[a].nil? || adj[b].nil?
  return 0 if a == b
  return 1 if adj[a].include?(b)

  src = $cn_hops_source
  if src && src[:max_hops] >= max_hops
    if a == src[:cue]
      dist = src[:table][b]
      return dist && dist <= max_hops ? dist : max_hops + 1
    elsif b == src[:cue]
      dist = src[:table][a]
      return dist && dist <= max_hops ? dist : max_hops + 1
    end
  end

  seen_a = { a => 0 }
  seen_b = { b => 0 }
  front_a = [a]
  front_b = [b]
  depth_a = 0
  depth_b = 0

  while depth_a + depth_b < max_hops
    if front_a.size <= front_b.size
      new_depth = depth_a + 1
      next_front = []
      front_a.each do |node|
        adj[node]&.each do |neigh|
          next if seen_a.key?(neigh)
          if seen_b.key?(neigh)
            total = new_depth + seen_b[neigh]
            return total if total <= max_hops
          end
          seen_a[neigh] = new_depth
          next_front << neigh
        end
      end
      return max_hops + 1 if next_front.empty?
      front_a = next_front
      depth_a = new_depth
    else
      new_depth = depth_b + 1
      next_front = []
      front_b.each do |node|
        adj[node]&.each do |neigh|
          next if seen_b.key?(neigh)
          if seen_a.key?(neigh)
            total = new_depth + seen_a[neigh]
            return total if total <= max_hops
          end
          seen_b[neigh] = new_depth
          next_front << neigh
        end
      end
      return max_hops + 1 if next_front.empty?
      front_b = next_front
      depth_b = new_depth
    end
  end
  max_hops + 1
end

# Number of nodes with edges to *both* words. Cheap and orthogonal to both edge_weight
# (0/1 direct-edge signal) and cn_hops (integer graph-distance signal).
def conceptnet_shared_neighbor_count(word1, word2)
  adj = conceptnet_adjacency
  na = adj[hyphens_to_underscores(word1)]
  nb = adj[hyphens_to_underscores(word2)]
  return 0 if na.nil? || nb.nil?
  (na & nb).size
end

# --- USF Free Association Norms (Nelson, McEvoy & Schreiber 1998) ---
# 5,019 cue words with ~72K forward association pairs from human participants.
# Used for 2-hop inference: word1 → bridge → word2, validated by requiring
# the bridge word to have positive Numberbatch cosine with both endpoints.

$usf_associations = nil
def usf_associations
  return $usf_associations unless $usf_associations.nil?
  path = USF_ASSOCIATIONS_PATH
  if File.exist?(path)
    $usf_associations = JSON.parse(File.read(path, encoding: "UTF-8"))
    puts "loaded #{$usf_associations.size} USF cues from #{path}"
  else
    $usf_associations = {}
  end
  $usf_associations
end

# Direct (1-hop) USF forward-association strengths between a lemma pair. Returns
# +[forward, reverse]+: +forward+ is the strength when +word1+ was the cue and
# +word2+ appeared as a target, +reverse+ is the symmetric case. Zero in each
# direction when no direct link exists. Complements +usf_twohop_bridge_validated?+:
# 2-hop needs validation because intermediate bridges can be spurious, but a direct
# link from human free-association participants is unambiguous evidence of mental
# association and typically a much stronger relatedness signal.
def usf_direct_association_strengths(word1, word2)
  ua = usf_associations
  return [0.0, 0.0] if ua.empty?
  fwd = (ua[word1] && ua[word1][word2]) || 0.0
  rev = (ua[word2] && ua[word2][word1]) || 0.0
  [fwd.to_f, rev.to_f]
end

def usf_twohop_bridge_validated?(word1, word2)
  ua = usf_associations
  # Neither endpoint is a USF cue → no word→bridge forward star to search.
  return false if ua.empty? || (!ua[word1] && !ua[word2])

  [[word1, word2], [word2, word1]].each do |a, b|
    targets_a = ua[a]
    next unless targets_a
    targets_a.each do |bridge, fsg1|
      next if fsg1 < 0.01
      targets_b = ua[bridge]
      next unless targets_b
      fsg2 = targets_b[b]
      next unless fsg2 && fsg2 >= 0.01
      br = lemma(bridge)
      cos_ab = numberbatch_cosine(a, br)
      cos_bb = numberbatch_cosine(br, b)
      min_cos = [cos_ab, cos_bb].min
      return true if (min_cos * 100).round >= $USF_MIN_BRIDGE_COS
    end
  end
  false
end

# --- Numberbatch vectors (pre-normalized) ---

# Numberbatch vectors are loaded once and cast to +Numo::SFloat+ at load time
# (see +model_sense_vectors_table+ for the same treatment of MPNet vectors and
# the rationale). Ruby-array dot products in the per-pair hot path scaled as
# +O(candidates × dim)+ pure-Ruby multiplies; +Numo#dot+ delegates to native
# BLAS and collapses the 300-dim (Numberbatch) and 768-dim (MPNet) cosines into
# a single FFI call apiece. Float32 cast is lossless for cosine purposes — the
# +(* 100).round+ quantization at the call sites absorbs any LSB drift.
$numberbatch = nil
def numberbatch
  return $numberbatch unless $numberbatch.nil?
  path = NUMBERBATCH_VEC_PATH
  if File.exist?(path)
    raw = MessagePack.unpack(File.binread(path))
    nb = {}
    raw.each { |k, v| nb[k] = Numo::SFloat.cast(v) if v && !v.empty? }
    $numberbatch = nb
    puts "loaded #{$numberbatch.size} Numberbatch vectors from #{path}"
  else
    $numberbatch = {}
  end
  $numberbatch
end

# Cached table handle — avoids calling #numberbatch on every vector lookup (hot path).
def numberbatch_table
  nb = $numberbatch
  nb.nil? ? numberbatch : nb
end

# Expects dictionary-lemma spellings (see +similarity+). Rows match +save_numberbatch_vectors!+ export.
def numberbatch_cosine(word1, word2)
  nb = numberbatch_table
  v1 = nb[hyphens_to_underscores(word1)]
  v2 = nb[hyphens_to_underscores(word2)]
  return 0.0 if v1.nil? || v2.nil?
  v1.dot(v2).to_f
end

# True if +lemma(word)+ has a row in the Numberbatch export (+save_numberbatch_vectors!+ keys, underscore-normalized).
# Used to skip the O(n) relatedness scan when the cue cannot contribute a primary vector score.
def dictionary_lemma_has_numberbatch_vector?(word)
  l = lemma(word)
  !numberbatch_table[hyphens_to_underscores(l)].nil?
end

# --- Modern sentence-transformer embeddings ---
# Built offline by +bin/dump-sense-glosses+ -> +bin/build-sense-vectors.py+, saved as
# +generated/model_sense_vectors.msgpack+. Supplements (does not replace) Numberbatch:
# Numberbatch is tiny and fast for the O(n) scan, while these contextualized vectors
# carry richer sense distinctions for the per-pair yes/no decision. On-disk shape
# (msgpack):
#   { "model" => String, "dim" => Integer,
#     "headword" => {lemma => [Float * dim]},
#     "senses"   => {lemma => [[Float * dim], ...]} }
# Vectors are pre-L2-normalized so cosine similarity is a plain dot product. Keys use
# hyphen-form lemmas (matching +lemma()+ output), not the underscore form Numberbatch
# keys use. Returns +nil+ if the file is absent — callers degrade gracefully (all
# model-* signals become 0 and +model_both_in_vocab?+ is false, which the learned
# combiner can condition on).
#
# At load time the per-word vectors get converted to +Numo::SFloat+ (32-bit float):
#   headword:  {lemma => Numo::SFloat(dim)}               or nil if OOV
#   senses:    {lemma => Numo::SFloat(K, dim)}            or nil if no senses
# The cosine helpers below are then one +Numo+ +dot+ call apiece — each 768-dim
# dot product offloads to the native BLAS shipped with +numo-narray+, giving a
# ~12x speed-up over the previous pure-Ruby +va.size.times { |i| ... }+ loops
# (measured: 40 kpairs/s vs 3.3 kpairs/s on the +pirate+ precompute cue). The
# float32 cast is lossless for cosine purposes: vectors are already stored as
# +Float+ in the msgpack but their dynamic range is well within float32's
# precision, and the +(* 100).round+ quantization at the call sites hides any
# LSB drift.
$model_sense_vectors = nil
$model_sense_vectors_loaded = false
def model_sense_vectors_table
  return $model_sense_vectors if $model_sense_vectors_loaded
  $model_sense_vectors_loaded = true
  path = generated_dict_path(MODEL_SENSE_VECTORS_FILENAME)
  return nil unless File.exist?(path)
  # Stream-decode instead of +File.binread(path)+: macOS' +read(2)+ syscall caps a
  # single read at +INT_MAX+ (2 GiB), so once the full-vocab msgpack passes that
  # threshold (~136k headwords × 768 fp32 ≈ 2.3 GB), +File.binread+ raises
  # +Errno::EINVAL+. +MessagePack::Unpacker+ on an open IO handles chunking.
  raw = File.open(path, "rb") { |f| MessagePack::Unpacker.new(f).read }
  hw_raw = raw["headword"] || {}
  df_raw = raw["definition"] || {}
  sn_raw = raw["senses"] || {}

  hw = {}
  hw_raw.each { |k, v| hw[k] = Numo::SFloat.cast(v) if v && !v.empty? }

  df = {}
  df_raw.each { |k, v| df[k] = Numo::SFloat.cast(v) if v && !v.empty? }

  sn = {}
  total_senses = 0
  sn_raw.each do |k, vs|
    next if vs.nil? || vs.empty?
    sn[k] = Numo::SFloat.cast(vs)
    total_senses += vs.size
  end

  $model_sense_vectors = {
    "model" => raw["model"],
    "dim" => raw["dim"],
    "headword" => hw,
    "definition" => df,
    "senses" => sn,
  }
  puts "loaded model sense vectors from #{path} " \
       "(model=#{raw['model']} dim=#{raw['dim']} " \
       "headwords=#{hw.size} definitions=#{df.size} senses=#{total_senses})"
  $model_sense_vectors
end

# Returns the word's headword vector as a 1-D +Numo::SFloat+ of length +dim+,
# or +nil+ when the word is out of MPNet vocabulary.
def model_headword_vector(word)
  t = model_sense_vectors_table
  return nil if t.nil?
  h = t["headword"]
  h.nil? ? nil : h[word]
end

# Pooled-definition embedding: MPNet over +"{word}. {gloss1}. {gloss2}..."+ (see
# +bin/dump-sense-glosses+). Disambiguates polysemous bare words ("bear",
# "match", "bank") that the +headword+ vector — which only sees the word in
# isolation — collapses to an averaged sense the classifier has trouble using.
# Returns 1-D +Numo::SFloat(dim)+ or +nil+ when out of vocab. Falls back at
# *build* time to the bare-word text when the word has no WordNet glosses, so
# +definition[word]+ is populated whenever the word is in vocab at all.
def model_definition_vector(word)
  t = model_sense_vectors_table
  return nil if t.nil?
  d = t["definition"]
  d.nil? ? nil : d[word]
end

# Definition-vs-definition cosine under the contextualized model (-1..1). Returns
# 0.0 when either side is out-of-vocab — pair with +def_both_in_vocab?+ so the
# classifier can distinguish "low similarity" from "no data".
def model_definition_cosine(word1, word2)
  v1 = model_definition_vector(word1)
  v2 = model_definition_vector(word2)
  return 0.0 if v1.nil? || v2.nil?
  v1.dot(v2).to_f
end

# Returns the word's sense vectors as a 2-D +Numo::SFloat+ of shape +[K, dim]+,
# or +nil+ when the word has no sense vectors. Callers that need a count use
# +.shape[0]+; presence is +.nil? == false+.
def model_sense_vectors_of(word)
  t = model_sense_vectors_table
  return nil if t.nil?
  s = t["senses"]
  return nil if s.nil?
  s[word]
end

# Headword-headword cosine under the contextualized model (-1..1). Returns 0.0 when
# either side is out-of-vocab — pair with +model_both_in_vocab?+ so the classifier
# can distinguish "low similarity" from "no data".
def model_headword_cosine(word1, word2)
  v1 = model_headword_vector(word1)
  v2 = model_headword_vector(word2)
  return 0.0 if v1.nil? || v2.nil?
  v1.dot(v2).to_f
end

# Directional sense-vs-headword cosines under the contextualized model (each 0..100
# centile). Analogous to +directional_sense_cosines+ but end-to-end in the model's
# embedding space: for each sense vector of word1, the cosine against word2's headword
# vector (and symmetrically). Lets a specific sense of a polysemous word rescue the
# pair even when the averaged headword embedding doesn't match.
#
# Gated by +$MODEL_SENSE_COSINE_GATE+ on the raw headword-headword cosine: when the
# two words are near-orthogonal in MPNet space, none of their per-sense cosines are
# going to cross the classifier's decision threshold either, so we skip the K_a + K_b
# vector-matrix products entirely. Accepts an optional precomputed +headword_cos+ to
# avoid recomputing what +PairSignals+ already cached.
def model_directional_sense_cosines(word1, word2, headword_cos = nil)
  v2_head = model_headword_vector(word2)
  v1_head = model_headword_vector(word1)
  return [0, 0] if v2_head.nil? && v1_head.nil?

  gate = $MODEL_SENSE_COSINE_GATE
  if gate.positive? && v1_head && v2_head
    cos = headword_cos || v1_head.dot(v2_head).to_f
    return [0, 0] if cos < gate
  end

  sa = model_sense_vectors_of(word1)
  sb = model_sense_vectors_of(word2)

  # +sa.dot(v2_head)+ is a +(K_a, dim) . (dim)+ product: one BLAS call returns a
  # +K_a+-length vector of sense-vs-head cosines; +.max+ picks the best sense.
  best_1to2 = (v2_head && sa) ? (sa.dot(v2_head).max * 100).round : 0
  best_1to2 = 0 if best_1to2 < 0
  best_2to1 = (v1_head && sb) ? (sb.dot(v1_head).max * 100).round : 0
  best_2to1 = 0 if best_2to1 < 0

  [best_1to2, best_2to1]
end

# Max cosine over all (sense_of_a, sense_of_b) pairs (0..100 centile). Captures pairs
# where a specific sense of A matches a specific sense of B more tightly than either
# matches the other's headword — i.e. polysemy on *both* sides. Small O(senses_a *
# senses_b); capped at SENSE_VECTOR_MAX_SENSES^2 = 16 comparisons in practice. Same
# headword-cosine gate as +model_directional_sense_cosines+ (see rationale there).
def model_sense_sense_max_cosine(word1, word2, headword_cos = nil)
  sa = model_sense_vectors_of(word1)
  sb = model_sense_vectors_of(word2)
  return 0 if sa.nil? || sb.nil?

  gate = $MODEL_SENSE_COSINE_GATE
  if gate.positive?
    v1_head = model_headword_vector(word1)
    v2_head = model_headword_vector(word2)
    if v1_head && v2_head
      cos = headword_cos || v1_head.dot(v2_head).to_f
      return 0 if cos < gate
    end
  end

  # +sa.dot(sb.transpose)+ is a +(K_a, dim) . (dim, K_b) = (K_a, K_b)+ matmul:
  # one BLAS call gives every sense-pair cosine; +.max+ picks the best cell.
  ((sa.dot(sb.transpose)).max * 100).round
end

# --- WordNet gloss containment (high-precision polysemy rescue) ---
# Checks if word1 (or a validated derivational form) literally appears as a word
# in any WordNet definition of word2, or vice versa.

$gloss_derivation_cache = {}
# All lowercase gloss tokens for a headword (union of every synset gloss); built once per word.
$gloss_token_set_cache = {}
# Pairs (sorted key) known not to match gloss containment either direction.
$gloss_negative_pair_cache = Set.new

def gloss_word_token_set(lemma_word)
  $gloss_token_set_cache[lemma_word] ||= begin
    tokens = Set.new
    WordNet::Lemma.find_all(lemma_word).each do |lemma|
      lemma.synsets.each do |synset|
        synset.gloss.downcase.scan(/[a-z]+/).each { |tok| tokens << tok }
      end
    end
    tokens
  end
end

def validated_derivations(word)
  nb = numberbatch_table
  candidates = [word]
  %w[al ian ical ous ic ly ing ed er tion ment s].each { |s| candidates << word + s }
  candidates << word[0..-2] + "ical" if word.end_with?("y")
  candidates << word[0..-2] + "ies" if word.end_with?("y")

  candidates.select do |d|
    next true if d == word
    w_key = hyphens_to_underscores(word)
    d_key = word_dict_includes_headword?(d) ? hyphens_to_underscores(lemma(d)) : hyphens_to_underscores(d)
    v1 = nb[w_key]
    v2 = nb[d_key]
    next false unless v1 && v2
    v1.dot(v2) >= 0.40
  end
end

def gloss_contains?(topic_word, other_word)
  derivations = $gloss_derivation_cache[topic_word] ||= validated_derivations(topic_word)
  gloss_tokens = gloss_word_token_set(other_word)
  derivations.each { |d| return true if gloss_tokens.include?(d) }
  false
end

def bidirectional_gloss_contains?(word1, word2)
  pair_key = word1 < word2 ? "#{word1}\t#{word2}" : "#{word2}\t#{word1}"
  return false if $gloss_negative_pair_cache.include?(pair_key)

  hit = gloss_contains?(word1, word2) || gloss_contains?(word2, word1)
  $gloss_negative_pair_cache.add(pair_key) unless hit
  hit
end

# --- WordNet gloss-vector sense embeddings ---
# For each WordNet sense, averages Numberbatch vectors of content words in
# the definition to create a sense-specific embedding. Handles polysemy by
# finding the best-matching sense pair.

GLOSS_STOP_WORDS = Set.new(%w[
  a an the is are was were be been being of in on at by to for or and not nor
  with that this these those it its he she they them his her their do does did
  has have had but if so as from than more most which who whom what when where
  how no some any all each every can could may might will would shall should
  very much also just only even still about into over after before between
  through during up down out off away back make made used one
]).freeze

# Cached per-word sense-vector matrix: either a +Numo::SFloat(K, dim)+ of K
# L2-normalized sense vectors (one row per WordNet synset whose gloss contained
# at least 2 Numberbatch-indexed content words) or +nil+ when the word has no
# qualifying senses. Returning a single 2-D matrix lets callers fuse K per-sense
# cosines into one BLAS +dot+ call instead of a Ruby +each+ + scalar-loop dot
# per sense (see +directional_sense_cosines+).
$sense_vectors_cache = {}
def sense_vectors(word, max_senses = $SENSE_VECTOR_MAX_SENSES)
  key = [word, max_senses]
  return $sense_vectors_cache[key] if $sense_vectors_cache.key?(key)

  nb = numberbatch_table
  rows = []
  WordNet::Lemma.find_all(word).each do |lemma|
    lemma.synsets.each do |synset|
      break if rows.size >= max_senses
      content_words = synset.gloss.downcase.scan(/[a-z]+/) - GLOSS_STOP_WORDS.to_a
      embeds = content_words.filter_map do |gw|
        gk = word_dict_includes_headword?(gw) ? hyphens_to_underscores(lemma(gw)) : hyphens_to_underscores(gw)
        nb[gk]
      end
      next if embeds.size < 2
      stacked = Numo::SFloat.vstack(embeds)
      avg = stacked.sum(0)
      mag = Math.sqrt(avg.dot(avg))
      next if mag < 1e-9
      avg /= mag
      rows << avg
    end
    break if rows.size >= max_senses
  end

  result = rows.empty? ? nil : Numo::SFloat.vstack(rows)
  $sense_vectors_cache[key] = result
  result
end

def directional_sense_cosines(word1, word2)
  nb = numberbatch_table
  best_1to2 = 0
  v2_raw = nb[hyphens_to_underscores(word2)]
  if v2_raw
    m1 = sense_vectors(word1)
    if m1
      # Matrix (K, dim) × vector (dim,) → vector (K,); max picks the best sense.
      best = m1.dot(v2_raw).max.to_f
      score = (best * 100).round
      best_1to2 = score if score > 0
    end
  end

  best_2to1 = 0
  v1_raw = nb[hyphens_to_underscores(word1)]
  if v1_raw
    m2 = sense_vectors(word2)
    if m2
      best = m2.dot(v1_raw).max.to_f
      score = (best * 100).round
      best_2to1 = score if score > 0
    end
  end

  [best_1to2, best_2to1]
end

# Morphy-derived sense-vector matrix (or +nil+), analogous to +sense_vectors+
# but resolves inflected forms (plurals, verb conjugations) through WordNet's
# morphy. Same return shape so both feed the same +directional_sense_cosines+
# matrix-dot fast path.
$morphy_sv_cache = {}
def sense_vectors_morphy(word, max_senses = $SENSE_VECTOR_MAX_SENSES)
  return $morphy_sv_cache[word] if $morphy_sv_cache.key?(word)
  nb = numberbatch_table
  morphs = (WordNet::Synset.morphy_all(word) rescue []).uniq - [word]
  rows = []
  morphs.each do |form|
    break if rows.size >= max_senses
    WordNet::Lemma.find_all(form).each do |lemma|
      break if rows.size >= max_senses
      lemma.synsets.each do |synset|
        break if rows.size >= max_senses
        content_words = synset.gloss.downcase.scan(/[a-z]+/) - GLOSS_STOP_WORDS.to_a
        embeds = content_words.filter_map do |gw|
          gk = word_dict_includes_headword?(gw) ? hyphens_to_underscores(lemma(gw)) : hyphens_to_underscores(gw)
          nb[gk]
        end
        next if embeds.size < 2
        stacked = Numo::SFloat.vstack(embeds)
        avg = stacked.sum(0)
        mag = Math.sqrt(avg.dot(avg))
        next if mag < 1e-9
        avg /= mag
        rows << avg
      end
    end
  end
  result = rows.empty? ? nil : Numo::SFloat.vstack(rows)
  $morphy_sv_cache[word] = result
  result
end

def morphy_directional_sense_cosines(word1, word2)
  # Only fall back to morphy when the side has NO direct sense vectors at all.
  sv1_orig = sense_vectors(word1)
  sv2_orig = sense_vectors(word2)
  sv1_morphy = sv1_orig.nil? ? sense_vectors_morphy(word1) : nil
  sv2_morphy = sv2_orig.nil? ? sense_vectors_morphy(word2) : nil
  return nil if sv1_morphy.nil? && sv2_morphy.nil?

  d1, d2 = directional_sense_cosines(word1, word2)
  nb = numberbatch_table

  if sv1_morphy
    v2_raw = nb[hyphens_to_underscores(word2)]
    if v2_raw
      best = sv1_morphy.dot(v2_raw).max.to_f
      score = (best * 100).round
      d1 = score if score > d1
    end
  end

  if sv2_morphy
    v1_raw = nb[hyphens_to_underscores(word1)]
    if v1_raw
      best = sv2_morphy.dot(v1_raw).max.to_f
      score = (best * 100).round
      d2 = score if score > d2
    end
  end

  [d1, d2]
end

# Numberbatch + ConceptNet centile score for two dictionary lemmas. Precompute-time
# input to +PairSignals#base_similarity+. Not used at Lambda runtime (the runtime
# +similarity+ reads the stored +relatedness_score+ directly from DynamoDB).
def lemmilarity(l1, l2)
  return 0 if stop_word?(l1) || stop_word?(l2)

  cos = numberbatch_cosine(l1, l2)
  edge_w = conceptnet_edge_weight(l1, l2)
  edge_bonus = edge_w > 0 ? $CONCEPTNET_EDGE_BONUS : 0

  (cos * 100).round + edge_bonus
end

# --- Phase 1: Signal gathering ---
#
# +PairSignals+ bundles every relatedness signal for a given dictionary-lemma pair
# +(a, b)+. Each feature is returned in its natural type/range (booleans for yes/no
# rescues, 0..100 integers for cosine-derived scores, raw weights for ConceptNet edges,
# counts for sense-vector availability) — no scaling to the composite 0..100 scale
# happens here. Accessors memoize on the instance so diagnostics, scoring, and any
# future callers can read the same signal multiple times without recomputation.
#
# Phase 2 (+relatedness_score+) is the only place feature weights / scaling live.
# --- Unigram feature registry ---
# Each entry here yields one column per pair reduction in +PAIR_REDUCTIONS+
# (+min+ / +max+ / +diff+, which behave as AND / OR / XOR for 0/1-valued booleans
# and as the obvious aggregates for numerics; plus +cue+ / +related+ — the raw
# directional values, kept alongside the symmetric reductions so the classifier
# can split on per-side priors when the +(cue, related)+ orientation matters).
# Add a new signal by extending +word_unigram_features+ and +UNIGRAM_FEATURE_NAMES+;
# the classifier will pick it up on the next retrain and prune it implicitly if
# it can't split on it usefully.

UNIGRAM_FEATURE_NAMES = %w[
  length
  log_freq
  is_rare
  sense_count
  model_sense_count
  wordnet_lemma_count
  cn_degree
  usf_out_degree
  in_numberbatch
  in_model_vocab
  pos_count
].freeze

# +min+ / +max+ / +diff+ are symmetric reductions that pre-date the directional
# split (and stay in place so the existing classifier file's feature-name guard
# only flags the *new* directional columns as added, not the old slots as moved).
# +cue+ / +related+ unfold the pair into its raw orientation: +cue+ is +word_a+'s
# value, +related+ is +word_b+'s value. Distinct from +min+ / +max+ because the
# classifier can now learn that, e.g., +cue+'s +log_freq+ matters more than the
# candidate's, or that +cue cn_degree+ has a different shape than +related
# cn_degree+ — patterns that the symmetric reductions deliberately erase.
PAIR_REDUCTIONS = %i[min max diff cue related].freeze

# Env-var ablation hook: comma-separated list of unigram names whose
# +_min/_max/_diff+ reductions should be excluded from the learned feature
# vector entirely. Read once at first call and cached so training and
# inference see the same filter (both consult this method when assembling
# +LEARNED_FEATURE_NAMES+ and +learned_feature_vector+). Used to A/B test
# whether confounder-y unigram features (length, cn_degree, usf_out_degree,
# is_rare) are helping or hurting the GBT — see +bin/_compare_feature_ablations+.
def dropped_unigram_set
  @dropped_unigram_set ||= begin
    raw = ENV["RELATED_DROP_UNIGRAMS"].to_s.strip
    raw.empty? ? [].to_set : raw.split(/\s*,\s*/).to_set
  end
end

def kept_unigram_indices
  @kept_unigram_indices ||= UNIGRAM_FEATURE_NAMES.each_index.reject do |i|
    dropped_unigram_set.include?(UNIGRAM_FEATURE_NAMES[i])
  end
end

def unigram_pair_feature_names
  kept_unigram_indices.flat_map do |i|
    n = UNIGRAM_FEATURE_NAMES[i]
    PAIR_REDUCTIONS.map { |r| "#{n}_#{r}" }
  end
end

# Memoized per-word: the same word usually appears in many pairs (O(n) scans, cue
# broadcasts, etc.) so we compute the unigram bundle once per word. Retained in
# Hash form (keyed by +UNIGRAM_FEATURE_NAMES+) so callers / diagnostics that want
# a labelled bundle still have one. The hot +unigram_pair_feature_values+ path
# goes through +word_unigram_feature_values+ below, which caches the same data
# as a parallel +Array<Float>+ indexed by position — no string-key hash lookups
# per pair.
$word_unigram_features_cache = {}
def word_unigram_features(word)
  $word_unigram_features_cache[word] ||= begin
    freq = frequency(word)
    nb_hit = dictionary_lemma_has_numberbatch_vector?(word)
    {
      "length" => word.length,
      "log_freq" => Math.log10(freq + 1).round(4),
      "is_rare" => rare?(word) ? 1 : 0,
      "sense_count" => (sv = sense_vectors(word)) ? sv.shape[0] : 0,
      "model_sense_count" => (mv = model_sense_vectors_of(word)) ? mv.shape[0] : 0,
      "wordnet_lemma_count" => (WordNet::Lemma.find_all(word).size rescue 0),
      "cn_degree" => (conceptnet_adjacency[hyphens_to_underscores(word)]&.size || 0),
      "usf_out_degree" => (usf_associations[word]&.size || 0),
      "in_numberbatch" => nb_hit ? 1 : 0,
      "in_model_vocab" => model_headword_vector(word).nil? ? 0 : 1,
      "pos_count" => (defined?(part_of_speech_tags) ? part_of_speech_tags(word).size : 0),
    }
  end
end

# Parallel-array view of +word_unigram_features+: positions match
# +UNIGRAM_FEATURE_NAMES+, values are pre-cast to Float. Avoids 11 string-key
# +Hash+ lookups and an +Integer#to_f+ boxing per (word, pair) inside the hot
# +unigram_pair_feature_values+ path. Cached per word, so the 36k-pair scan
# loop pays the conversion once per cue and once per candidate (2×N total).
$word_unigram_feature_values_cache = {}
def word_unigram_feature_values(word)
  $word_unigram_feature_values_cache[word] ||= begin
    h = word_unigram_features(word)
    UNIGRAM_FEATURE_NAMES.map { |n| h[n].to_f }
  end
end

# Mechanical +(min, max, diff, cue, related)+ expansion of every unigram for a
# pair; appended to the learned feature vector in the same order as
# +unigram_pair_feature_names+. +cue+ / +related+ are the raw directional values
# (+word_a+ is the cue, +word_b+ is the related candidate) so the classifier can
# learn cue-vs-candidate priors that the symmetric +min+ / +max+ / +diff+ collapse
# erases. Writes into a pre-sized output array (vs. a +flat_map+ that allocates
# intermediate per-feature arrays plus the concatenated result per call).
def unigram_pair_feature_values(word_a, word_b)
  fa = word_unigram_feature_values(word_a)
  fb = word_unigram_feature_values(word_b)
  kept = kept_unigram_indices
  out = Array.new(kept.size * PAIR_REDUCTIONS.size)
  j = 0
  kept.each do |i|
    va = fa[i]
    vb = fb[i]
    if va < vb
      out[j] = va
      out[j + 1] = vb
    else
      out[j] = vb
      out[j + 1] = va
    end
    out[j + 2] = (va - vb).abs
    out[j + 3] = va
    out[j + 4] = vb
    j += PAIR_REDUCTIONS.size
  end
  out
end

class PairSignals
  attr_reader :cue, :related

  def initialize(cue, related)
    @cue = cue
    @related = related
  end

  # --- boolean features ---

  def stop_word_cue?
    return @stop_word_cue if defined?(@stop_word_cue)
    @stop_word_cue = stop_word?(@cue)
  end

  def stop_word_related?
    return @stop_word_related if defined?(@stop_word_related)
    @stop_word_related = stop_word?(@related)
  end

  def involves_stop_word?
    stop_word_cue? || stop_word_related?
  end

  def gloss_match?
    return @gloss_match if defined?(@gloss_match)
    @gloss_match = bidirectional_gloss_contains?(@cue, @related)
  end

  def usf_twohop_validated?
    return @usf_twohop if defined?(@usf_twohop)
    @usf_twohop = usf_twohop_bridge_validated?(@cue, @related)
  end

  # Direct (1-hop) USF forward-association strengths, asymmetric.
  # +usf_direct_max+ catches "at least one direction has a human-reported link"
  # (the usual "are these associated?" question). +usf_direct_min+ is non-zero only
  # when *both* directions fired, i.e. mutual association — a stronger signal.
  def usf_direct_strengths
    @usf_direct_strengths ||= usf_direct_association_strengths(@cue, @related)
  end

  def usf_direct_max
    usf_direct_strengths.max
  end

  def usf_direct_min
    usf_direct_strengths.min
  end

  # Directional unfolds: raw cue→related and related→cue forward-association
  # strengths (+usf_direct_max+ / +usf_direct_min+ above are the symmetric
  # reductions). Useful because USF is asymmetric in human data — "cat" cues
  # "dog" much more strongly than "dog" cues "cat" in free-association — and
  # collapsing to max/min discards exactly the orientation signal that
  # distinguishes "X reminds people of Y" from "Y reminds people of X".
  def usf_direct_cue_to_related
    usf_direct_strengths[0]
  end

  def usf_direct_related_to_cue
    usf_direct_strengths[1]
  end

  def both_have_sense_vectors?
    sv_cue_count > 0 && sv_related_count > 0
  end

  def morphy_available?
    !morphy_sv_directional.nil?
  end

  # --- numeric features (natural scale) ---

  # Numberbatch cosine as a 0..100 centile (may be negative when vectors disagree).
  def cos_pct
    @cos_pct ||= (numberbatch_cosine(@cue, @related) * 100).round
  end

  # Raw ConceptNet edge weight (0.0 if no edge recorded).
  def edge_weight
    return @edge_weight if defined?(@edge_weight)
    @edge_weight = conceptnet_edge_weight(@cue, @related)
  end

  def edge_present?
    edge_weight > 0
  end

  # Base similarity score: Numberbatch centile + fixed ConceptNet edge bonus when an
  # edge exists. Same formula as +lemmilarity+; kept here for independent memoization.
  def base_similarity
    @base_similarity ||= cos_pct + (edge_present? ? $CONCEPTNET_EDGE_BONUS : 0)
  end

  # Directional sense-vector cosines (0..100 centiles): +sv_directional.first+ is
  # the cue's sense embeddings vs. the related candidate's Numberbatch vector;
  # +sv_directional.last+ is the reverse. +sv_max+ / +sv_min+ are the symmetric
  # reductions; +sv_cue_to_related+ / +sv_related_to_cue+ expose the raw
  # directional cosines so the classifier can split on which orientation
  # matched.
  def sv_directional
    @sv_directional ||= directional_sense_cosines(@cue, @related)
  end

  def sv_cue_to_related
    sv_directional[0]
  end

  def sv_related_to_cue
    sv_directional[1]
  end

  def sv_max
    sv_directional.max
  end

  def sv_min
    sv_directional.min
  end

  # Count of WordNet senses that produced a usable gloss-average embedding.
  # +sense_vectors+ returns a +Numo::SFloat(K, dim)+ matrix or +nil+; we want
  # K (the per-word sense count), not total element count.
  def sv_cue_count
    return @sv_cue_count if defined?(@sv_cue_count)
    sv = sense_vectors(@cue)
    @sv_cue_count = sv ? sv.shape[0] : 0
  end

  def sv_related_count
    return @sv_related_count if defined?(@sv_related_count)
    sv = sense_vectors(@related)
    @sv_related_count = sv ? sv.shape[0] : 0
  end

  # Morphy-resolved directional cosines (0..100), or +nil+ when neither side needed
  # morphy (both had direct WordNet lemma entries) or no morphy form produced a
  # usable sense vector.
  def morphy_sv_directional
    return @morphy_sv_directional if defined?(@morphy_sv_directional)
    @morphy_sv_directional = morphy_directional_sense_cosines(@cue, @related)
  end

  def morphy_sv_max
    m = morphy_sv_directional
    m ? m.max : 0
  end

  def morphy_sv_min
    m = morphy_sv_directional
    m ? m.min : 0
  end

  # Directional unfolds of the morphy-resolved sense-vector cosines; +0+ when
  # neither side needed morphy fallback. Matching index convention with
  # +sv_directional+: +[0]+ is cue→related, +[1]+ is related→cue.
  def morphy_sv_cue_to_related
    m = morphy_sv_directional
    m ? m[0] : 0
  end

  def morphy_sv_related_to_cue
    m = morphy_sv_directional
    m ? m[1] : 0
  end

  # --- Modern sentence-transformer signals ---
  # Mirror the Numberbatch-based signals above but use contextualized MPNet embeddings
  # (see +model_sense_vectors_table+). +model_both_in_vocab?+ lets the combiner treat
  # "0 because out-of-vocab" differently from "0 because actually unrelated".

  def model_both_in_vocab?
    return @model_both_in_vocab if defined?(@model_both_in_vocab)
    @model_both_in_vocab = !model_headword_vector(@cue).nil? && !model_headword_vector(@related).nil?
  end

  # Raw headword-headword cosine in [-1, 1]. Computed once per pair and reused by
  # +model_cos_pct+ as well as the gate inside +model_directional_sense_cosines+ /
  # +model_sense_sense_max_cosine+ — a tiny +Numo#dot+ but nice to only do once.
  def model_headword_cos
    return @model_headword_cos if defined?(@model_headword_cos)
    @model_headword_cos = model_headword_cosine(@cue, @related)
  end

  def model_cos_pct
    @model_cos_pct ||= (model_headword_cos * 100).round
  end

  def model_sv_directional
    @model_sv_directional ||= model_directional_sense_cosines(@cue, @related, model_headword_cos)
  end

  def model_sv_max
    model_sv_directional.max
  end

  def model_sv_min
    model_sv_directional.min
  end

  # Directional unfolds of the contextualized-model directional cosines;
  # +[0]+ is cue's sense vectors vs. related's headword embedding, +[1]+ is
  # the reverse. Same +0+-when-out-of-vocab semantics as +model_sv_max+ /
  # +model_sv_min+ — pair with +model_both_in_vocab?+ if you want to
  # distinguish "low cosine" from "no data".
  def model_sv_cue_to_related
    model_sv_directional[0]
  end

  def model_sv_related_to_cue
    model_sv_directional[1]
  end

  def model_both_have_sense_vectors?
    return @model_both_have_sv if defined?(@model_both_have_sv)
    @model_both_have_sv = !model_sense_vectors_of(@cue).nil? && !model_sense_vectors_of(@related).nil?
  end

  def model_sense_sense_max
    @model_sense_sense_max ||= model_sense_sense_max_cosine(@cue, @related, model_headword_cos)
  end

  # --- Pooled-definition (cross-encoder) signals ---
  # +model_headword_*+ above embeds bare words ("bear") and so collapses polysemy
  # into one averaged sense the classifier struggles to use as a negative-evidence
  # signal. The definition vector is MPNet over +"{word}. {gloss1}. {gloss2}..."+
  # — the concatenation of WordNet glosses — which the encoder can attend across,
  # producing a definition-aware embedding. +def_both_in_vocab?+ lets the
  # classifier condition on data availability the same way +model_both_in_vocab?+
  # does. Falls back at build time to the bare-word text when no glosses exist,
  # so populated whenever the word is in vocab at all.
  def def_both_in_vocab?
    return @def_both_in_vocab if defined?(@def_both_in_vocab)
    @def_both_in_vocab = !model_definition_vector(@cue).nil? && !model_definition_vector(@related).nil?
  end

  def def_cos_pct
    @def_cos_pct ||= (model_definition_cosine(@cue, @related) * 100).round
  end

  # --- ConceptNet graph-structure signals ---
  # +edge_weight+/+edge_present?+ already capture 1-hop presence. These add:
  # (a) the shortest path length (capped and distinct "unreachable" / "no-node"
  # codings so GBT can split on each independently), and (b) the count of nodes
  # adjacent to *both* sides (a Jaccard-style corroboration signal).

  # Legacy alias for +::CN_MAX_HOPS+; kept for existing +PairSignals::CN_MAX_HOPS+
  # call sites outside this file.
  CN_MAX_HOPS = ::CN_MAX_HOPS

  def cn_hops
    @cn_hops ||= conceptnet_shortest_hops(@cue, @related, ::CN_MAX_HOPS)
  end

  def cn_shared_neighbors
    @cn_shared_neighbors ||= conceptnet_shared_neighbor_count(@cue, @related)
  end
end
