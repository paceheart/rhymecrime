# encoding: utf-8
#
# VarCon (Variant Conversion Info) loader. VarCon is Kevin Atkinson's hand-verified mapping
# between American / British-ise / British-ize (OED) / Canadian / Australian English spellings,
# maintained as part of the aspell/SCOWL ecosystem since 2000. Complements the noisier Wiktionary
# signal: where Wiktionary says "X is an alternative form of Y" we additionally get VarCon's
# explicit regional preference direction and variant-strength markers.
#
# Input file: +corpora/varcon/varcon.txt+ (see setup.sh; BSD-style license per varcon-readme).
#
# Output shape (returned by +load_varcon+):
#
#   { variant_word => [
#       { target: <other_spelling>,
#         preferred: <:self | :target>,   # which side of the pair this file says is canonical
#         self_strength: <int>,           # preference score for +variant_word+ (lower = more preferred)
#         target_strength: <int>,         # preference score for +target+
#         scowl_level: <int | nil>,       # SCOWL rarity band; nil for entries without a cluster header
#         cluster_headword: <String>,     # headword of the cluster this row belongs to (for debugging)
#       }, ...
#     ]
#   }
#
# Shape mirrors +kaikki_variant_map+ so +corpus_variants.rb+ can merge the two signals cleanly.
# The +self_strength+/+target_strength+ scores encode VarCon's preference direction without
# requiring callers to re-parse the tag syntax.

require "set"

VARCON_DATA_PATH = File.expand_path("../../../corpora/varcon/varcon.txt", __dir__)

# Preference score per VarCon tag. Lower = more preferred for display. We bias toward American
# English because that's the app's assumed default (no regional-preference setting in the UI).
# Ranks inside each spelling category: bare > +.+ (equal-variant) > +v+ (variant) > +V+ (seldom)
# > +-+ (avoid-but-attested). Category-level ordering: American → British (either -ise or -ize) →
# Canadian → Australian → neutral/other. The +x+ ("improper variant") tag filters a spelling
# out entirely: VarCon uses it for attested misspellings kept in the file for completeness.
VARCON_TAG_SCORES = {
  "A" => 0,
  "A." => 1,
  "Av" => 5,
  "AV" => 15,
  "A-" => 50,
  "B" => 10,
  "B." => 11,
  "Bv" => 15,
  "BV" => 25,
  "B-" => 60,
  "Z" => 10,
  "Z." => 11,
  "Zv" => 15,
  "ZV" => 25,
  "Z-" => 60,
  "C" => 15,
  "C." => 16,
  "Cv" => 20,
  "CV" => 30,
  "C-" => 65,
  "D" => 20,
  "D." => 21,
  "Dv" => 25,
  "DV" => 35,
  "D-" => 70,
  "_" => 30,
  "_." => 31,
  "_v" => 35,
  "_V" => 45,
  "_-" => 75,
}.freeze

VARCON_IMPROPER_TAGS = Set.new(%w[Ax Bx Zx Cx Dx _x]).freeze

# Maximum SCOWL level to trust. VarCon's own readme notes that clusters with headwords at level
# > 80 are "likely not legal words" and weren't verified during the 5.0 cleanup pass. Cap at 80
# so we skip the long tail of rarely-attested variants the maintainer themselves didn't vouch for.
VARCON_MAX_SCOWL_LEVEL = 80

VARCON_CLUSTER_HEADER_RE = /\A#\s*(\S+)\s*(?:<(\w+)>\s*)?(?:\(level\s+(\d+)\))?/.freeze

# Return the variant map described above, or +{}+ if the file is missing (keeps builds running
# on machines that haven't pulled VarCon yet).
def load_varcon
  variant_map = Hash.new { |h, k| h[k] = [] }
  return variant_map unless File.exist?(VARCON_DATA_PATH)

  current_headword = nil
  current_level = nil
  skipped_by_level = 0
  skipped_improper = 0
  pair_seen = Set.new

  # VarCon has a handful of Latin-1-encoded headwords (+fuehrer/führer+, +Roentgen/Röntgen+).
  # Our dict only carries ASCII headwords, so we transcode with +:replace+ to swallow the bad
  # bytes and then skip any spelling that still contains non-ASCII below.
  File.foreach(VARCON_DATA_PATH, chomp: true, encoding: "ISO-8859-1:UTF-8",
               invalid: :replace, undef: :replace) do |line|
    stripped = line.strip
    next if stripped.empty?

    if stripped.start_with?("#")
      if (m = VARCON_CLUSTER_HEADER_RE.match(stripped))
        current_headword = m[1]
        current_level = m[3] ? m[3].to_i : nil
      end
      next
    end

    if current_level && current_level > VARCON_MAX_SCOWL_LEVEL
      skipped_by_level += 1
      next
    end

    # Drop the trailing +| <POS>+ / +| sense+ / +| -- pl+ annotations. Our app has no POS or sense
    # context at display time, so we conservatively merge the POS-qualified groups into a single
    # pair-set per cluster; voting across those rows aggregates the preference correctly for
    # cases like +practice/practise+ (noun-preferred +practice+ in US English across both POS).
    body = stripped.split(" | ", 2).first

    entries = body.split(" / ").map { |e| parse_varcon_entry(e) }.compact
    next if entries.size < 2

    # Skip possessive rows (+acknowledgment's / acknowledgement's+) — our dict doesn't carry
    # +'s+ headwords, so emitting these pairs would be dead weight.
    next if entries.any? { |e| e[:spelling].include?("'") }

    # Filter spellings whose only tags are improper-variant markers +x+.
    entries.reject! do |e|
      if e[:tags].all? { |t| VARCON_IMPROPER_TAGS.include?(t) }
        skipped_improper += 1
        true
      else
        false
      end
    end
    next if entries.size < 2

    # Emit each unordered pair of spellings on this row, with VarCon's preference direction
    # captured via +self_strength+ / +target_strength+.
    entries.each_with_index do |e1, i|
      entries.each_with_index do |e2, j|
        next if i >= j
        s1, s2 = e1[:spelling], e2[:spelling]
        next if s1 == s2
        sc1 = entry_preference_score(e1)
        sc2 = entry_preference_score(e2)

        variant_map[s1] << {
          target: s2,
          preferred: (sc1 <= sc2) ? :self : :target,
          self_strength: sc1,
          target_strength: sc2,
          scowl_level: current_level,
          cluster_headword: current_headword,
        }
        variant_map[s2] << {
          target: s1,
          preferred: (sc2 <= sc1) ? :self : :target,
          self_strength: sc2,
          target_strength: sc1,
          scowl_level: current_level,
          cluster_headword: current_headword,
        }
        pair_seen << [s1, s2].sort
      end
    end
  end

  puts "VarCon: #{pair_seen.size} unique variant pairs loaded " \
       "(#{variant_map.values.map(&:size).sum} evidence rows; " \
       "skipped #{skipped_by_level} rows over level #{VARCON_MAX_SCOWL_LEVEL}, " \
       "#{skipped_improper} spellings tagged improper)"
  variant_map
end

# Parse a single +A Bv C: acknowledgment+ entry into +{ spelling:, tags: }+. Column numbers
# (+A B 1: aerie+) are treated as opaque and dropped: they link rows within a cluster that share
# the same column assignment, but our pair-emission logic already iterates every row, so we don't
# need them.
def parse_varcon_entry(raw)
  tag_part, _, spelling = raw.rpartition(": ")
  return nil if spelling.nil? || spelling.empty?
  spelling = spelling.strip.downcase
  return nil if spelling.empty?
  # Skip non-ASCII headwords (+führer+, +röntgen+) — our dict can't represent them anyway.
  return nil unless spelling.ascii_only?
  tags = tag_part.split(/\s+/).reject { |t| t.empty? || t =~ /\A\d+\z/ }
  { spelling: spelling, tags: tags }
end

# Preference score = minimum score over an entry's tags. Unrecognised tags score 99 so a known
# tag always beats them. We take the min rather than summing so a spelling that is preferred in
# _any_ region beats one that's everywhere a variant.
def entry_preference_score(entry)
  entry[:tags].map { |t| VARCON_TAG_SCORES[t] || 99 }.min || 99
end
