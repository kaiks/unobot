# frozen_string_literal: true

require_relative '../canonical'

module UnobotV2
  module Human
    class ActionEncoder
      Result = Struct.new(:command, :code, :message, keyword_init: true) do
        def success? = !command.nil?
        def error? = !success?
      end
      COLORS = { 'red' => 'r', 'green' => 'g', 'blue' => 'b', 'yellow' => 'y' }.freeze

      def encode(action, request:)
        action = Canonical::Action.from(action)
        return failure(:unsafe_state, 'human state is not safe') unless request.safe?
        return failure(:action_unavailable, "#{action.action} is unavailable") unless request.available_actions.include?(action.action)
        return Result.new(command: action.action == 'draw' ? 'pe' : 'pa') unless action.action == 'play'
        return failure(:card_unavailable, 'card is not currently playable') unless request.playable_cards.include?(action.card)
        if action.double_play && (request.already_picked || request.hand.count(action.card) < 2)
          return failure(:double_unavailable, 'two matching cards are not available')
        end

        code = action.card
        code = "#{code}#{COLORS.fetch(action.wild_color)}" if Canonical::Cards.wild?(code)
        code *= 2 if action.double_play
        Result.new(command: "pl #{code}")
      rescue Canonical::ValidationError, KeyError => error
        failure(:invalid_action, error.message)
      end

      private

      def failure(code, message)
        Result.new(code: code, message: message)
      end
    end
  end
end
