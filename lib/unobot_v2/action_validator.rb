# frozen_string_literal: true

require_relative 'canonical'

module UnobotV2
  # Validates the strategy boundary before an action reaches either transport.
  module ActionValidator
    module_function

    def validate(action, request:)
      canonical = Canonical::Action.from(action)
      unless request.available_actions.include?(canonical.action)
        raise Canonical::ValidationError, "action #{canonical.action.inspect} is unavailable"
      end
      return canonical unless canonical.action == 'play'

      unless request.playable_cards.include?(canonical.card)
        raise Canonical::ValidationError, "card #{canonical.card.inspect} is not playable"
      end
      if canonical.double_play && (request.already_picked || request.hand.count(canonical.card) < 2)
        raise Canonical::ValidationError, 'double play is unavailable'
      end

      canonical
    end
  end
end
