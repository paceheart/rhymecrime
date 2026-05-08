# frozen_string_literal: true

module Rhymecrime
  # Lightweight wall-clock instrumentation. Wrap an expensive section in
  # Rhymecrime::Timing.measure(label) { ... }; the elapsed time is logged to
  # STDERR (and from there to CloudWatch under the Lambda runtime).
  #
  # Always on. There used to be a RHYMECRIME_LOG_TIMING env-var gate (set on
  # the Lambda function via template.yaml) so we could flip phase logging on
  # for a perf-debug pass and back off in steady state, but the overhead is
  # negligible (one warn call per phase) and the CloudWatch visibility is
  # worth keeping continuously — the knob was retired in May 2026.
  #
  # Why STDERR instead of a logger: the Lambda runtime captures both STDOUT
  # and STDERR into the function log group, and warn prepends nothing.
  # This keeps the lines greppable without pulling in a logger gem or carrying
  # a Logger instance through the request.
  #
  # Format is [timing] <label>: <ms>ms. Keep labels short and identifying
  # (include the cue word, key counts, etc.) so a single greppable line tells
  # you whether the bottleneck is find_related vs prefetch vs prune without
  # context lines.
  module Timing
    def self.measure(label)
      t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = yield
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000).round(1)
      warn "[timing] #{label}: #{elapsed_ms}ms"
      result
    end
  end
end
