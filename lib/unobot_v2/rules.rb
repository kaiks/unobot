# frozen_string_literal: true

require_relative 'canonical'

module UnobotV2
  class Rules
    Result = Struct.new(:available_actions, :playable_cards, keyword_init: true) do
      def initialize(**)
        super
        available_actions.freeze
        playable_cards.freeze
        freeze
      end
    end

    def derive(hand:, top_card:, game_state:, stacked_cards:, already_picked:, picked_card:)
      candidates = already_picked ? Array(picked_card) : hand
      playable = candidates.select { |card| playable?(card, top_card, game_state) }
      actions = if already_picked
                  actions_after_draw(playable)
                else
                  actions_before_draw(playable, stacked_cards)
                end
      Result.new(available_actions: actions, playable_cards: playable)
    end

    def playable?(candidate, top_card, game_state)
      card = Canonical::Cards.base(candidate)
      return false unless plays_after?(card, top_card)
      return true if game_state == 'normal'

      figure = figure(card)
      return false unless %w[+2 r wd4].include?(figure)
      return true if game_state == 'war_+2'

      figure == 'wd4' || figure == 'r'
    end

    private

    def actions_after_draw(playable)
      actions = []
      actions << 'play' unless playable.empty?
      actions << 'pass'
      actions
    end

    def actions_before_draw(playable, stacked_cards)
      actions = []
      actions << 'play' unless playable.empty?
      actions << (stacked_cards.positive? ? 'pass' : 'draw')
      actions
    end

    def plays_after?(candidate, top_card)
      return true if Canonical::Cards.wild?(candidate)

      candidate[0] == Canonical::Cards.selected_color(top_card) || figure(candidate) == figure(top_card)
    end

    def figure(card)
      base = Canonical::Cards.base(card)
      return base if %w[w wd4].include?(base)

      base[1..]
    end
  end
end
