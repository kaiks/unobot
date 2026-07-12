# frozen_string_literal: true

require 'json'

module UnobotV2
  module Canonical
    class ValidationError < ArgumentError; end

    module ValueObject
      def ==(other)
        other.instance_of?(self.class) && to_h == other.to_h
      end
      alias eql? ==

      def hash
        [self.class, to_h].hash
      end

      def to_json(*args)
        JSON.generate(to_h, *args)
      end
    end

    class PlayerCount
      include ValueObject
      attr_reader :id, :card_count

      def initialize(id:, card_count:)
        @id = String(id).dup.freeze
        @card_count = Integer(card_count)
        raise ValidationError, 'player id cannot be empty' if @id.empty?
        raise ValidationError, 'card count cannot be negative' if @card_count.negative?
        freeze
      end

      def to_h
        { id: id, card_count: card_count }
      end
    end

    class Action
      include ValueObject
      TYPES = %w[play draw pass].freeze
      COLORS = %w[red green blue yellow].freeze
      attr_reader :action, :card, :wild_color, :double_play

      def self.from(value)
        return value if value.is_a?(self)

        unless value.is_a?(Hash)
          raise ValidationError, 'action must be an object'
        end
        hash = value.transform_keys(&:to_sym)
        unknown = hash.keys - %i[action card wild_color double_play]
        raise ValidationError, "unknown action fields: #{unknown.join(', ')}" unless unknown.empty?

        new(**hash.slice(:action, :card, :wild_color, :double_play))
      rescue ValidationError
        raise
      rescue ArgumentError, TypeError, NoMethodError => error
        raise ValidationError, "invalid action: #{error.message}"
      end

      def initialize(action:, card: nil, wild_color: nil, double_play: false)
        @action = String(action).freeze
        @card = card&.to_s&.dup&.freeze
        @wild_color = wild_color&.to_s&.dup&.freeze
        unless [true, false].include?(double_play)
          raise ValidationError, 'double_play must be boolean'
        end
        @double_play = double_play
        validate!
        freeze
      end

      def to_h
        result = { action: action }
        result[:card] = card if card
        result[:wild_color] = wild_color if wild_color
        result[:double_play] = true if double_play
        result
      end

      private

      def validate!
        raise ValidationError, "unknown action #{action.inspect}" unless TYPES.include?(action)
        if action == 'play'
          raise ValidationError, 'play requires card' unless card
          raise ValidationError, "invalid card #{card.inspect}" unless Cards.valid?(card, allow_colored_wild: false)
          if Cards.wild?(card)
            raise ValidationError, 'wild play requires wild_color' unless COLORS.include?(wild_color)
          elsif wild_color
            raise ValidationError, 'wild_color is only valid for wild cards'
          end
        elsif card || wild_color || double_play
          raise ValidationError, "#{action} cannot include play fields"
        end
      end
    end

    module Cards
      COLORS = %w[r g b y].freeze
      FIGURES = (0..9).map(&:to_s).concat(%w[r s +2]).freeze
      BASE_RE = /\A(?:[rgby](?:[0-9]|r|s|\+2)|w|wd4)\z/
      COLORED_WILD_RE = /\A(?:w|wd4)[rgby]\z/

      module_function

      def valid?(card, allow_colored_wild: true)
        BASE_RE.match?(card.to_s) || (allow_colored_wild && COLORED_WILD_RE.match?(card.to_s))
      end

      def wild?(card)
        %w[w wd4].include?(card.to_s)
      end

      def base(card)
        text = card.to_s
        COLORED_WILD_RE.match?(text) ? text.sub(/[rgby]\z/, '') : text
      end

      def selected_color(card)
        COLORED_WILD_RE.match?(card.to_s) ? card.to_s[-1] : card.to_s[0]
      end
    end

    class DecisionRequest
      include ValueObject
      GAMES = %w[normal war_+2 war_wd4].freeze
      ACTIONS = %w[play draw pass].freeze
      CONFIDENCE = %w[exact derived uncertain].freeze

      attr_reader :your_id, :hand, :top_card, :game_state, :stacked_cards,
                  :already_picked, :picked_card, :other_players,
                  :available_actions, :playable_cards, :metadata

      def self.from_protocol(value, metadata: {})
        raise ValidationError, 'request must be an object' unless value.is_a?(Hash)

        envelope = value.transform_keys(&:to_sym)
        raise ValidationError, 'not a request_action envelope' unless envelope[:type] == 'request_action'
        raise ValidationError, 'unsupported protocol version' unless envelope[:protocol_version] == 1

        state_value = envelope.fetch(:state)
        raise ValidationError, 'state must be an object' unless state_value.is_a?(Hash)

        state = state_value.transform_keys(&:to_sym)
        new(**state, metadata: metadata)
      rescue KeyError, TypeError, NoMethodError => error
        raise ValidationError, "invalid request: #{error.message}"
      end

      def initialize(your_id:, hand:, top_card:, game_state:, stacked_cards:,
                     already_picked:, picked_card:, other_players:,
                     available_actions:, playable_cards:, metadata: {})
        @your_id = String(your_id).dup.freeze
        @hand = strings(hand)
        @top_card = String(top_card).dup.freeze
        @game_state = String(game_state).dup.freeze
        @stacked_cards = Integer(stacked_cards)
        unless [true, false].include?(already_picked)
          raise ValidationError, 'already_picked must be boolean'
        end
        @already_picked = already_picked
        @picked_card = picked_card&.to_s&.dup&.freeze
        @other_players = other_players.map do |player|
          player.is_a?(PlayerCount) ? player : PlayerCount.new(**player.transform_keys(&:to_sym))
        end.freeze
        @available_actions = strings(available_actions)
        @playable_cards = strings(playable_cards)
        @metadata = deep_freeze(symbolize(metadata))
        validate!
        freeze
      end

      def safe?
        metadata.fetch(:safe, true)
      end

      def decision_id
        metadata[:decision_id]
      end

      def protocol_h
        {
          type: 'request_action', protocol_version: 1,
          state: state_h
        }
      end

      def state_h
        {
          your_id: your_id, hand: hand, top_card: top_card,
          game_state: game_state, stacked_cards: stacked_cards,
          already_picked: already_picked, picked_card: picked_card,
          other_players: other_players.map(&:to_h),
          available_actions: available_actions, playable_cards: playable_cards
        }
      end

      def to_h
        protocol_h.merge(metadata: metadata)
      end

      private

      def strings(values)
        Array(values).map { |value| String(value).dup.freeze }.freeze
      end

      def symbolize(hash)
        hash.each_with_object({}) { |(key, value), result| result[key.to_sym] = value }
      end

      def deep_freeze(value)
        case value
        when Hash
          value.each { |key, child| deep_freeze(key); deep_freeze(child) }
        when Array
          value.each { |child| deep_freeze(child) }
        else
          value.freeze
        end
        value.freeze
      end

      def validate!
        raise ValidationError, 'your_id cannot be empty' if your_id.empty?
        raise ValidationError, "invalid top card #{top_card.inspect}" unless Cards.valid?(top_card)
        raise ValidationError, "unknown game state #{game_state.inspect}" unless GAMES.include?(game_state)
        raise ValidationError, 'stacked_cards cannot be negative' if stacked_cards.negative?
        hand.each { |card| raise ValidationError, "invalid hand card #{card.inspect}" unless Cards.valid?(card, allow_colored_wild: false) }
        raise ValidationError, 'picked_card required after drawing' if already_picked && picked_card.nil?
        raise ValidationError, 'picked_card forbidden before drawing' if !already_picked && picked_card
        if picked_card && !hand.include?(picked_card)
          raise ValidationError, 'picked_card must be in hand'
        end
        unknown = available_actions - ACTIONS
        raise ValidationError, "unknown available actions: #{unknown.join(', ')}" unless unknown.empty?
        unless (playable_cards - hand).empty?
          raise ValidationError, 'playable_cards must be in hand'
        end
      end
    end
  end
end
