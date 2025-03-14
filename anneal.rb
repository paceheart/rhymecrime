#!/usr/bin/env ruby

require 'annealing'
require_relative 'semantic-similarity'
require_relative 'spec/test_utils'

state = [5, 55] # or [45, 15]
$coldest_state = state

$tweak_increment = 1

Annealing.configure do |config|
  config.cooling_rate = 0.001
  config.temperature = 30
end

class FailCount
  include Memery

  memoize def fail_count(state)
    failing_test_count
  end

end

$foo = FailCount.new

energy_calculator = lambda do |state|
  $SIMILARITY_THRESHOLD = state[0]
  $DOC_SIMILARITY_ADJUSTMENT = state[1]
  result = $foo.fail_count(state)
  puts "#{state} -> #{result.round(3)}"
  return result
end

state_change = lambda do |state|
  thresh = state[0]
  doc_adjustment = state[1]
  tweak = $tweak_increment
  if coin_flip
    tweak = -tweak
  end
  if coin_flip
    thresh += tweak
  else
    doc_adjustment += tweak
  end
  thresh = -100 unless thresh > -100 
  thresh = 100 unless thresh < 100
  doc_adjustment = -100 unless doc_adjustment > -100
  doc_adjustment = 100 unless doc_adjustment < 100
  return [thresh, doc_adjustment]
end

Annealing::Metal.class_eval do

  def prefer?(cooled_metal)
    result = really_prefer?(cooled_metal)
    if result
      $coldest_state = @state
    end
    return result
  end

  def really_prefer?(cooled_metal)
    return true if cooled_metal.energy < energy

    energy_delta = energy - cooled_metal.energy
    temp = cooled_metal.temperature
    num = (Math::E**(energy_delta / cooled_metal.temperature))
    #puts "delta = #{energy_delta.round(3)}, temp = #{temp.round(2)}, #{(num.round(2)*100).to_i}% chance to prefer hotter"
    num > rand
  end
end

optimal_settings = Annealing.simulate(state, energy_calculator: energy_calculator, state_change: state_change)
p optimal_settings
p $coldest_state
p $foo.fail_count($coldest_state)
