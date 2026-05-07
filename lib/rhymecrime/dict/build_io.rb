# frozen_string_literal: true

# Central gate for generated-data pipeline file I/O: optional invariant checks
# and optional append-only JSONL audit log (shared across subprocesses when
# bin/build sets RHYMECRIME_BUILD_IO_LOG).
#
# Env:
#   RHYMECRIME_BUILD_IO_VALIDATE — default ON (unset or empty). Set to 0 / false / no / off to disable.
#   RHYMECRIME_BUILD_IO_LOG      — append one JSON object per line per read/write
#   RHYMECRIME_BUILD_IO_VERBOSE  — truthy: $stderr line per read/write

require "json"
require "fileutils"

module BuildIo
  REPO_ROOT = File.expand_path("../../..", __dir__).freeze
  CORPORA_ROOT = File.join(REPO_ROOT, "corpora").freeze
  CURATED_ROOT = File.join(REPO_ROOT, "curated").freeze
  LIB_ROOT = File.join(REPO_ROOT, "lib").freeze
  GENERATED_ROOT = File.join(REPO_ROOT, "generated").freeze
  GENERATED_CURRENT = File.join(GENERATED_ROOT, "current").freeze
  LEGACY_VARIANT_BASENAMES = %w[spelling_variants_auto.txt hyphen_variant_map.json].freeze
  BUILD_STAMP_RE = /\A\d{8}T\d{6}\z/.freeze

  class BuildIoInvariantError < RuntimeError; end

  class << self
    def validate?
      v = ENV["RHYMECRIME_BUILD_IO_VALIDATE"]
      return true if v.nil? || v.to_s.strip.empty?

      truthy?(v)
    end

    def verbose?
      truthy?(ENV["RHYMECRIME_BUILD_IO_VERBOSE"])
    end

    def log_path
      p = ENV["RHYMECRIME_BUILD_IO_LOG"]
      (p && !p.empty?) ? File.expand_path(p) : nil
    end

    def truthy?(v)
      v && !%w[0 false no off].include?(v.to_s.strip.downcase)
    end

    def build_dir
      d = ENV["RHYMECRIME_BUILD_DIR"]
      return nil if d.nil? || d.to_s.empty?

      File.expand_path(d, REPO_ROOT)
    end

    def bootstrap_mode?
      ENV["RHYMECRIME_BUILD_MODE"].to_s == "bootstrap"
    end

    def final_mode?
      ENV["RHYMECRIME_BUILD_MODE"].to_s == "final"
    end

    def abs(path)
      File.expand_path(path)
    end

    def under?(path, root)
      p = abs(path)
      r = abs(root)
      p == r || p.start_with?(r + File::SEPARATOR)
    end

    def tmpish?(p)
      pa = abs(p)
      pa.start_with?("/tmp/") || pa.start_with?("/var/folders/")
    end

    # Direct file under generated/ (not in generated/current/… or generated/<stamp>/…).
    def generated_root_leaf?(path)
      p = abs(path)
      return false unless under?(p, GENERATED_ROOT)

      File.dirname(p) == GENERATED_ROOT
    end

    def legacy_flat_variant_file?(path)
      p = abs(path)
      return false unless generated_root_leaf?(p)

      LEGACY_VARIANT_BASENAMES.include?(File.basename(p))
    end

    def generated_timestamped_build_dir(path)
      p = abs(path)
      return nil unless under?(p, GENERATED_ROOT)

      rel = p.delete_prefix(GENERATED_ROOT + File::SEPARATOR)
      first = rel.split(File::SEPARATOR, 2).first
      return nil unless first&.match?(BUILD_STAMP_RE)

      File.join(GENERATED_ROOT, first)
    end

    def sibling_timestamped_build_read?(path)
      bd = build_dir
      return false unless bd

      stamped_dir = generated_timestamped_build_dir(path)
      return false unless stamped_dir

      abs(stamped_dir) != abs(bd)
    end

    def read_forbidden?(path)
      p = abs(path)
      return true if sibling_timestamped_build_read?(p)

      if bootstrap_mode?
        return true if under?(p, GENERATED_CURRENT)
        return true if legacy_flat_variant_file?(p)
      end
      false
    end

    # Returns true when write should be rejected under validation rules.
    def write_forbidden?(path)
      p = abs(path)
      return false if tmpish?(p)
      return true unless under?(p, REPO_ROOT)

      bd = build_dir
      if bootstrap_mode? && bd
        return false if under?(p, bd)
        return false if generated_root_leaf?(p)
        return true
      end

      if final_mode? && bd
        return false if under?(p, bd)
        return false if generated_root_leaf?(p)
        return true
      end

      return false if bd && under?(p, bd)
      return false if under?(p, GENERATED_ROOT)
      return false if under?(p, CORPORA_ROOT) || under?(p, CURATED_ROOT) || under?(p, LIB_ROOT)

      true
    end

    def validate_read!(path, hint)
      return unless validate?
      if sibling_timestamped_build_read?(path)
      raise BuildIoInvariantError,
            "disallowed READ from sibling timestamped build #{abs(path).inspect} " \
            "hint=#{hint.inspect} (active_build_dir=#{build_dir.inspect})"
    end
    return unless read_forbidden?(abs(path))

    raise BuildIoInvariantError,
          "disallowed READ #{abs(path).inspect} hint=#{hint.inspect} " \
          "(bootstrap=#{bootstrap_mode?} build_dir=#{build_dir.inspect})"
  end

  def validate_write!(path, hint)
    return unless validate?
    return unless write_forbidden?(path)

    raise BuildIoInvariantError,
            "disallowed WRITE #{abs(path).inspect} hint=#{hint.inspect} " \
            "(bootstrap=#{bootstrap_mode?} final=#{final_mode?} build_dir=#{build_dir.inspect})"
    end

    def record!(kind, path, hint)
      p = abs(path)
      validate_read!(p, hint) if kind == :read
      validate_write!(p, hint) if kind == :write

      if (lp = log_path)
        FileUtils.mkdir_p(File.dirname(lp))
        rec = {
          "kind" => kind.to_s,
          "path" => p,
          "hint" => hint,
          "build_mode" => ENV["RHYMECRIME_BUILD_MODE"],
          "ts" => Time.now.utc.iso8601(3),
        }
        File.open(lp, "a", encoding: "UTF-8") do |f|
          f.flock(File::LOCK_EX)
          f.puts(JSON.generate(rec))
        ensure
          f.flock(File::LOCK_UN)
        end
      end

      return unless verbose?

      warn "[generated_io] #{kind} #{p} #{hint}"
    end

    def read(path, encoding: "UTF-8", hint: nil)
      record!(:read, path, hint)
      File.read(path, encoding: encoding)
    end

    def foreach(path, **kwargs, &block)
      hint = kwargs.delete(:hint) || "foreach"
      record!(:read, path, hint)
      File.foreach(path, **kwargs, &block)
    end

    def binread(path, hint: nil)
      record!(:read, path, hint)
      File.binread(path)
    end

    def write(path, content, encoding: "UTF-8", hint: nil)
      record!(:write, path, hint)
      File.write(path, content, encoding: encoding)
    end

    def binwrite(path, content, hint: nil)
      record!(:write, path, hint)
      File.binwrite(path, content)
    end

    # Prefer explicit mode string ("r", "rb", "w", "w+", …); hint should name the operation.
    # Integer File::Constants modes are passed through without recording (rare in this codebase).
    def open(path, *args, hint: nil, **kwargs, &block)
      mode = args.first
      if mode.is_a?(String)
        first = mode[0]
        plus = mode.include?("+")
        record!(:read, path, hint) if first == "r" || (plus && %w[w a].include?(first))
        record!(:write, path, hint) if %w[w a].include?(first) || (plus && first == "r")
      end
      File.open(path, *args, **kwargs, &block)
    end

    # Block-form helpers for streaming reads/writes (e.g. msgpack streaming).
    # The IO is yielded; caller drives parsing/encoding without ever materializing
    # the whole file. One audit record is logged at open time with a "stream_*"
    # hint so the bin/build report shows these alongside one-shot read/writes.
    def stream_read(path, hint: nil, &block)
      open(path, "rb", hint: "stream_read #{hint}".strip, &block)
    end

    def stream_write(path, hint: nil, &block)
      open(path, "wb", hint: "stream_write #{hint}".strip, &block)
    end

    # Audit-aware wrapper around CSV.foreach. Records one read for `path` then
    # streams rows through the supplied block exactly like CSV.foreach does
    # (same kwargs: headers:, encoding:, etc.).
    def csv_foreach(path, hint: nil, **csv_opts, &block)
      require "csv"
      record!(:read, path, hint || "csv_foreach")
      CSV.foreach(path, **csv_opts, &block)
    end

    # Audit-aware wrapper around Zlib::GzipReader.open. Records the read up
    # front, then yields the open GzipReader IO to the caller. encoding:
    # defaults to UTF-8 to match the existing call sites that wanted text.
    def gzip_read(path, encoding: "UTF-8", hint: nil, &block)
      require "zlib"
      record!(:read, path, hint || "gzip_read")
      Zlib::GzipReader.open(path, encoding: encoding, &block)
    end

    # Pretty summary for bin/build (reads stdin or path to JSONL).
    def print_build_report(io: $stdout, path: nil)
      path ||= log_path
      unless path && File.file?(path)
        io.puts "(no RHYMECRIME_BUILD_IO_LOG file or empty: #{path.inspect})"
        return
      end

      reads = []
      writes = []
      File.foreach(path, chomp: true, encoding: "UTF-8") do |line|
        next if line.strip.empty?

        rec = JSON.parse(line)
        case rec["kind"]
        when "read" then reads << rec["path"]
        when "write" then writes << rec["path"]
        end
      end
      io.puts "=== build I/O audit (#{path}) ==="
      io.puts "--- unique READ paths (#{reads.uniq.size}) ---"
      reads.uniq.sort.each { |p| io.puts p }
      io.puts "--- unique WRITE paths (#{writes.uniq.size}) ---"
      writes.uniq.sort.each { |p| io.puts p }
    end
  end
end
