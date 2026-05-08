# frozen_string_literal: true

# Central gate for generated-data pipeline file I/O: optional invariant checks
# and optional append-only JSONL audit log (shared across subprocesses when
# bin/build sets RHYMECRIME_BUILD_IO_LOG). Actual bytes flow through
# BuildIoUtils; this module adds validation + logging only.
#
# Env:
#   RHYMECRIME_BUILD_IO_VALIDATE — default ON (unset or empty). Set to 0 / false / no / off to disable.
#   RHYMECRIME_BUILD_IO_LOG      — append one JSON object per line per read/write

require "json"
require "fileutils"

require_relative "../build_io_utils"

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
      expanded = File.expand_path(path)
      return File.realpath(expanded) if File.exist?(expanded)

      # Walk up to the deepest existing ancestor, realpath it, and rejoin the
      # unresolved suffix. Required because:
      #  - REPO_ROOT (computed from __dir__) is auto-realpath'd by MRI's require, and
      #  - RHYMECRIME_BUILD_DIR is set from a shell `pwd` (logical, not -P), which
      #    does not follow symlinks.
      # If the user reaches the repo via a symlink alias (e.g. ~/later → ~/GitHub),
      # the two strings disagree even though they name the same file, and the
      # string-prefix `under?` checks below misclassify legitimate writes as
      # disallowed. realpath'ing through the symlink folds them back together.
      cur = expanded
      suffix = []
      loop do
        parent = File.dirname(cur)
        break if parent == cur

        if File.exist?(parent)
          return File.join(File.realpath(parent), File.basename(cur), *suffix)
        end
        suffix.unshift(File.basename(cur))
        cur = parent
      end
      expanded
    end

    def under?(path, root)
      p = abs(path)
      r = abs(root)
      p == r || p.start_with?(r + File::SEPARATOR)
    end

    def tmpish?(p)
      pa = abs(p)
      # /tmp and /var/folders are the macOS system tmp roots; /private/tmp and
      # /private/var/folders are their realpath'd canonical forms (since abs()
      # now realpath's where possible). Linux's /tmp doesn't symlink, so the
      # /private/* variants are no-ops there.
      pa.start_with?("/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/")
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
    end

    def read(path, encoding: "UTF-8", hint: nil)
      record!(:read, path, hint)
      BuildIoUtils.read(path, encoding: encoding, hint: hint)
    end

    def foreach(path, **kwargs, &block)
      hint = kwargs.delete(:hint) || "foreach"
      record!(:read, path, hint)
      BuildIoUtils.foreach(path, **kwargs, &block)
    end

    def binread(path, hint: nil)
      record!(:read, path, hint)
      BuildIoUtils.binread(path, hint: hint)
    end

    def write(path, content, encoding: "UTF-8", hint: nil)
      record!(:write, path, hint)
      BuildIoUtils.write(path, content, encoding: encoding, hint: hint)
    end

    def binwrite(path, content, hint: nil)
      record!(:write, path, hint)
      BuildIoUtils.binwrite(path, content, hint: hint)
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
      BuildIoUtils.open(path, *args, hint: hint, **kwargs, &block)
    end

    def stream_read(path, hint: nil, &block)
      open(path, "rb", hint: "stream_read #{hint}".strip, &block)
    end

    def stream_write(path, hint: nil, &block)
      open(path, "wb", hint: "stream_write #{hint}".strip, &block)
    end

    def csv_foreach(path, hint: nil, **csv_opts, &block)
      record!(:read, path, hint || "csv_foreach")
      BuildIoUtils.csv_foreach(path, hint: hint, **csv_opts, &block)
    end

    def gzip_read(path, encoding: "UTF-8", hint: nil, &block)
      record!(:read, path, hint || "gzip_read")
      BuildIoUtils.gzip_read(path, encoding: encoding, hint: hint, &block)
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
