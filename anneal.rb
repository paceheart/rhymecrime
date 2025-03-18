#!/usr/bin/env ruby

require 'annealing'
require_relative 'semantic-similarity'
require_relative 'spec/test_utils'

#state = [190, 5, 1] # -> 81 # $SIMILARITY_THRESHOLD, $DOC_SIMILARITY_ADJUSTMENT, $DOC_SIMILARITY_WEIGHT

# $SIMILARITY_THRESHOLD, $SENTENCE_SIMILARITY_ADJUSTMENT, $DOC_SIMILARITY_WEIGHT, $DOC_SIMILARITY_ADJUSTMENT
#state = [30, -14, 0.25, 9] # -> 75
#state = [160, -20, 0.5, 39] # -> 66
#state = [158, -21, 0.51, 38] # -> 64

# subtract 1 from rarity
state = [50, 56, 0.3, -52] # -> 64

# raise to the power of rarity
#state = [40, 40, 0.08, -40] # -> 102
#state = [37, 43, 0.06, -42] # -> 98
# nope

$FINE_GRAINED = true
$ANNEAL_MULT = $FINE_GRAINED ? 1 : 10

$MIN_SIMILARITY_THRESHOLD = 0
$MAX_SIMILARITY_THRESHOLD = 400
$SIMILARITY_THRESHOLD_INCREMENT = 1 * $ANNEAL_MULT

#$MIN_SENTENCE_WEIGHT = 0.01 * $ANNEAL_MULT
#$MAX_SENTENCE_WEIGHT = 2
#$SENTENCE_WEIGHT_INCREMENT = 0.01 * $ANNEAL_MULT

$MIN_SENTENCE_ADJUSTMENT = -100
$MAX_SENTENCE_ADJUSTMENT = 100
$SENTENCE_ADJUSTMENT_INCREMENT = 1 * $ANNEAL_MULT

$MIN_DOC_WEIGHT = 0.01
$MAX_DOC_WEIGHT = 2
$DOC_WEIGHT_INCREMENT = 0.01 * $ANNEAL_MULT

$MIN_DOC_ADJUSTMENT = -200
$MAX_DOC_ADJUSTMENT = 200
$DOC_ADJUSTMENT_INCREMENT = 1 * $ANNEAL_MULT

Annealing.configure do |config|
  config.cooling_rate = 0.001
  config.temperature = 10
end

class FailCount
  include Memery

  memoize def fail_count(state)
    failing_test_count
  end

end

$foo = FailCount.new

energy_calculator = lambda do |state|
  $SIMILARITY_THRESHOLD, $SENTENCE_SIMILARITY_ADJUSTMENT, $DOC_SIMILARITY_WEIGHT, $DOC_SIMILARITY_ADJUSTMENT = state
  result = $foo.fail_count(state)
  puts "#{state} -> #{result}"
  return result
end

state_change = lambda do |state|
  thresh, sentence_adjustment, doc_weight, doc_adjustment = state
  mult = coin_flip ? 1 : -1
  if coin_flip
    if coin_flip
      sentence_adjustment += $SENTENCE_ADJUSTMENT_INCREMENT * mult
    else
      thresh += $SIMILARITY_THRESHOLD_INCREMENT * mult
      #sentence_weight += $SENTENCE_WEIGHT_INCREMENT * mult
      #sentence_weight = sentence_weight.round(2)
    end
  else
    if coin_flip
      doc_adjustment += $DOC_ADJUSTMENT_INCREMENT * mult
    else
      doc_weight += $DOC_WEIGHT_INCREMENT * mult
      doc_weight = doc_weight.round(2)
    end
  end
  thresh = $MIN_SIMILARITY_THRESHOLD unless thresh > $MIN_SIMILARITY_THRESHOLD 
  thresh = $MAX_SIMILARITY_THRESHOLD unless thresh < $MAX_SIMILARITY_THRESHOLD
  sentence_adjustment = $MIN_SENTENCE_ADJUSTMENT unless sentence_adjustment > $MIN_SENTENCE_ADJUSTMENT
  sentence_adjustment = $MAX_SENTENCE_ADJUSTMENT unless sentence_adjustment < $MAX_SENTENCE_ADJUSTMENT
  #sentence_weight = $MIN_SENTENCE_WEIGHT unless sentence_weight > $MIN_SENTENCE_WEIGHT
  #sentence_weight = $MAX_SENTENCE_WEIGHT unless sentence_weight < $MAX_SENTENCE_WEIGHT
  doc_adjustment = $MIN_DOC_ADJUSTMENT unless doc_adjustment > $MIN_DOC_ADJUSTMENT
  doc_adjustment = $MAX_DOC_ADJUSTMENT unless doc_adjustment < $MAX_DOC_ADJUSTMENT
  doc_weight = $MIN_DOC_WEIGHT unless doc_weight > $MIN_DOC_WEIGHT
  doc_weight = $MAX_DOC_WEIGHT unless doc_weight < $MAX_DOC_WEIGHT
  return [thresh, sentence_adjustment, doc_weight, doc_adjustment]
end

Annealing::Metal.class_eval do

    # True if cooled_metal.energy is lower than current energy.
    def lower_energy?(cooled_metal)
      cooled_metal.energy < energy
    end
    
    # True if cooled_metal.energy is lower than current energy. Otherwise, let
    # probability determine if we should accept a higher value over a lower
    # value
    def prefer?(cooled_metal)
      lower_energy?(cooled_metal) or prefer_despite_higher_energy?(cooled_metal)
    end

    def prefer_despite_higher_energy?(cooled_metal)
      energy_delta = energy - cooled_metal.energy
      (Math::E**(energy_delta / cooled_metal.temperature)) > rand
    end
end

Annealing::Simulator.class_eval do
  class Metal
     attr_reader :configuration, :state, :temperature
  def initialize(current_state, current_temperature, configuration = nil)
      @configuration = configuration || Annealing.configuration.merge({})
      @state = current_state
      @temperature = current_temperature
  end

     def energy
      @energy ||= configuration.energy_calculator.call(state)
    end

    # This method is not idempotent!
    # It relies on random probability to select the next state
    def cool!(new_temperature)
      cooled_metal = cool(new_temperature)
      if prefer?(cooled_metal)
        cooled_metal
      else
        @temperature = new_temperature
        self
      end
    end

    # True if cooled_metal.energy is lower than current energy.
    def lower_energy?(cooled_metal)
      cooled_metal.energy < energy
    end
    
    private

    # True if cooled_metal.energy is lower than current energy. Otherwise, let
    # probability determine if we should accept a higher value over a lower
    # value
    def prefer?(cooled_metal)
      lower_energy?(cooled_metal) or prefer_despite_higher_energy?(cooled_metal)
    end

    def prefer_despite_higher_energy?(cooled_metal)
      energy_delta = energy - cooled_metal.energy
      (Math::E**(energy_delta / cooled_metal.temperature)) > rand
    end

    def cool(new_temperature)
      next_state = configuration.state_change.call(state)
      Metal.new(next_state, new_temperature, configuration)
    end
  end # end class Metal
  
    def run(initial_state, config_hash = {})
      with_runtime_config(config_hash) do |runtime_config|
        initial_temperature = runtime_config.temperature
        current = Metal.new(initial_state, initial_temperature, runtime_config)
        best = current
        steps = 0
        until termination_condition_met?(current, runtime_config)
          steps += 1
          current = reduce_temperature(current, steps, runtime_config)
          # If the current state has lower energy than the previous best (lowest energy) state
          # we've seen so far, the current state is the new best state.
          if best.lower_energy?(current)
            best = current
            puts "state = #{best.state} # -> #{best.energy}"
          end
        end
        best
      end
    end
end

optimal_settings = Annealing.simulate(state, energy_calculator: energy_calculator, state_change: state_change)
puts "state = #{optimal_settings} # -> #{$foo.fail_count(optimal_settings)}"
