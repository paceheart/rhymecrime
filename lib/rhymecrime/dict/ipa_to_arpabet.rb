# Converts IPA (International Phonetic Alphabet) transcriptions to ARPAbet
# phonemes as used by CMUDict and rhymecrime's Pronunciation class.
#
# Handles stress markers (ˈ primary, ˌ secondary), syllable boundaries,
# and the core American English phoneme inventory.

module IpaToArpabet
  # Diphthongs and affricates must be checked before their component parts.
  # Ordered longest-first to ensure greedy matching.
  IPA_TO_ARPABET = [
    # Affricates (multi-codepoint — check first)
    ["t͡ʃ", "CH"],
    ["d͡ʒ", "JH"],
    ["tʃ",  "CH"],
    ["dʒ",  "JH"],

    # Diphthongs (before monophthongs)
    ["aɪ",  "AY"],
    ["a͜ɪ", "AY"],
    ["aʊ",  "AW"],
    ["eɪ",  "EY"],
    ["e͜ɪ", "EY"],
    ["oʊ",  "OW"],
    ["ɔɪ",  "OY"],
    ["ɔː",  "AO"],
    ["ɑː",  "AA"],

    # R-colored vowels
    ["ɝː",  "ER"],
    ["ɝ",   "ER"],
    ["ɜː",  "ER"],
    ["ɜ",   "ER"],
    ["ɚ",   "ER"],

    # Monophthongs
    ["iː",  "IY"],
    ["i",   "IY"],
    ["ɪ",   "IH"],
    ["ɛ",   "EH"],
    ["æ",   "AE"],
    ["ɑ",   "AA"],
    ["ɒ",   "AA"],
    ["ɔ",   "AO"],
    ["ʊ",   "UH"],
    ["uː",  "UW"],
    ["u",   "UW"],
    ["ʌ",   "AH"],
    ["ə",   "AH"],
    ["ɐ",   "AH"],
    ["a",   "AE"],
    ["e",   "EH"],
    ["o",   "OW"],

    # Consonants
    ["ŋ",   "NG"],
    ["θ",   "TH"],
    ["ð",   "DH"],
    ["ʃ",   "SH"],
    ["ʒ",   "JH"], # align with CMU ZH → JH global merge in +apply_shared_arphabet_phoneme_string_normalizations+
    ["ɹ",   "R"],
    ["ɡ",   "G"],  # IPA ɡ (U+0261)
    ["ɾ",   "D"],  # alveolar flap
    ["ɫ",   "L"],  # dark l
    ["ç",   "HH"],
    ["h",   "HH"],
    ["j",   "Y"],
    ["p",   "P"],
    ["b",   "B"],
    ["t",   "T"],
    ["d",   "D"],
    ["k",   "K"],
    ["g",   "G"],  # ASCII g
    ["f",   "F"],
    ["v",   "V"],
    ["s",   "S"],
    ["z",   "Z"],
    ["m",   "M"],
    ["n",   "N"],
    ["l",   "L"],
    ["r",   "R"],
    ["w",   "W"],
    ["x",   "K"],  # voiceless velar fricative — approximate
  ]

  SKIP_CHARS = Set.new([
    "ː", "ˑ",        # length marks
    ".",              # syllable boundary
    "ʔ",             # glottal stop
    "ʰ", "ʷ", "ʲ",  # aspiration/labialization/palatalization
    "̩", "̯", "̃",    # combining diacritics (syllabic, non-syllabic, nasalized)
    "̪", "̠", "̝", "̊", "̈", "̥", "ᵊ", # more diacritics
    "˞",             # rhoticity
    "ˈ", "ˌ",        # stress markers (handled separately before mapping)
    "ˈ", "ˌ",        # sometimes different unicode codepoints
    " ",              # spaces between phonemes
    "(",  ")",        # optional segments
    "/",              # IPA delimiters
  ])

  VOWELS = Set.new(%w[AA AE AH AO AW AY EH ER EY IH IY OW OY UH UW])

  IPA_TO_ARPABET.each { |pair| pair[0].freeze; pair[1].freeze }

  # Prebuilt "AA0".."UW2" tokens — avoids "#{arpa}#{pending_stress}" per vowel.
  STRESSED_VOWEL_TOKEN = {}.tap do |h|
    VOWELS.each do |v|
      h[[v, 0]] = "#{v}0".freeze
      h[[v, 1]] = "#{v}1".freeze
      h[[v, 2]] = "#{v}2".freeze
    end
  end.freeze

  # Convert an IPA string like "/ˈsɛlfi/" to an array of ARPAbet phonemes
  # with stress markers on vowels (e.g. ["S", "EH1", "L", "F", "IY0"]).
  # Returns nil if conversion fails.
  def self.convert(ipa_str)
    return nil if ipa_str.nil? || ipa_str.empty?

    cleaned = ipa_str.gsub(%r{[/\[\]]}, '')
    # Wiktionary uses +(ɹ)+ to mark a rhotic as optional so a single transcription
    # can cover both rhotic and non-rhotic dialects. rhymecrime is rhotic, so
    # promote optional rhotics to required before the generic optional-segment
    # strip below; otherwise +/snɑː(ɹ)f/+ would lose its R.
    cleaned = cleaned.gsub(/\(([ɹr])\)/, '\1')
    # Remove remaining optional segments (e.g. "(ʊ)" in /ˈpɹəʊtə(ʊ)stɑː/).
    cleaned = cleaned.gsub(/\([^)]*\)/, '')

    tokens = []
    pos = 0
    len = cleaned.length
    pending_stress = 0  # 0=unstressed, 1=primary, 2=secondary

    while pos < len
      char = cleaned[pos]

      if char == "ˈ" || char == "\u02C8"
        pending_stress = 1
        pos += 1
        next
      elsif char == "ˌ" || char == "\u02CC"
        pending_stress = 2
        pos += 1
        next
      end

      # Try longest match (substring by character index — no chars[].join per attempt)
      matched = false
      IPA_TO_ARPABET.each do |ipa, arpa|
        ipalen = ipa.length
        next if pos + ipalen > len
        next unless cleaned[pos, ipalen] == ipa

        if VOWELS.include?(arpa)
          tokens << STRESSED_VOWEL_TOKEN.fetch([arpa, pending_stress])
          pending_stress = 0
        else
          tokens << arpa
        end
        pos += ipalen
        matched = true
        break
      end
      next if matched

      if SKIP_CHARS.include?(char)
        pos += 1
        next
      end

      # Check for combining characters or unknown chars — skip them
      codepoint = char.ord
      if codepoint >= 0x0300 && codepoint <= 0x036F  # combining diacritical marks
        pos += 1
        next
      end
      if codepoint >= 0x02B0 && codepoint <= 0x02FF  # modifier letters
        pos += 1
        next
      end

      # Unknown character — conversion failed
      return nil
    end

    return nil if tokens.empty?

    # If no vowel got primary stress and word has vowels, assign stress 1
    # to the first vowel marked 0 (heuristic for monosyllables without markers)
    has_primary = false
    tokens.each do |t|
      if t.end_with?("1")
        has_primary = true
        break
      end
    end
    unless has_primary
      tokens.each_with_index do |t, i|
        next unless t.end_with?("0")

        base = t.delete_suffix("0")
        next unless VOWELS.include?(base)

        tokens[i] = STRESSED_VOWEL_TOKEN.fetch([base, 1])
        break
      end
    end

    tokens
  end
end
