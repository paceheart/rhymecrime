require 'csv'
require_relative '../pace_utils'

def zerone_string_to_boolean(str)
  str = str.strip
  if str == "0"
    return false
  elsif str == "1"
    return true
  else
    raise "zerone_string_to_boolean called on a non-zerone string: " + str
  end
end

$cases = nil
def relatedness_test_cases
  $cases ||= load_relatedness_test_cases
end

# word1, word2, oughta be related?, notes
def load_relatedness_test_cases
  CSV::Converters[:boolean] = ->(value) { zerone_string_to_boolean(value) rescue value }
  cases = CSV.parse(File.read("spec/related.csv", encoding: 'UTF-8'), headers:true, converters: :boolean) or raise "Could not read/parse related.csv"
  for c in cases
    repair_relatedness_test_case(c)
  end
  for c in cases
    validate_relatedness_test_case(c)
  end
end

def word?(object)
  object.is_a?(String) and object == object.strip
end

def repair_relatedness_test_case(c)
  c['notes'] ||= ""
end

def validate_relatedness_test_case(c)
  word1 = c['word1']
  word?(word1) or raise "Malformed word1 '#{word1}' in #{c}"
  word2 = c['word2']
  word?(word2) or raise "Malformed word2 '#{word2}' in #{c}"
  related = c['oughta be related?']
  boolean?(related) or raise "Malformed oughta_be_related? '#{related}' in #{c}"
  notes = c['notes']
  notes.is_a?(String) or raise "Malformed notes '#{notes}' in #{c}"
end

def define_relatedness_test_case(c)
  context c["notes"] do
    if c["oughta be related?"]
      oughta_be_related c["word1"], c["word2"]
    else
      ought_not_be_related c["word1"], c["word2"]
    end
  end
end

def load_and_define_relatedness_test_cases
  load_relatedness_test_cases.each { |c| define_relatedness_test_case(c) }
end

def relatedness_test_passes?(test_case)
  expected = test_case['oughta be related?']
  actual = semantically_related?(test_case["word1"], test_case["word2"], false)
  debug expected == actual ? "." : "F"
  return expected == actual
end

def succeeding_test_count
  cases = relatedness_test_cases
  success_count = cases.count { |c| relatedness_test_passes?(c) }
  return success_count
end

def failing_test_count
  relatedness_test_cases.count - succeeding_test_count
end
