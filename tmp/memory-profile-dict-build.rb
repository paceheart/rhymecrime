#!/usr/bin/env ruby
# Allocation / memory hot-spot profile for bin/dict-build.
#
# Why not MemoryProfiler? It records *every* allocation; dict-build allocates on the order of
# hundreds of millions of objects, so the process appears hung with zero output for a long time.
#
# StackProf :object mode samples every Nth new object (see interval below). Overhead is modest and
# normal dict-build progress lines still print.
#
# Usage:
#   ruby tmp/memory-profile-dict-build.rb                    # skip ConceptNet/Numberbatch
#   ruby tmp/memory-profile-dict-build.rb --full
#   STACKPROF_OBJECT_INTERVAL=50 ruby tmp/memory-profile-dict-build.rb   # coarser = faster
#
# Outputs:
#   tmp/stackprof-dict-build-object.dump   (aggregated; use stackprof CLI for drill-down)
#   tmp/stackprof-dict-build-object.txt    (human summary)
#
# Do not pass raw: true for a full dict-build — it embeds every sample in the Marshal blob (multi-GB)
# and IO.binread / Marshal.load can fail with Errno::EINVAL on macOS.

$stderr.sync = true
$stdout.sync = true

require "stackprof"
require "stackprof/report"

repo = File.expand_path("..", __dir__)
dict_dir = File.join(repo, "lib", "rhymecrime", "dict")
dump = File.join(repo, "tmp", "stackprof-dict-build-object.dump")
text = File.join(repo, "tmp", "stackprof-dict-build-object.txt")

interval = (ENV["STACKPROF_OBJECT_INTERVAL"] || "20").to_i
interval = 1 if interval < 1

$stderr.puts "[dict-build profile] StackProf object sampling → #{dump} (interval=#{interval}, every Nth allocation)"
$stderr.puts "[dict-build profile] You should see normal dict-build log lines below…"

if ARGV.include?("--full")
  ENV.delete("RHYMECRIME_DICT_SKIP_CONCEPTNET_NUMBERBATCH")
else
  ENV["RHYMECRIME_DICT_SKIP_CONCEPTNET_NUMBERBATCH"] = "1"
end

$LOAD_PATH.unshift File.join(repo, "lib")

StackProf.run(mode: :object, out: dump, interval: interval) do
  Dir.chdir(dict_dir) do
    load File.join(dict_dir, "dict.rb")
    rebuild_rhymecrime_dictionaries
  end
end

$stderr.puts "[dict-build profile] Building text report → #{text}"

data = File.open(dump, "rb") { |f| Marshal.load(f) }
report = StackProf::Report.new(data)
File.open(text, "w") do |io|
  io.puts "# StackProf object samples (interval=#{interval})"
  io.puts "# Frames under lib/rhymecrime/dict/ (project code):"
  io.puts
  report.print_text(true, 80, [dict_dir], nil, nil, nil, io)
  io.puts
  io.puts "# Global top frames (includes stdlib/gems):"
  io.puts
  report.print_text(true, 50, nil, nil, nil, nil, io)
end

$stderr.puts "[dict-build profile] Done."
puts "Wrote #{text}"
puts "Dump: #{dump}  (e.g. stackprof #{dump} --method 'SomeClass#foo')"
