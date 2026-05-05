#
# set_related — +music+ cue (50 examples). Second-largest bucket; split off
# from +set_related_misc_spec.rb+ so +parallel_rspec+ can run music in
# parallel with pirate / water / crime / cat. See the per-cue companions
# +set_related_<cue>_spec.rb+ and +set_related_misc_spec.rb+ for the rest.
#

require_relative "similar_rhymes_set_related_support"

describe 'SET_RELATED' do
  context 'music' do
    set_related_oughta_contain 'music', 'baroque', 'folk'
    set_related_oughta_contain 'music', 'beat', 'sheet'
    set_related_oughta_contain 'music', 'cantata', 'sonata'
    set_related_oughta_contain 'music', 'enjoys', 'noise'
    set_related_oughta_contain 'music', 'funk', 'punk'
    set_related_oughta_contain 'music', 'sing', 'swing'
    set_related_oughta_contain 'music', 'orchestration', 'vibration'
    set_related_oughta_contain 'music', 'sonic', 'harmonic'
    set_related_oughta_contain 'music', 'piece', 'release'
    set_related_oughta_contain 'music', 'recital', 'title'
    set_related_oughta_contain 'music', 'piano', 'soprano'
    set_related_oughta_contain 'music', 'violins', 'winds'
    set_related_oughta_contain 'music', 'flute', 'lute'
    set_related_oughta_contain 'music', 'fandango', 'tango'
    set_related_oughta_contain 'music', 'session', 'progression'
    set_related_oughta_contain_semantic_base 'music', 'croon', 'tune'
    set_related_oughta_contain 'music', 'ears', 'spheres'
    set_related_oughta_contain 'music', 'bridal', 'idol'
    set_related_oughta_contain 'music', 'audition', 'composition'
    set_related_oughta_contain 'music', 'chord', 'record'
    set_related_oughta_contain_semantic_base 'music', 'composition', 'musician' # identical rime
    set_related_oughta_contain 'music', 'clarinet', 'minuet'
    set_related_oughta_contain 'music', 'accidental', 'instrumental'
    set_related_oughta_contain_semantic_base 'music', 'sing', 'string'
    set_related_oughta_contain 'music', 'glissando', 'ritardando', not_working_reason: "these lack prons"
    set_related_oughta_contain 'music', 'viola', 'hemiola'
    set_related_ought_not_contain 'music', 'overtone', 'xylophone'
    set_related_oughta_contain 'music', 'wave', 'rave'
    set_related_oughta_contain 'music', 'beat', 'repeat'
    set_related_oughta_contain 'music', 'flow', 'bow'
    set_related_oughta_contain 'music', 'jingle', 'single' # as in a hit single
    set_related_oughta_contain 'music', 'harp', 'sharp'
    set_related_ought_not_contain 'music', 'show', 'arpeggio' # stress mismatch
    set_related_ought_not_contain 'music', 'mix', 'drumsticks' # stress mismatch
    set_related_oughta_contain 'music', 'violin', 'mandolin'
    set_related_oughta_contain 'music', 'rest', 'expressed'
    set_related_oughta_contain 'music', 'lute', 'flute'
    set_related_oughta_contain 'music', 'fortissimo', 'pianissimo', not_working_reason: "both rare, rime bucket pruned"
    set_related_oughta_contain 'music', 'gong', 'song'
    set_related_oughta_contain 'music', 'duet', 'quartet'
    set_related_oughta_contain 'music', 'duet', 'quintet'
    set_related_ought_not_contain 'music', 'coral', 'choral' # exclude homophones 
    set_related_ought_not_contain 'music', 'recorded', 'prerecorded' # exclude rich rhymes
    set_related_ought_not_contain 'music', 'percussion', 'repercussion' # repercussion unrelated
    set_related_ought_not_contain 'music', 'tonal', 'atonal' # exclude rich rhymes
    set_related_oughta_contain 'music', 'abbreviation', 'notation'
    set_related_ought_not_contain 'music', 'tv', 'vision'
    set_related_ought_not_contain 'music', 'bass', 'brass', not_working_reason: "We'd have to enrich the relatedness to be to a word sense, not just a word, to distinguish between bass (tuba) and bass (fish)"
    it 'set_related music: bone / intone / trombone tuple' do
      skip_if_not_working(true)
      bone_intone_trombone = %w[bone intone trombone]
      tuples = find_rhyming_tuples('music', 'en')
      expect(tuples.include?(bone_intone_trombone)).to eql(true)
    end

    it 'no proper subsets: music ought not return bone / intone alone' do
      bone_intone = %w[bone intone]
      tuples = find_rhyming_tuples('music', 'en')
      expect(tuples.include?(bone_intone)).to eql(false)
    end
  end
end
