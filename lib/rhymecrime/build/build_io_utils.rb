# frozen_string_literal: true

# Neutral repo file I/O (read/write/stream/gzip/csv): no build-pipeline path
# validation and no RHYMECRIME_BUILD_IO_LOG audit. Runtime code should require
# only this file; dict-build and other tools load build_io.rb, which wraps
# these methods with checks and optional JSONL logging.

require "json"
require "fileutils"

module BuildIoUtils
  class << self
    def read(path, encoding: "UTF-8", hint: nil)
      File.read(path, encoding: encoding)
    end

    def foreach(path, **kwargs, &block)
      k = kwargs.dup
      k.delete(:hint)
      File.foreach(path, **k, &block)
    end

    def binread(path, hint: nil)
      File.binread(path)
    end

    def write(path, content, encoding: "UTF-8", hint: nil)
      File.write(path, content, encoding: encoding)
    end

    def binwrite(path, content, hint: nil)
      File.binwrite(path, content)
    end

    # Prefer explicit mode string ("r", "rb", "w", "w+", …). hint is ignored here
    # but accepted for call-site parity with BuildIo.
    def open(path, *args, hint: nil, **kwargs, &block)
      File.open(path, *args, **kwargs, &block)
    end

    def stream_read(path, hint: nil, &block)
      open(path, "rb", hint: "stream_read #{hint}".strip, &block)
    end

    def stream_write(path, hint: nil, &block)
      open(path, "wb", hint: "stream_write #{hint}".strip, &block)
    end

    def csv_foreach(path, hint: nil, **csv_opts, &block)
      require "csv"
      CSV.foreach(path, **csv_opts, &block)
    end

    def gzip_read(path, encoding: "UTF-8", hint: nil, &block)
      require "zlib"
      Zlib::GzipReader.open(path, encoding: encoding, &block)
    end
  end
end
