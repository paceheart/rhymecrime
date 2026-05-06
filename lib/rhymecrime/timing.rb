# frozen_string_literal: true

module Rhymecrime
  # Lightweight wall-clock instrumentation. Wrap an expensive section in
  # Rhymecrime::Timing.measure(label) { ... }; when RHYMECRIME_LOG_TIMING=1
  # is set, the elapsed time is logged to STDERR (and from there to CloudWatch
  # under the Lambda runtime). Otherwise measure is a single ENV check
  # plus a yield — call-site overhead is negligible on the hot path.
  #
  # Why STDERR instead of a logger: the Lambda runtime captures both STDOUT
  # and STDERR into the function log group, and warn prepends nothing.
  # This keeps the lines greppable without pulling in a logger gem or carrying
  # a Logger instance through the request.
  #
  # The template.yaml deployed config sets RHYMECRIME_LOG_TIMING=1 on the
  # Lambda function so we get ongoing visibility into the set_related path —
  # set_related on a common cue (e.g. cat, 3K+ related lemmas) does ~150
  # sequential BatchGetItem round-trips and is the realistic worst case for
  # Lambda's 29-second hard cap. Flip the env var off (or remove the line) once
  # you're done iterating; the overhead is small but not zero (a warn call
  # per phase).
  #
  # Format is [timing] <label>: <ms>ms. Keep labels short and identifying
  # (include the cue word, key counts, etc.) so a single greppable line tells
  # you whether the bottleneck is find_related vs prefetch vs prune without
  # context lines.
  module Timing
    def self.enabled?
      ENV["RHYMECRIME_LOG_TIMING"].to_s == "1"
    end

    def self.measure(label)
      return yield unless enabled?

      t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = yield
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000).round(1)
      warn "[timing] #{label}: #{elapsed_ms}ms"
      result
    end
  end
end
