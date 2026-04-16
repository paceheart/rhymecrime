# encoding: utf-8
# Loads Wiktionary data from kaikki.org/wiktextract filtered English JSONL.
# Provides POS-aware pronunciation loading and inflected form maps.

require 'json'
require 'zlib'
require 'set'
require_relative 'ipa_to_arpabet'
require_relative 'pronunciation'

# Kaikki extract (large; often gitignored) under corpora/wiktionary/.
WIKTIONARY_DATA_PATH = File.expand_path("../../../corpora/wiktionary/kaikki-english-filtered.jsonl.gz", __dir__)

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

# Empty Kaikki verb morphology (see +load_wiktionary+ fourth return value).
def empty_kaikki_verb_morphology
  {
    past_surfaces: Set.new,
    lemmas_with_present_participle: Set.new,
    verb_paradigm_forms: Hash.new { |h, k| h[k] = Set.new },
    # Surfaces that appear as a non-lemma form in some verb paradigm whose lemma has an explicit
    # present participle in Kaikki — Inflect *-ing* from that surface is redundant (*snuck*→*snucking*).
    non_lemma_surfaces_in_pp_paradigm: Set.new
  }
end

# Load kaikki.org filtered JSONL.
# Returns [pron_hash, forms_map, pos_map, kaikki_verb_morph, kaikki_capitalized_only]
#   pron_hash: { word => [Pronunciation, ...] }  (same format as load_cmudict)
#   forms_map: { base_word => [[inflected_form, base_word], ...] }
#   pos_map: { word => Set<String> } union of Kaikki "pos" per lemma (Layer A ∩ WordNet in dict.rb)
#   kaikki_verb_morph: Hash with :past_surfaces (Set), :lemmas_with_present_participle (Set),
#     :verb_paradigm_forms (lemma => Set of attested inflected surfaces), and
#     :non_lemma_surfaces_in_pp_paradigm (Set) for morph gating.
#   kaikki_capitalized_only: Set<String> of lowercased headwords that never appeared with a
#     lowercase headword in Kaikki (proper-noun signal for the Wiktionary floor / compute_frequency).
def load_wiktionary
  path = WIKTIONARY_DATA_PATH
  unless File.exist?(path)
    puts "Wiktionary data not found at #{path}; skipping."
    m = empty_kaikki_verb_morphology
    return [{}, {}, {}, m, Set.new]
  end

  pron_hash = Hash.new { |h, k| h[k] = [] }
  forms_map = Hash.new { |h, k| h[k] = [] }
  pos_map = {}
  verb_morph = empty_kaikki_verb_morphology
  kaikki_has_capitalized = Set.new
  kaikki_has_lowercase = Set.new
  total = 0; converted = 0; skipped = 0

  Zlib::GzipReader.open(path, encoding: 'UTF-8') do |gz|
    gz.each_line do |line|
      obj = JSON.parse(line) rescue next

      word_raw = obj["word"].to_s.strip
      word = word_raw.downcase
      next if word.empty? || word.match?(/\d/) || word.start_with?("'") || word.include?(" ")

      # Record case of the headword before any pos-based skipping: "name"-tagged and capitalized
      # "noun" entries (Modena, Batavia, Cabot, Srebrenica) are the proper-noun signal we want.
      if word_raw == word
        kaikki_has_lowercase.add(word)
      else
        kaikki_has_capitalized.add(word)
      end

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

      collect_inflected_forms(obj, word, pos, forms_map, verb_morph)
    end
  end

  verb_morph[:lemmas_with_present_participle].each do |lemma|
    verb_morph[:verb_paradigm_forms][lemma].each do |form|
      verb_morph[:non_lemma_surfaces_in_pp_paradigm].add(form) if form != lemma
    end
  end

  puts "Wiktionary: #{total} entries with pronunciation, #{converted} converted, #{skipped} skipped"
  puts "Wiktionary: #{pron_hash.size} unique words, #{forms_map.size} words with inflected forms"
  kaikki_capitalized_only = kaikki_has_capitalized - kaikki_has_lowercase
  puts "Wiktionary: #{kaikki_capitalized_only.size} headwords only ever capitalized (proper-noun signal)"
  [pron_hash, forms_map, pos_map, verb_morph, kaikki_capitalized_only]
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

def collect_inflected_forms(obj, base_word, pos, forms_map, verb_morph = nil)
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

    if verb_morph && pos == "verb"
      if tags.include?("past") || (tags.include?("participle") && tags.include?("past"))
        verb_morph[:past_surfaces].add(form)
      end
      verb_morph[:lemmas_with_present_participle].add(base_word) if tags.include?("participle") && tags.include?("present")
      verb_morph[:verb_paradigm_forms][base_word].add(form)
    end

    unless forms_map[base_word].any? { |existing_form, _| existing_form == form }
      forms_map[base_word] << [form, base_word]
    end
  end
end
