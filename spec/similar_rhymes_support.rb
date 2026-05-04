# Shared infrastructure for the +set_related+ / +pair_related+ / +related_rhymes+
# spec files (+similar_rhymes_*_spec.rb+). All three files use +summarize_for_failure+
# to produce a focused failure-message summary instead of dumping a 1k+ line tuple
# / pair list — see callers +summarize_pairs_for_failure+ (in +similar_rhymes_pair_
# related_spec.rb+) and +summarize_tuples_for_failure+ (in +similar_rhymes_set_
# related_spec.rb+).
#
# Used to live alongside the SET_RELATED / PAIR_RELATED / RELATED_RHYMES describe
# blocks in a single +spec/similar_rhymes_spec.rb+. Split into per-describe files
# so +parallel_rspec+ can fan the (formerly ~220s) work across workers; extracting
# the common helpers here keeps each split file self-contained without duplication.

# Failure-message helpers: dumping the full +find_rhyming_pairs+ result (often
# 1000+ pairs) or +find_rhyming_tuples+ result drowns out the actual signal —
# whether the expected words made it into the rhyme list at all and, if so,
# which partners they got paired with. Instead, summarize: total count, the
# subset involving any expected word, and otherwise a small head sample.
SIMILAR_SPEC_INVOLVING_LIMIT = 25
SIMILAR_SPEC_HEAD_LIMIT = 8

def summarize_for_failure(label, items, expected_words)
  items ||= []
  expected = expected_words.compact.uniq
  involving = items.select { |entry| (entry & expected).any? }
  parts = ["got #{items.size} #{label}#{items.size == 1 ? '' : 's'}"]
  expected_str = expected.map { |w| "'#{w}'" }.join(' or ')
  if involving.any?
    sample = involving.first(SIMILAR_SPEC_INVOLVING_LIMIT)
    suffix = involving.size > SIMILAR_SPEC_INVOLVING_LIMIT ? " (+#{involving.size - SIMILAR_SPEC_INVOLVING_LIMIT} more)" : ""
    parts << "#{label}s involving #{expected_str}: #{sample.inspect}#{suffix}"
  elsif items.any?
    head = items.first(SIMILAR_SPEC_HEAD_LIMIT)
    parts << "no #{label} contains any of #{expected_str}; first #{head.size}: #{head.inspect}"
  end
  parts.join(", ")
end
