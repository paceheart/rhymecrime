# coding: utf-8

#
# Lexicon: in-process $word_dict, loaded from word_dict.msgpack at boot.
# Same data shape in dev and Lambda (optional 4th entry column: prefix-allow
# bases from precompute-prefix-gate); the DDB word# partition was retired
# (see bin/upload-to-dynamodb and bin/stage-lambda) once the msgpack got
# small enough (~5.5 MB) to ship in the deploy bundle. DynamoRuntime now
# only fronts the related# / score# partitions.
#

def lexicon_word_entry(word)
  word_dict[word]
end

def debug_info(word)
  result = ""
  i = 0
  prons = pronunciations(word)
  for pron in prons
    i = i + 1
    unless i == 1
      result << " "
    end

    # pronunciation
    if prons.length == 1
      result << "pron="
    else
      result << "pron#{i}="
    end
    result << pron.to_s

    # rhyme syllables string
    if prons.length == 1
      result << " rich_rime="
    else
      result << " rich_rime#{i}="
    end

    result << pron.rich_rime

    if prons.length == 1
      result << " rime="
    else
      result << " rime#{i}="
    end
    result << pron.rime
  end
  return result
end

#
# rhyme computation
#

$word_dict = nil
def word_dict()
  # word => [frequency, pronunciations, lemma]
  # pronunciations = [pronunciation1, pronunciation2 ...]
  # pronunciation = [syllable1, syllable1, ...]
  return $word_dict unless $word_dict.nil?
  # Prefer the msgpack: it's the runtime-canonical artifact (smaller, faster
  # to parse, and the only one shipped to Lambda). Fall back to the .txt
  # loader for fresh checkouts where bin/dict-build hasn't run yet — keeps
  # bundle exec rspec working before the first build.
  $word_dict = load_word_dict_msgpack || load_word_dict
end

WORDS_NEEDED_FOR_TESTING = ['arpeggio', 'asterisk', 'blackmail', 'bobcat', 'burglar', 'burglary', 'cat', 'celebrity', 'costume', 'crime', 'doubloons', 'drumsticks', 'fanciers', 'feline', 'fortissimo', 'galaxy', 'glissando', 'halloween', 'hemiola', 'homicide', 'item', 'jaguar', 'mandolin', 'music', 'overtone', 'pianissimo', 'pirate', 'pussy', 'repertoire', 'ritardando', 'scurvy', 'star', 'thing', 'tree', 'treetop', 'trespassing', 'whiskers', 'wildcat', 'xylophone'] # include these even if they don't have any rhymes

$rime_dict = nil # rime (underscore ARPABET key) -> words hash
def rime_dict
  # rime => [rhyming_word1 rhyming_word2 ...]
  return $rime_dict unless $rime_dict.nil?
  # Mirror of the word_dict loader: prefer rime_dict.msgpack, fall back to
  # the .txt surface for pre-dict-build checkouts.
  $rime_dict = load_rime_dict_msgpack || load_rime_dict_as_hash
end

def load_rime_dict_as_hash()
  load_string_hash(generated_dict_path_under_dict_dir(RIME_DICT_FILENAME)) or
    raise "First run ./bin/dict-build to populate generated/"
end

def pronunciations(word)
  word_info = lexicon_word_entry(word)
  if word_info
    return word_info[1]
  else
    return []
  end
end

def frequency(word)
  word_info = lexicon_word_entry(word)
  if word_info
    return word_info[0]
  else
    return 0
  end
end

# Sorted list of RhymeCrime part-of-speech tags for word (Kaikki pos union, then lexical
# Kaikki POS intersected with WordNet coarse POS when WN has the lemma; see apply_lexical_pos_layer_a!
# in dict.rb (build). Empty array if the word is unknown to the loaded map.
#
# Strict-load: raises RuntimeError if generated/part_of_speech.json is missing. The file
# is *deliberately* excluded from the Lambda deploy bundle (see bin/stage-lambda) because
# the only Lambda-reachable caller — relatedness/signals.rb's pos_count feature — is the
# local-dev compute fallback that DDB mode short-circuits before ever requiring
# signals.rb. If you trip this raise from inside a Lambda invocation, something has
# pulled signals.rb (or another POS reader) into the runtime path that shouldn't be there;
# fix the offender rather than re-including the file in the deploy zip.
$part_of_speech_by_word = nil
def part_of_speech_tags(word)
  w = word.to_s.downcase.strip
  return [] if w.empty?
  if $part_of_speech_by_word.nil?
    path = generated_dict_path_under_dict_dir(PART_OF_SPEECH_FILENAME)
    unless File.exist?(path)
      raise "missing #{path}: run ./bin/dict-build to generate it. " \
            "If this fired inside Lambda, the file is excluded by design — see " \
            "bin/stage-lambda and the doc comment above part_of_speech_tags."
    end
    $part_of_speech_by_word = JSON.parse(IoUtils.read(path, encoding: "UTF-8", hint: "part_of_speech_tags"))
  end
  tags = $part_of_speech_by_word[w]
  tags.is_a?(Array) ? tags : []
end
