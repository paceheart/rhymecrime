#
# Helpers + DSL shared by every +set_related_*_spec.rb+: a cue-specific spec
# (e.g. +set_related_pirate_spec.rb+) only needs +require_relative+ this file
# (it transitively pulls in +similar_rhymes_support+ for +summarize_for_failure+
# / the head/involving sample limits) and the per-cue +describe 'SET_RELATED'+
# block can use +set_related_oughta_contain+ etc. directly.
#
# Used to live alongside the +describe 'SET_RELATED'+ block in
# +spec/similar_rhymes_set_related_spec.rb+. Split into per-cue files so
# +parallel_rspec+ can fan the (formerly ~210-example, ~170s pre-LocalStore-warm)
# cue across workers — pirate / music / water / crime / cat each in their own
# file (>=10 examples), everything else in +set_related_misc_spec.rb+.
#

require_relative "similar_rhymes_support"

# Prefer the production-shaped path (+find_rhyming_tuples+ with cross-tuple
# pruning enabled) so SQLite +set_related#+ and the LRU hit first — fast runs.
#
# Disable the cross-tuple redundancy pruner (+$disable_cross_tuple_redundancy_pruning+) only when
# a pair is absent there but still needed for an assertion (+set_related_oughta_contain 'pirate', 'deck', 'wreck'+
# when sibling +[decked, wrecked]+ masks +[deck, wreck]+ — see +prune_suffix_redundant_rhyming_tuples+).
def with_similar_spec_pruning_fallback(input, common_only, fallback_unpruned: true)
  was = $disable_cross_tuple_redundancy_pruning
  begin
    # Standard path hits precomputed set_related#LRU when available.
    $disable_cross_tuple_redundancy_pruning = false
    tuples_standard = find_rhyming_tuples(input, common_only)

    tuples_fb = tuples_standard
    hit = yield(tuples_standard, :standard)

    if !hit && fallback_unpruned
      $disable_cross_tuple_redundancy_pruning = true
      tuples_fb = find_rhyming_tuples(input, common_only)
      hit = yield(tuples_fb, :no_cross_tuple_prune)
    end
    [hit, tuples_fb]
  ensure
    $disable_cross_tuple_redundancy_pruning = was
  end
end

def tuples_share_pair_words?(tuple, output1, output2)
  tuple.include?(output1) && tuple.include?(output2)
end

def summarize_tuples_for_failure(tuples, *expected_words)
  summarize_for_failure("tuple", tuples, expected_words)
end

# Returns [hit_boolean, tuples_from_last_attempt] for diagnostics.
# Negatives (+set_related_ought_not_contain+) disable the unpruned fallback via
# +similar_spec_pair_contains_detail(..., fallback_unpruned: false)+ (see +negative_expectation:+ on
# +set_related_contains?+) so we only inspect production-shaped tuples: SQLite set_related#/LRU with
# cross-tuple redundancy pruning—the same cue a user sees.
def similar_spec_pair_contains_detail(input, output1, output2, common_only = false, fallback_unpruned: true)
  with_similar_spec_pruning_fallback(input, common_only, fallback_unpruned: fallback_unpruned) do |tuples, _mode|
    next false if tuples.nil?
    tuples.any? { |tuple| tuples_share_pair_words?(tuple, output1, output2) }
  end
end

def set_related_contains?(input, output1, output2, common_only = false, negative_expectation: false)
  hit, = similar_spec_pair_contains_detail(
    input, output1, output2, common_only,
    fallback_unpruned: !negative_expectation
  )
  hit
end

# Permissive sibling of +set_related_contains?+: pass if any inflected form sharing +base1+'s lemma
# co-occurs with any inflected form sharing +base2+'s lemma in some rhyming tuple. Use when the
# suffix-redundancy pruner collapses base/-s/-ed/-ing/-er siblings into a single emitted tuple and
# we don't care which inflectional surface survives — only that *a* member of each lemma family
# rhymes with the other in context.
def lemma_family(base)
  fam = lemma_to_words[base]
  fam = fam.nil? || fam.empty? ? [base] : fam.dup
  fam << base unless fam.include?(base)
  fam
end

def similar_spec_contains_base_family_pair_detail(input, base1, base2, common_only = false, fallback_unpruned: true)
  fam1 = lemma_family(base1)
  fam2 = lemma_family(base2)
  with_similar_spec_pruning_fallback(input, common_only, fallback_unpruned: fallback_unpruned) do |tuples, _mode|
    next false if tuples.nil?
    tuples.any? do |tuple|
      fam1.any? { |w| tuple.include?(w) } && fam2.any? { |w| tuple.include?(w) }
    end
  end
end

def set_related_contains_base_form?(input, base1, base2, common_only = false, negative_expectation: false)
  hit, = similar_spec_contains_base_family_pair_detail(
    input, base1, base2, common_only,
    fallback_unpruned: !negative_expectation
  )
  hit
end

def set_related_works(input, common_only = false)
  test_name = "set_related works: #{input}"
  it test_name do
    _hit, tuples = with_similar_spec_pruning_fallback(input, common_only) do |ts, _|
      ts && ts.length.nonzero?
    end
    expect(tuples&.length.to_i).not_to eq(0), "Set-related rhymes for '#{input}' oughta be non-empty"
  end
end

def set_related_oughta_contain(input, output1, output2, common_only: false, not_working_reason: nil)
  test_name = "set_related: #{input} -> #{output1} / #{output2}"
  it test_name do
    skip_if_not_working(not_working_reason)
    hit, diag = similar_spec_pair_contains_detail(input, output1, output2, common_only)
    expect(hit).to eql(true), "Set-related rhymes for '#{input}' oughta include '#{output1}' (#{debug_info(output1)}) / '#{output2}' (#{debug_info(output2)}) / ..., but #{summarize_tuples_for_failure(diag, output1, output2)}"
  end
end

def set_related_ought_not_contain(input, output1, output2, common_only: false, not_working_reason: nil)
  test_name = "set_related: #{input} !-> #{output1} / #{output2}"
  it test_name do
    skip_if_not_working(not_working_reason)
    expect(set_related_contains?(input, output1, output2, common_only, negative_expectation: true)).to eql(false), "Set-related rhymes for '#{input}' ought not include '#{output1}' / '#{output2}' / ..."
  end
end

def set_related_oughta_contain_semantic_base(input, base1, base2, common_only: false, not_working_reason: nil)
  test_name = "set_related: #{input} -> #{base1}* / #{base2}*"
  it test_name do
    skip_if_not_working(not_working_reason)
    fam1 = lemma_family(base1)
    fam2 = lemma_family(base2)
    hit, diag = similar_spec_contains_base_family_pair_detail(input, base1, base2, common_only)
    expect(hit).to eql(true),
      "Set-related rhymes for '#{input}' oughta include some inflected form of '#{base1}' (family=#{fam1.inspect}) alongside some inflected form of '#{base2}' (family=#{fam2.inspect}), but #{summarize_tuples_for_failure(diag, *fam1, *fam2)}"
  end
end
