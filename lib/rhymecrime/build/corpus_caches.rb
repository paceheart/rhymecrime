# frozen_string_literal: true

def build_hyphen_multi_fold_map(explicit_word_keys = nil)
  buckets = {}
  load_variants_raw.each do |forms|
    forms.each { |w| ingest_word_into_hyphen_fold_buckets!(buckets, w) }
  end
  if explicit_word_keys
    explicit_word_keys.each { |w| ingest_word_into_hyphen_fold_buckets!(buckets, w) }
  elsif defined?($word_dict) && $word_dict.is_a?(Hash) && !$word_dict.empty?
    $word_dict.each_key { |w| ingest_word_into_hyphen_fold_buckets!(buckets, w) }
  else
    path = generated_dict_path_under_dict_dir(WORD_DICT_FILENAME)
    if File.exist?(path)
      BuildIoUtils.foreach(path, encoding: "UTF-8", hint: "build_hyphen_multi_fold_map") do |line|
        next if line =~ /\A;/ || line =~ /\A#/
        tok = line.split(",", 2).first
        next if tok.nil? || tok.empty?
        ingest_word_into_hyphen_fold_buckets!(buckets, tok.desanitize)
      end
    end
  end
  out = {}
  buckets.each do |fold, set|
    next if set.size < 2
    out[fold] = set.to_a.freeze
  end
  out.freeze
end

# build_keys: headwords used to discover fold groups (include rare spellings when pairing hyphen/solid variants).
# exported_keys: final lexicon; a fold is written only when at least one of its spellings remains exported.
def save_hyphen_variant_map!(build_keys, exported_keys: nil)
  exported_keys = build_keys if exported_keys.nil?
  map = build_hyphen_multi_fold_map(build_keys)
  in_export = exported_keys.to_set
  map = map.reject { |_fold, forms| forms.none? { |w| in_export.include?(w) } }
  ensure_generated_dict_dir!
  path =
    if rhymecrime_build_dir
      generated_bootstrap_path(HYPHEN_VARIANT_MAP_FILENAME)
    else
      generated_dict_path(HYPHEN_VARIANT_MAP_FILENAME)
    end
  sorted = {}
  map.keys.sort.each { |k| sorted[k] = map[k].sort }
  FileUtils.mkdir_p(File.dirname(path))
  BuildIoUtils.write(path, "#{JSON.generate(sorted)}\n", encoding: "UTF-8", hint: "save_hyphen_variant_map")
  puts "Wrote #{sorted.size} hyphen-variant folds to #{HYPHEN_VARIANT_MAP_FILENAME}"
  link_runtime_spelling_hyphen_symlinks! if final_mode? && rhymecrime_build_dir
end

# --- ConceptNet edge map build ---
# Source: conceptnet-assertions-5.7.0.csv.gz (CC-BY-SA 4.0). Resolved by conceptnet_assertions_gz_path:
#   CONCEPTNET_ASSERTIONS_GZ env (absolute path), then corpora/conceptnet/, corpora/, repo root,
#   then newest corpora/**/conceptnet-assertions*.csv.gz
# Kept relations: RelatedTo, Synonym, IsA, HasA, PartOf, UsedFor, CapableOf, AtLocation,
# Causes, HasProperty, HasSubevent, DerivedFrom, FormOf, SimilarTo, HasPrerequisite,
# HasContext, MannerOf, ReceivesAction, HasFirstSubevent, HasLastSubevent, DefinedAs
#
# Vocab list gzip when assertions exist: built by ensure_conceptnet_vocab_cache_for_build! (dict-build) or
# setup.sh / bin/preprocess-conceptnet. conceptnet_headwords_intersecting aborts if cache still missing/stale.
# Path: CONCEPTNET_VOCAB_CACHE_GZ, else <repo>/generated/conceptnet_assertions.txt.gz.
CONCEPTNET_ASSERTIONS_GZ = "conceptnet-assertions-5.7.0.csv.gz"
CONCEPTNET_KEEP_RELATIONS = %w[
  /r/RelatedTo /r/Synonym /r/IsA /r/HasA /r/PartOf /r/UsedFor /r/CapableOf
  /r/AtLocation /r/Causes /r/HasProperty /r/HasSubevent /r/DerivedFrom /r/FormOf
  /r/SimilarTo /r/HasPrerequisite /r/HasContext /r/MannerOf /r/ReceivesAction
  /r/HasFirstSubevent /r/HasLastSubevent /r/DefinedAs
].to_set.freeze
CONCEPTNET_KEEP_RELATION_INDEX = CONCEPTNET_KEEP_RELATIONS.each_with_object({}) { |r, h| h[r] = true }.freeze
CONCEPTNET_EN_NODE_RE = %r{\A/c/en/([a-z][a-z]*)\z}

# Fast /c/en/<ascii_lowercase_word> parse (same acceptance as CONCEPTNET_EN_NODE_RE); avoids MatchData in hot loops.
def conceptnet_en_lemma_from_uri(uri)
  return nil unless uri
  len = uri.bytesize
  return nil if len <= 6
  return nil unless uri.start_with?("/c/en/")
  w = uri.byteslice(6, len - 6)
  return nil if w.empty?
  w.each_byte.all? { |b| b >= 97 && b <= 122 } ? w : nil
end

# CMU-style compounds use hyphens; Numberbatch, ConceptNet /c/en/, etc. use underscores.
def hyphens_to_underscores(word)
  word.to_s.tr("-", "_")
end

# True if dict_set contains this ConceptNet lemma spelling or the hyphenated CMU-style variant.
def conceptnet_dict_includes_lemma?(dict_set, cn_lemma)
  dict_set.include?(cn_lemma) || dict_set.include?(cn_lemma.tr("_", "-"))
end

# Headwords that are their own relatedness-export key: excludes inflected forms (keys of lemma_map).
def relatedness_export_base_headwords(all_headwords, lemma_map)
  all_headwords.reject { |w| lemma_map.key?(w) }
end

# Map a ConceptNet /c/en/ lemma to the spelling we store in relatedness artifacts when it matches
# our lexicon (otherwise returns cn_lemma unchanged). Uses build-time lemma_map like runtime lemma.
def relatedness_canonical_spelling_for_conceptnet_lemma(cn_lemma, dict_set, lemma_map)
  if dict_set.include?(cn_lemma)
    return lemma_map[cn_lemma] || cn_lemma
  end
  hy = cn_lemma.tr("_", "-")
  if dict_set.include?(hy)
    return lemma_map[hy] || hy
  end
  cn_lemma
end

def conceptnet_assertions_gz_path
  env = ENV["CONCEPTNET_ASSERTIONS_GZ"]
  return env if env && !env.empty? && File.file?(env)
  [
    File.join(REPO_ROOT, "corpora", "conceptnet", CONCEPTNET_ASSERTIONS_GZ),
    File.join(REPO_ROOT, "corpora", CONCEPTNET_ASSERTIONS_GZ),
    File.join(REPO_ROOT, CONCEPTNET_ASSERTIONS_GZ),
  ].each { |p| return p if File.file?(p) }
  [File.join(REPO_ROOT, "corpora", "conceptnet"), File.join(REPO_ROOT, "corpora"), REPO_ROOT].each do |dir|
    next unless Dir.exist?(dir)
    matches = Dir.glob(File.join(dir, "conceptnet-assertions*.csv.gz"))
    return matches.max_by { |p| File.mtime(p) } if matches.any?
  end
  nil
end

def conceptnet_vocab_cache_derived_gz_path(assertions_path)
  return nil unless assertions_path
  File.join(GENERATED_ROOT_DIR, CONCEPTNET_VOCAB_CACHE_FILENAME)
end

# Canonical vocab-cache path (read + write): CONCEPTNET_VOCAB_CACHE_GZ if set, else under GENERATED_ROOT_DIR.
def conceptnet_vocab_cache_output_gz_path(assertions_path = nil)
  assertions_path ||= conceptnet_assertions_gz_path
  return nil unless assertions_path
  env = ENV["CONCEPTNET_VOCAB_CACHE_GZ"]
  return env if env && !env.empty?
  conceptnet_vocab_cache_derived_gz_path(assertions_path)
end

def conceptnet_vocab_cache_usable?(assertions_gz, cache_gz)
  return false unless cache_gz && File.file?(cache_gz) && !File.zero?(cache_gz)
  return false unless assertions_gz && File.file?(assertions_gz)
  File.mtime(cache_gz) >= File.mtime(assertions_gz)
end

# Ensures generated vocab cache exists and is no older than assertions (dict-build entrypoint).
# setup.sh also runs bin/preprocess-conceptnet after downloading assertions; this covers
# fresh clones and upgraded assertion files without a separate admin step.
def ensure_conceptnet_vocab_cache_for_build!
  gz = conceptnet_assertions_gz_path
  return unless gz

  cache = conceptnet_vocab_cache_output_gz_path(gz)
  abort "Could not derive ConceptNet vocab cache path for #{gz}" unless cache
  return if File.file?(cache) && conceptnet_vocab_cache_usable?(gz, cache)

  puts "ConceptNet vocab cache missing or stale; building #{cache} (long scan)…"
  build_conceptnet_vocab_cache!
end

# Loads vocab entries from a cache built by build_conceptnet_vocab_cache! (skips # comments).
def conceptnet_vocab_load(cache_gz_path)
  s = Set.new
  BuildIoUtils.gzip_read(cache_gz_path, encoding: "UTF-8", hint: "conceptnet_vocab_load") do |gz|
    gz.each_line do |line|
      w = line.rstrip
      next if w.empty? || w.start_with?("#")
      s.add(w)
    end
  end
  s
end

def conceptnet_vocab_load_cached(cache_gz_path)
  mtime = File.mtime(cache_gz_path)
  memo = $conceptnet_vocab_memo
  if memo.is_a?(Hash) && memo[:path] == cache_gz_path && memo[:mtime] == mtime
    return memo[:set]
  end
  set = conceptnet_vocab_load(cache_gz_path)
  $conceptnet_vocab_memo = { path: cache_gz_path, mtime: mtime, set: set }
  set
end

# Yields each distinct English lemma pair (w1, w2), w1 != w2, on a kept relation (same rules as edge export).
def each_conceptnet_kept_en_en_lemma_pair(gz_path)
  return enum_for(:each_conceptnet_kept_en_en_lemma_pair, gz_path) unless block_given?

  keep = CONCEPTNET_KEEP_RELATION_INDEX
  BuildIoUtils.gzip_read(gz_path, encoding: "UTF-8", hint: "each_conceptnet_kept_en_en_lemma_pair") do |gz|
    gz.each_line do |line|
      next unless line.include?("/c/en/")
      parts = line.split("\t", 5)
      next if parts.length < 4
      next unless keep[parts[1]]
      w1 = conceptnet_en_lemma_from_uri(parts[2])
      w2 = conceptnet_en_lemma_from_uri(parts[3])
      next unless w1 && w2
      next if w1 == w2
      yield w1, w2
    end
  end
end

# One-time (or when upgrading ConceptNet): scan assertions gz and write sorted unique vocab entries for fast dict builds.
def build_conceptnet_vocab_cache!(output_path: nil)
  assertions = conceptnet_assertions_gz_path
  raise "No conceptnet assertions .csv.gz found (set CONCEPTNET_ASSERTIONS_GZ=/path/to/file.gz)" unless assertions

  output_path ||= conceptnet_vocab_cache_output_gz_path(assertions)
  raise "Could not derive output path from #{assertions}" unless output_path

  vocab = Set.new
  edges = 0
  each_conceptnet_kept_en_en_lemma_pair(assertions) do |w1, w2|
    edges += 1
    print "." if (edges % 5_000_000).zero?
    vocab.add(w1)
    vocab.add(w2)
  end
  puts if edges >= 5_000_000

  sorted = vocab.to_a.sort!
  FileUtils.mkdir_p(File.dirname(output_path))
  require "zlib"
  Zlib::GzipWriter.open(output_path, Zlib::BEST_SPEED) do |gz|
    gz.puts "# RhymeCrime ConceptNet English vocab (endpoints on kept relations, /c/en/<ascii_a-z> only)"
    gz.puts "# Built from: #{assertions}"
    sorted.each { |w| gz.puts(w) }
  end
  puts "Wrote #{sorted.size} vocab entries from #{edges} edges to #{output_path}"
  output_path
end

# Subset of dict_set that have a Numberbatch row. Reads the setup-produced
# corpus mirror (generated/numberbatch_vectors.msgpack) — the entire 19.08
# corpus is mirrored into msgpack at setup time, so build-time dict-attestation
# probes never need to re-scan the raw .txt.
def numberbatch_headwords_intersecting(dict_set)
  return Set.new if dict_set.nil? || dict_set.empty?
  by_nb = dict_set.group_by { |w| hyphens_to_underscores(w) }
  out = Set.new
  numberbatch_corpus_token_set_cached.each do |token|
    by_nb[token]&.each { |w| out.add(w) }
  end
  out
end

# Subset of dict_set that appear as /c/en/… endpoints on a kept ConceptNet relation (same filter as edge export).
def conceptnet_headwords_intersecting(dict_set)
  return Set.new if dict_set.nil? || dict_set.empty?
  gz_path = conceptnet_assertions_gz_path
  unless gz_path
    raise "ConceptNet assertions not found for headword intersection. " \
          "Run ./bin/setup-corpora to download corpora/conceptnet/conceptnet-assertions-*.csv.gz " \
          "(or set CONCEPTNET_ASSERTIONS_GZ to its absolute path)."
  end

  cache_path = conceptnet_vocab_cache_output_gz_path(gz_path)
  unless cache_path
    abort "ConceptNet vocab cache path could not be derived for assertions: #{gz_path}"
  end
  unless File.file?(cache_path)
    abort <<~MSG
      ConceptNet vocab cache missing (required for dict-build):
        #{cache_path}
      Run once from repo root:
        ./bin/preprocess-conceptnet
    MSG
  end
  unless conceptnet_vocab_cache_usable?(gz_path, cache_path)
    abort <<~MSG
      ConceptNet vocab cache is older than the assertions file (required):
        cache: #{cache_path}
        assertions: #{gz_path}
      Re-run:
        ./bin/preprocess-conceptnet
    MSG
  end

  vocab = conceptnet_vocab_load_cached(cache_path)
  puts "Using ConceptNet vocab cache #{cache_path} (#{vocab.size} vocab entries) for headword intersection"
  dict_set.each_with_object(Set.new) do |w, out|
    out.add(w) if vocab.include?(hyphens_to_underscores(w))
  end
end

# Stable signature of the kept-relations set; embedded in the cache header so the cache invalidates
# when the set changes (rebuilding with a wider/narrower keep list otherwise risks silent staleness).
def conceptnet_keep_relations_signature
  require "digest/sha1"
  Digest::SHA1.hexdigest(CONCEPTNET_KEEP_RELATION_INDEX.keys.sort.join(","))
end

# Mirror the entire kept-relation ConceptNet edge set to disk as a streaming msgpack file:
#
#   record 0 (header): {"format" => CONCEPTNET_EDGES_STREAM_FORMAT,
#                       "keep_signature" => sha1(CONCEPTNET_KEEP_RELATIONS),
#                       "n_triples" => N}
#   records 1..N      : [w1, w2, weight]   # raw conceptnet lemmas, w1 < w2
#
# Independent of word_dict (matching numberbatch_vectors.msgpack: stable
# corpus-derived artifact). Loaders apply hyphens_to_underscores +
# relatedness_canonical_spelling_for_conceptnet_lemma at load time using the
# current word_dict + lemma_map, so a word transitioning from forbidden to
# common gains coverage without rebuilding this cache. Re-run only when the
# corpus assertions file or the kept-relations set changes — see
# ensure_conceptnet_edges_cache! for the setup-time staleness check.
def save_conceptnet_edges!(out_path = nil)
  gz_path = conceptnet_assertions_gz_path
  unless gz_path
    raise "ConceptNet assertions not found. Run ./bin/setup-corpora to fetch " \
          "corpora/conceptnet/conceptnet-assertions-*.csv.gz (or set " \
          "CONCEPTNET_ASSERTIONS_GZ to its absolute path)."
  end
  ensure_generated_dict_dir!
  out_path ||= generated_root_path(CONCEPTNET_EDGES_FILENAME)

  keep = CONCEPTNET_KEEP_RELATION_INDEX
  triples = {}
  lines = 0
  BuildIoUtils.gzip_read(gz_path, encoding: "UTF-8", hint: "save_conceptnet_edges") do |gz|
    gz.each_line do |line|
      lines += 1
      print "." if (lines % 5_000_000).zero?
      next unless line.include?("/c/en/")
      parts = line.split("\t", 5)
      next if parts.length < 5
      next unless keep[parts[1]]
      w1 = conceptnet_en_lemma_from_uri(parts[2])
      w2 = conceptnet_en_lemma_from_uri(parts[3])
      next unless w1 && w2
      next if w1 == w2
      weight = begin
        JSON.parse(parts[4])["weight"] || 1.0
      rescue
        1.0
      end
      a, b = (w1 < w2) ? [w1, w2] : [w2, w1]
      key = "#{a}\x00#{b}"
      prev = triples[key]
      triples[key] = weight if prev.nil? || weight > prev
    end
  end
  puts if lines >= 5_000_000

  BuildIoUtils.stream_write(out_path, hint: "save_conceptnet_edges") do |out|
    packer = MessagePack::Packer.new(out)
    packer.write({
      "format" => CONCEPTNET_EDGES_STREAM_FORMAT,
      "keep_signature" => conceptnet_keep_relations_signature,
      "n_triples" => triples.size,
    })
    written = 0
    triples.each do |key, weight|
      a, b = key.split("\x00", 2)
      packer.write([a, b, weight])
      written += 1
      packer.flush if (written % 100_000).zero?
    end
    packer.flush
  end
  size_mb = File.size(out_path) / 1024.0 / 1024.0
  puts "Wrote #{triples.size} ConceptNet edges to #{CONCEPTNET_EDGES_FILENAME} (#{size_mb.round(1)} MB)"
  triples.size
end

# Yields [w1, w2, weight] for every record in the streaming ConceptNet edges
# cache file. Caller decides what to do with each triple (filter, materialize,
# count) — the on-disk file is never fully buffered. Raises if the file is
# missing or its header doesn't match the current format / keep-signature
# (operator must rerun ./bin/setup-corpora, which calls
# ensure_conceptnet_edges_cache!).
def each_conceptnet_edge_streaming(path)
  return enum_for(:each_conceptnet_edge_streaming, path) unless block_given?
  raise "ConceptNet edges file missing: #{path} (run save_conceptnet_edges!)" unless File.exist?(path)

  BuildIoUtils.stream_read(path, hint: "conceptnet_edges") do |io|
    unpacker = MessagePack::Unpacker.new(io)
    header = unpacker.read
    unless header.is_a?(Hash) && header["format"] == CONCEPTNET_EDGES_STREAM_FORMAT
      raise "ConceptNet edges file at #{path} has unexpected header #{header.inspect}; " \
            "expected format=#{CONCEPTNET_EDGES_STREAM_FORMAT.inspect}. Regenerate via save_conceptnet_edges!."
    end
    if header["keep_signature"] != conceptnet_keep_relations_signature
      raise "ConceptNet edges file at #{path} has stale keep_signature " \
            "#{header['keep_signature'].inspect} (expected #{conceptnet_keep_relations_signature.inspect}); " \
            "CONCEPTNET_KEEP_RELATIONS changed. Regenerate via save_conceptnet_edges!."
    end
    begin
      loop do
        rec = unpacker.read
        yield rec[0], rec[1], rec[2]
      end
    rescue EOFError
      # end of stream
    end
  end
end

# Stream-load the corpus-mirror ConceptNet edges and materialize the
# per-build/per-runtime filtered + canonicalized {key => weight} hash that
# signals.rb / rarity_classifier.rb consume.
#
# dict_set:      Set<String> of word_dict keys (any spelling — both hyphenated
#                and underscored forms are looked up).
# lemma_lookup:  Hash<String, String> mapping headword → its base lemma. At
#                build time this is compute_lemma_map(word_dict); at runtime
#                it's $word_to_lemma loaded from word_lemma_map.msgpack.
#
# Returns Hash<String, Float> with keys "u1|u2" where u1 < u2 are
# hyphens_to_underscores'd dict-canonical spellings, matching the edge-map shape
# that conceptnet_edge_weight / conceptnet_adjacency consume.
def load_conceptnet_edges_streaming(path, dict_set:, lemma_lookup:)
  edges = {}
  each_conceptnet_edge_streaming(path) do |w1, w2, weight|
    next unless conceptnet_dict_includes_lemma?(dict_set, w1) || conceptnet_dict_includes_lemma?(dict_set, w2)
    c1 = relatedness_canonical_spelling_for_conceptnet_lemma(w1, dict_set, lemma_lookup)
    c2 = relatedness_canonical_spelling_for_conceptnet_lemma(w2, dict_set, lemma_lookup)
    u1 = hyphens_to_underscores(c1)
    u2 = hyphens_to_underscores(c2)
    next if u1 == u2
    key = [u1, u2].sort.join("|")
    edges[key] = weight if weight > (edges[key] || 0)
  end
  edges
end

# Decide whether the ConceptNet edges cache needs (re)building. Returns a
# reason string, or nil if the cache is fresh and in the current streaming
# format with the right keep-signature.
def conceptnet_edges_cache_rebuild_reason
  out_path = generated_root_path(CONCEPTNET_EDGES_FILENAME)
  return "missing #{out_path}" unless File.exist?(out_path)

  gz_path = conceptnet_assertions_gz_path
  if gz_path && File.mtime(out_path) < File.mtime(gz_path)
    return "stale (assertions newer than cache)"
  end

  begin
    BuildIoUtils.stream_read(out_path, hint: "conceptnet_edges header_check") do |io|
      header = MessagePack::Unpacker.new(io).read
      unless header.is_a?(Hash) && header["format"] == CONCEPTNET_EDGES_STREAM_FORMAT
        return "old format (header=#{header.inspect}); current format=#{CONCEPTNET_EDGES_STREAM_FORMAT.inspect}"
      end
      if header["keep_signature"] != conceptnet_keep_relations_signature
        return "stale keep_signature (CONCEPTNET_KEEP_RELATIONS changed)"
      end
    end
  rescue StandardError => e
    return "header probe failed: #{e.class} #{e.message}"
  end

  nil
end

# Idempotent setup-time precondition: rebuild generated/conceptnet_edges.msgpack
# from the corpora/conceptnet/* assertions when missing, stale, or
# format/signature mismatch. Cheap mtime + header probe in steady state. Called
# from bin/setup-corpora, not dict-build: dict builds should consume this stable
# corpus mirror and fail if setup has not produced it.
def ensure_conceptnet_edges_cache!
  reason = conceptnet_edges_cache_rebuild_reason
  return unless reason

  out_path = generated_root_path(CONCEPTNET_EDGES_FILENAME)
  if reason.start_with?("missing ")
    puts "ConceptNet edges cache build: #{out_path}"
  else
    puts "ConceptNet edges cache rebuild: #{reason}"
  end
  save_conceptnet_edges!
end

def require_conceptnet_edges_cache!
  out_path = generated_root_path(CONCEPTNET_EDGES_FILENAME)
  reason = if File.exist?(out_path)
             conceptnet_edges_cache_rebuild_reason
           else
             "missing #{out_path}"
           end
  return unless reason

  raise "ConceptNet edges cache is not ready: #{reason}. Run ./bin/setup-corpora " \
        "to create #{CONCEPTNET_EDGES_FILENAME}; bin/build intentionally does not " \
        "rebuild corpus mirrors."
end

# --- Numberbatch vector build ---
# Source: numberbatch-en-19.08.txt (CC-BY-SA 4.0, pre-normalized). Resolved by numberbatch_txt_path:
#   NUMBERBATCH_TXT env (absolute path), then corpora/numberbatch/, corpora/, repo root,
#   then newest corpora/**/numberbatch*.txt
NUMBERBATCH_TXT = "numberbatch-en-19.08.txt"

def numberbatch_txt_path
  env = ENV["NUMBERBATCH_TXT"]
  return env if env && !env.empty? && File.file?(env)
  [
    File.join(REPO_ROOT, "corpora", "numberbatch", NUMBERBATCH_TXT),
    File.join(REPO_ROOT, "corpora", NUMBERBATCH_TXT),
    File.join(REPO_ROOT, NUMBERBATCH_TXT),
  ].each { |p| return p if File.file?(p) }
  [File.join(REPO_ROOT, "corpora", "numberbatch"), File.join(REPO_ROOT, "corpora"), REPO_ROOT].each do |dir|
    next unless Dir.exist?(dir)
    matches = Dir.glob(File.join(dir, "numberbatch*.txt"))
    return matches.max_by { |p| File.mtime(p) } if matches.any?
  end
  nil
end

# Set of every Numberbatch headword token (underscore spelling, /c/en/ shape).
# Reads the setup-time corpus mirror at generated/numberbatch_vectors.msgpack
# instead of streaming the raw 600 MB .txt during dict-build. Memoized per
# process; the mirror itself is rebuilt only when the source corpus changes
# (see ensure_numberbatch_vectors_cache!).
def numberbatch_corpus_token_set_cached
  return $numberbatch_corpus_token_set_cached unless $numberbatch_corpus_token_set_cached.nil?

  path = generated_root_path(NUMBERBATCH_VECTORS_FILENAME)
  unless File.exist?(path)
    raise "Numberbatch corpus mirror not found at #{path}. " \
          "Run ./bin/setup-corpora to create it."
  end

  s = Set.new
  BuildIoUtils.stream_read(path, hint: "numberbatch_corpus_token_set_cached") do |io|
    unpacker = MessagePack::Unpacker.new(io)
    header = unpacker.read
    unless header.is_a?(Hash) && header["format"] == NUMBERBATCH_STREAM_FORMAT
      raise "Numberbatch vectors file at #{path} has unexpected header #{header.inspect}; " \
            "expected #{NUMBERBATCH_STREAM_FORMAT.inspect}. Rerun ./bin/setup-corpora."
    end
    begin
      loop do
        rec = unpacker.read
        word, _bin = rec
        s.add(word)
      end
    rescue EOFError
      # end of stream
    end
  end
  $numberbatch_corpus_token_set_cached = s
end

# Cue and single-token target spellings from the setup-produced USF cache
# (generated/usf_associations.json) — every key, plus every per-cue target,
# rather than re-parsing the raw Cue_Target_Pairs.* shards during dict-build.
# Memoized per process.
def usf_corpus_word_set
  return $usf_corpus_word_set_cached unless $usf_corpus_word_set_cached.nil?

  path = generated_root_path(USF_ASSOCIATIONS_FILENAME)
  unless File.exist?(path)
    raise "USF associations cache not found at #{path}. " \
          "Run ./bin/setup-corpora to create it."
  end

  graph = JSON.parse(BuildIoUtils.read(path, encoding: "UTF-8", hint: "usf_corpus_word_set"))
  s = Set.new
  graph.each do |cue, targets|
    s.add(cue)
    targets.each_key { |t| s.add(t) if t.match?(/\A[a-z][a-z0-9'-]*\z/) }
  end
  $usf_corpus_word_set_cached = s
end

# ConceptNet English vocab for attestation checks; nil if assertions/cache unavailable.
def conceptnet_vocab_for_attestation
  gz_path = conceptnet_assertions_gz_path
  return nil unless gz_path

  cache_path = conceptnet_vocab_cache_output_gz_path(gz_path)
  return nil unless cache_path && File.file?(cache_path)
  return nil unless conceptnet_vocab_cache_usable?(gz_path, cache_path)

  conceptnet_vocab_load_cached(cache_path)
end

NUMBERBATCH_STREAM_FORMAT = "nbvec_stream_v1"

# Mirror the entire numberbatch corpus to disk as a streaming msgpack file:
#
#   record 0 (header): {"format" => NUMBERBATCH_STREAM_FORMAT, "dtype" => "f4_le"}
#   records 1..N      : [word_str, vec_binary]
#                       vec_binary = Numo::SFloat.cast(L2-normalized vec).to_binary
#                       (300 × 4 bytes for the 19.08 release; loader infers dim
#                       from bytesize so other releases work without a config bump.)
#
# Independent of word_dict — covers every lowercase token in the source corpus.
# Loaders (numberbatch_table, load_numberbatch_vectors_for_semantic_base_guard)
# stream the file and only materialize entries matching their dict-membership
# predicate, so a word transitioning from forbidden to common gains coverage
# without rebuilding this cache. Re-run only when corpora/numberbatch/*.txt
# changes — see ensure_numberbatch_vectors_cache! for the staleness check
# triggered automatically by rebuild_rhymecrime_dictionaries.
def save_numberbatch_vectors!
  txt_path = numberbatch_txt_path
  unless txt_path
    puts "Skipping Numberbatch vectors: no numberbatch*.txt under #{File.join(REPO_ROOT, 'corpora')} or repo root (set NUMBERBATCH_TXT=/path/to/file.txt)"
    return
  end
  require "numo/narray"

  ensure_generated_dict_dir!
  out_path = generated_root_path(NUMBERBATCH_VECTORS_FILENAME)
  count = 0
  dim_seen = nil
  BuildIoUtils.stream_write(out_path, hint: "save_numberbatch_vectors") do |out|
    packer = MessagePack::Packer.new(out)
    packer.write({ "format" => NUMBERBATCH_STREAM_FORMAT, "dtype" => "f4_le" })
    first = true
    BuildIoUtils.foreach(txt_path, encoding: "UTF-8",
                             hint: "save_numberbatch_vectors corpus_scan") do |line|
      if first
        first = false
        next
      end
      line = line.scrub
      parts = line.rstrip.split(" ")
      word = parts[0]&.scrub
      next unless word && word.match?(/\A[a-z][a-z_]*\z/)
      vec = parts[1..].map(&:to_f)
      mag = Math.sqrt(vec.sum { |v| v * v })
      next if mag == 0
      vec.map! { |v| (v / mag).round(5) }
      sf = Numo::SFloat.cast(vec)
      dim_seen ||= sf.size
      packer.write([word, sf.to_binary])
      count += 1
      packer.flush if (count % 50_000).zero?
    end
    packer.flush
  end
  size_mb = File.size(out_path) / 1024.0 / 1024.0
  puts "Wrote #{count} Numberbatch corpus vectors (dim=#{dim_seen}) to #{NUMBERBATCH_VECTORS_FILENAME} (#{size_mb.round(1)} MB)"
end

# Yields [word_underscored, Numo::SFloat] for every record in the streaming
# Numberbatch cache file. Caller decides what to do with each pair (filter,
# materialize, count, etc.) — the on-disk file is never fully buffered.
# Raises if the file is missing or its header doesn't match the current format
# (operator must regenerate via save_numberbatch_vectors! /
# ensure_numberbatch_vectors_cache!).
def each_numberbatch_vector_streaming(path)
  return enum_for(:each_numberbatch_vector_streaming, path) unless block_given?
  raise "Numberbatch vectors file missing: #{path} (run save_numberbatch_vectors!)" unless File.exist?(path)

  require "numo/narray"
  BuildIoUtils.stream_read(path, hint: "numberbatch_vectors") do |io|
    unpacker = MessagePack::Unpacker.new(io)
    header = unpacker.read
    unless header.is_a?(Hash) && header["format"] == NUMBERBATCH_STREAM_FORMAT
      raise "Numberbatch vectors file at #{path} has unexpected header #{header.inspect}; " \
            "expected #{NUMBERBATCH_STREAM_FORMAT.inspect}. Regenerate via save_numberbatch_vectors!."
    end
    begin
      loop do
        rec = unpacker.read
        word, bin = rec
        yield word, Numo::SFloat.from_binary(bin)
      end
    rescue EOFError
      # end of stream
    end
  end
end

# Stream-load the Numberbatch cache, materializing only entries whose underscored
# spelling is in keep_underscored (a Set or Array). Returns Hash<String, Numo::SFloat>.
# Pass nil to keep everything (rare; typically only useful for one-off audits — RAM
# footprint is ~3.6 GB for the full 19.08 corpus).
def load_numberbatch_vectors_streaming(path, keep_underscored: nil)
  keep = keep_underscored.is_a?(Set) ? keep_underscored : (keep_underscored && Set.new(keep_underscored))
  out = {}
  each_numberbatch_vector_streaming(path) do |word, sf|
    next if keep && !keep.include?(word)
    out[word] = sf
  end
  out
end
