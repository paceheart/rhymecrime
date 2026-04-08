# encoding: utf-8
# Loads Wiktionary data from kaikki.org/wiktextract filtered English JSONL.
# Provides POS-aware pronunciation loading and inflected form maps.

require 'json'
require 'zlib'
require 'set'
require_relative 'ipa_to_arpabet'
require_relative 'pronunciation'

# Kaikki extract (large; often gitignored) under corpora/wiktionary/.
WIKTIONARY_DATA_PATH = File.expand_path("../corpora/wiktionary/kaikki-english-filtered.jsonl.gz", __dir__)

SKIP_FORM_TAGS = Set.new(%w[
  alternative obsolete dialectal nonstandard archaic
  rare misspelling Eye-dialect Latinization
])

INFLECTION_TAGS = {
  "noun" => [["plural"]],
  "verb" => [
    ["past"],
    ["participle", "past"],
    ["participle", "present"],
    ["present", "singular", "third-person"],
  ],
  "adj" => [["comparative"], ["superlative"]],
}

# Load kaikki.org filtered JSONL.
# Returns [pron_hash, forms_map, pos_map]
#   pron_hash: { word => [Pronunciation, ...] }  (same format as load_cmudict)
#   forms_map: { base_word => [[inflected_form, base_word], ...] }
#   pos_map: { word => Set<String> } union of Kaikki "pos" per lemma (Layer A ∩ WordNet in dict_lib)
def load_wiktionary
  path = WIKTIONARY_DATA_PATH
  unless File.exist?(path)
    puts "Wiktionary data not found at #{path}; skipping."
    return [{}, {}, {}]
  end

  pron_hash = Hash.new { |h, k| h[k] = [] }
  forms_map = Hash.new { |h, k| h[k] = [] }
  pos_map = {}
  total = 0; converted = 0; skipped = 0

  Zlib::GzipReader.open(path, encoding: 'UTF-8') do |gz|
    gz.each_line do |line|
      obj = JSON.parse(line) rescue next

      word = obj["word"].to_s.downcase.strip
      next if word.empty? || word.match?(/\d/) || word.start_with?("'") || word.include?(" ")

      pos = obj["pos"].to_s
      next if pos == "name"

      (pos_map[word] ||= Set.new).add(pos) unless pos.empty?

      sounds = obj["sounds"]
      next if sounds.nil? || sounds.empty?
      total += 1

      ipa_strings = pick_ga_sounds(sounds)
      next if ipa_strings.empty?

      added = false
      ipa_strings.each do |ipa|
        arpabet = IpaToArpabet.convert(ipa)
        next if arpabet.nil? || arpabet.empty?

        pron = Pronunciation.new(arpabet)
        next if pron.empty?

        unless pron_hash[word].any? { |existing| existing.phonemes == pron.phonemes }
          pron_hash[word] << pron
          added = true
        end
      end

      if added
        converted += 1
      else
        skipped += 1
      end

      collect_inflected_forms(obj, word, pos, forms_map)
    end
  end

  puts "Wiktionary: #{total} entries with pronunciation, #{converted} converted, #{skipped} skipped"
  puts "Wiktionary: #{pron_hash.size} unique words, #{forms_map.size} words with inflected forms"
  [pron_hash, forms_map, pos_map]
end

def pick_ga_sounds(sounds)
  ga = []
  unspecified = []
  other = []

  sounds.each do |s|
    ipa = s["ipa"]
    next if ipa.nil? || ipa.empty?
    tags = s["tags"] || []

    if tags.any? { |t| t.include?("General-American") || t.include?("US") || t.include?("GenAm") }
      ga << ipa
    elsif tags.empty?
      unspecified << ipa
    else
      other << ipa
    end
  end

  result = ga.empty? ? (unspecified.empty? ? other : unspecified) : ga
  result.uniq
end

def collect_inflected_forms(obj, base_word, pos, forms_map)
  forms = obj["forms"]
  return if forms.nil? || forms.empty?

  valid_tag_sets = INFLECTION_TAGS[pos]
  return if valid_tag_sets.nil?

  forms.each do |f|
    form = f["form"].to_s.downcase.strip
    next if form.empty? || form.include?(" ") || form == base_word
    tags = f["tags"] || []

    next if tags.any? { |t| SKIP_FORM_TAGS.include?(t) }

    next unless valid_tag_sets.any? { |required| required.all? { |rt| tags.include?(rt) } }

    unless forms_map[base_word].any? { |existing_form, _| existing_form == form }
      forms_map[base_word] << [form, base_word]
    end
  end
end
