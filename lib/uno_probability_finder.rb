require 'uno_path_finder'

class ProbabilityFinder < PathFinder
  HAND_LIMIT = 10

  def find(hand)
    if hand.length < HAND_LIMIT
      best_score = 0
      best_permutation = []
      hand.permutation(hand.length) do |p|
        next unless p[0].plays_after? @last_card
        probability_output = smart_probability(p)
        bot_debug "Before: #{probability_output}", 3
        probability_score = special_card_penalty(p, probability_output)
        bot_debug "After: #{probability_score}", 3

        if probability_score > best_score
          best_score = probability_score
          best_permutation = p
        end
      end
      bot_debug "Found best permutation: #{best_permutation.map(&:to_s)}"
      if !best_permutation.empty? && best_permutation[0].special_card?
        best_permutation[0].set_wild_color first_non_wild_color(best_permutation)
      end
      best_permutation
    else
      raise 'we should not be here'
    end
  end
end
