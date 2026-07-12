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

      # Human transport must never offer a strategy an action that cannot be
      # represented by the IRC command grammar. Machine requests intentionally
      # bypass this mask and retain the complete canonical action space.
      def mask_request(request)
        actions = request.available_actions.select do |kind|
          next true if kind == 'play'

          expressible?({ action: kind }, request: request)
        end
        playable = request.playable_cards.select { |card| every_play_variant_expressible?(card, request) }
        actions.delete('play') if playable.empty?
        return request if actions == request.available_actions && playable == request.playable_cards

        metadata = request.metadata.merge(
          human_action_masked: true,
          human_masked_actions: (request.available_actions - actions).uniq,
          human_masked_cards: (request.playable_cards - playable).uniq
        )
        Canonical::DecisionRequest.new(
          **request.state_h.merge(available_actions: actions, playable_cards: playable),
          metadata: metadata
        )
      end

      def expressible?(action, request:)
        encode(action, request: request).success?
      rescue Canonical::ValidationError, KeyError
        false
      end

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

      def every_play_variant_expressible?(card, request)
        colors = Canonical::Cards.wild?(card) ? COLORS.keys : [nil]
        doubles = request.hand.count(card) >= 2 && !request.already_picked ? [false, true] : [false]
        colors.product(doubles).all? do |color, double_play|
          action = { action: 'play', card: card, double_play: double_play }
          action[:wild_color] = color if color
          expressible?(action, request: request)
        end
      end

      def failure(code, message)
        Result.new(code: code, message: message)
      end
    end
  end
end
