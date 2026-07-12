# frozen_string_literal: true

require_relative '../canonical'
require_relative '../rules'
require_relative 'card_parser'

module UnobotV2
  module Human
    Event = Struct.new(:channel, :source, :text, :private, :recipient, :kind,
                       :old_nick, :new_nick, keyword_init: true) do
      def initialize(**values)
        super
        self.channel = channel.to_s.downcase.freeze
        self.text = text.to_s.freeze
        self.kind ||= :message
        freeze
      end
    end

    Reduction = Struct.new(:request, :commands, :changed, :reason, keyword_init: true) do
      def initialize(request: nil, commands: [], changed: false, reason: nil)
        super
        commands.freeze
        freeze
      end
    end

    class Reducer
      STATUS_RE = /\AUNO_STATUS_V1 phase=(waiting|active|ended) current=([^ ]+) top=([^ ]+) mode=([^ ]+) stacked_cards=(\d+) already_picked=([01]) players=(.*)\z/
      PRIVATE_RE = /\AUNO_STATUS_PRIVATE_V1 picked_card=([^ ]+)\z/
      TURN_RE = /\A(?:(\S+) passes\. )?(\S+)'s turn\. Top card: (.+)\z/
      DRAW_RE = /\A(\S+) draws a card\.\z/
      JOIN_RE = /\A(\S+) joins the game\z/
      COUNT_RE = /\ACard count: (.+)\z/
      ORDER_RE = /\ACurrent (?:order|player order is): (.+)\z/

      attr_reader :channel, :own_nick, :phase, :unsafe_reasons

      def initialize(channel:, own_nick:, host_nicks:, rules: Rules.new)
        @channel = channel.to_s.downcase.freeze
        @own_nick = own_nick.to_s.dup.freeze
        @host_nicks = host_nicks.map(&:downcase).freeze
        @rules = rules
        reset
      end

      def receive(event)
        return Reduction.new unless event.channel == channel
        return rename(event) if event.kind == :nick
        return lifecycle(event.kind) if %i[disconnect reconnect].include?(event.kind)
        return Reduction.new unless host?(event.source)

        event.private ? receive_private(event) : receive_public(event)
      rescue StandardError => error
        uncertain!("reducer_error:#{error.class}")
        Reduction.new(commands: resync_commands, changed: true, reason: error.message)
      end

      def safe?
        phase == 'active' && @current == own_nick && @hand && @top_card &&
          @players.any? && @mode != 'unknown' && @unsafe_reasons.empty? &&
          (!@already_picked || @picked_card)
      end

      def current_request
        return unless safe?

        derived = @rules.derive(hand: @hand, top_card: @top_card, game_state: @mode,
                                stacked_cards: @stacked, already_picked: @already_picked,
                                picked_card: @picked_card)
        others = ordered_after_own.map do |nick|
          Canonical::PlayerCount.new(id: nick, card_count: @counts.fetch(nick))
        end
        decision_key = [@generation, @turn_number, @current, @top_card, @stacked,
                        @already_picked, @picked_card, @hand].hash.to_s(36)
        Canonical::DecisionRequest.new(
          your_id: own_nick, hand: @hand, top_card: @top_card,
          game_state: @mode, stacked_cards: @stacked,
          already_picked: @already_picked, picked_card: @picked_card,
          other_players: others, available_actions: derived.available_actions,
          playable_cards: derived.playable_cards,
          metadata: {
            channel: channel, transport: 'human', decision_id: decision_key,
            safe: true, confidence: overall_confidence,
            facts: @facts.dup, generation: @generation, turn: @turn_number
          }
        )
      end

      def refuse!(reason)
        uncertain!(reason)
      end

      def resync_commands
        %w[us ca]
      end

      private

      def reset
        @phase = 'off'
        @current = nil
        @top_card = nil
        @mode = 'off'
        @stacked = 0
        @already_picked = false
        @picked_card = nil
        @players = []
        @counts = {}
        @hand = nil
        @facts = {}
        @unsafe_reasons = ['no_complete_state']
        @status_seen = false
        @private_status_seen = false
        @generation = (@generation || 0) + 1
        @turn_number = 0
        @double_pending = false
        @drawn_this_turn = {}
        @private_penalty_draw = {}
        @last_turn_line = nil
        @last_status_signature = nil
        @pending_count_assertions = {}
      end

      def host?(nick)
        @host_nicks.include?(nick.to_s.downcase)
      end

      def private_for_us?(event)
        event.recipient.nil? || event.recipient.to_s.casecmp?(own_nick)
      end

      def receive_private(event)
        return Reduction.new unless private_for_us?(event)

        return apply_status(STATUS_RE.match(event.text)) if STATUS_RE.match?(event.text)

        if (match = PRIVATE_RE.match(event.text))
          return apply_private_status(match[1])
        end

        cards = CardParser.hand(event.text)
        return Reduction.new if cards.empty?

        if event.text.start_with?('You draw ')
          @hand ||= []
          @hand = (@hand + cards).sort.freeze
          if cards.one?
            @picked_card = cards.first
            @already_picked = true
          else
            increment(own_nick, cards.length)
            @private_penalty_draw[own_nick] = cards.length
            @picked_card = nil
            uncertain!('awaiting_penalty_pass')
          end
          @facts[:hand] = 'exact'
          @facts[:picked_card] = 'exact'
          @unsafe_reasons.delete('awaiting_private_draw') if cards.one?
        else
          @hand = cards.freeze
          @facts[:hand] = 'exact'
        end
        complete_resync_if_possible
        reduction_with_request
      end

      def receive_public(event)
        text = event.text
        return apply_status(STATUS_RE.match(text)) if STATUS_RE.match?(text)
        return game_created if text.match?(/\AOk,? -? ?created .* game on /i)
        return player_joined(JOIN_RE.match(text)[1]) if JOIN_RE.match?(text)
        return counts(COUNT_RE.match(text)[1]) if COUNT_RE.match?(text)
        return order(ORDER_RE.match(text)[1]) if ORDER_RE.match?(text)
        return count_announcement(text) if text.include?('has only') || text.include?('has just one card left')
        return turn(TURN_RE.match(text)) if TURN_RE.match?(text)
        return drew(DRAW_RE.match(text)[1]) if DRAW_RE.match?(text)
        return double_pending if text == '[Playing two cards]'
        return reverse_order(text) if text.match?(/\APlayer order reversed(?: twice)?!\z/)
        return game_end if text.match?(/ gains \d+ points\.|loses instantly|Uno game has been stopped\./)
        if text.include?("'s turn") || text.include?('Top card:') || text.start_with?('Card count:')
          uncertain!('malformed_game_event')
          return Reduction.new(commands: resync_commands, changed: true)
        end
        return Reduction.new if informational?(text)

        Reduction.new
      end

      def apply_status(match)
        phase, current, top, mode, stacked, already, players_text = match.captures
        signature = match.captures.freeze
        if signature == @last_status_signature && @unsafe_reasons.empty?
          return Reduction.new
        end
        parsed = parse_players(players_text)
        if parsed.empty? || (phase == 'active' && (current == '-' || top == '-'))
          uncertain!('malformed_status')
          return Reduction.new(commands: resync_commands, changed: true)
        end
        @phase = phase
        @current = current == '-' ? nil : current
        @top_card = top == '-' ? nil : top
        @mode = mode
        @stacked = stacked.to_i
        @already_picked = already == '1'
        @picked_card = nil
        @players = parsed.map(&:first)
        @counts = parsed.to_h
        @hand = nil
        @status_seen = true
        @last_status_signature = signature
        @private_status_seen = !@already_picked || @current != own_nick
        %i[phase current top_card game_state stacked_cards already_picked players].each { |fact| @facts[fact] = 'exact' }
        if phase != 'active'
          @unsafe_reasons = ['game_not_active']
          return Reduction.new(changed: true)
        end
        complete_resync_if_possible
        reduction_with_request
      end

      def apply_private_status(card)
        return Reduction.new unless @status_seen && @current == own_nick

        @picked_card = card == '-' ? nil : Canonical::Cards.base(card)
        @private_status_seen = true
        @facts[:picked_card] = 'exact'
        complete_resync_if_possible
        uncertain!('status_picked_card_mismatch') if @already_picked != !@picked_card.nil?
        reduction_with_request
      end

      def complete_resync_if_possible
        complete = @status_seen && @hand && @players.include?(own_nick) &&
                   (!@already_picked || @current != own_nick || @private_status_seen)
        return unless complete

        @unsafe_reasons.clear
        uncertain!('status_hand_count_mismatch') unless @counts[own_nick] == @hand.length
        if @picked_card && !@hand.include?(@picked_card)
          uncertain!('status_picked_card_not_in_hand')
        end
        @status_seen = false
        @private_status_seen = false
      end

      def game_created
        reset
        @phase = 'waiting'
        Reduction.new(changed: true)
      end

      def player_joined(nick)
        @players << nick unless @players.include?(nick)
        @counts[nick] ||= 0
        @facts[:players] = 'derived'
        Reduction.new(changed: true)
      end

      def counts(text)
        pairs = text.split(/,\s*/).filter_map do |piece|
          match = /\A(.+?) (\d+)\z/.match(piece)
          [match[1], match[2].to_i] if match
        end
        if pairs.empty?
          uncertain!('malformed_card_count')
          return Reduction.new(commands: resync_commands, changed: true)
        end
        @players = pairs.map(&:first) if @players.empty?
        @counts.merge!(pairs.to_h)
        @facts[:players] = 'exact'
        @unsafe_reasons.delete('no_complete_state') if continuously_complete?
        reduction_with_request
      end

      def order(text)
        ordered = text.split
        if ordered.empty? || ordered.uniq.length != ordered.length ||
           (!@players.empty? && ordered.sort != @players.sort)
          uncertain!('inconsistent_player_order')
          return Reduction.new(commands: resync_commands, changed: true)
        end

        @players = ordered
        @facts[:players] = 'exact'
        reduction_with_request
      end

      def count_announcement(text)
        match = /(\S+) has (?:only .*three.* cards left|just one card left)!/.match(text)
        return Reduction.new unless match

        @pending_count_assertions[match[1]] = text.include?('just one') ? 1 : 3
        Reduction.new(changed: true)
      end

      def turn(match)
        return Reduction.new if match[0] == @last_turn_line

        passer, current, card_text = match.captures
        cards = CardParser.parse_all(card_text)
        if cards.length != 1
          uncertain!('malformed_top_card')
          return Reduction.new(commands: resync_commands, changed: true)
        end
        new_top = cards.first
        previous = @current
        was_double = @double_pending
        expected = expected_next(new_top, was_double) if previous && !passer
        inconsistent = expected && expected != current
        uncertain!('inconsistent_turn_order') if inconsistent
        if previous && !passer && previous != current
          decrement(previous, was_double ? 2 : 1)
          remove_own_cards(Canonical::Cards.base(new_top), was_double ? 2 : 1) if previous == own_nick
          inconsistent ||= !validate_count_assertion(previous)
        elsif passer
          unless passer == previous || previous.nil?
            uncertain!('unexpected_passer')
            return Reduction.new(commands: resync_commands, changed: true)
          end
          penalty = if @private_penalty_draw.delete(passer)
                      0
                    elsif @stacked.positive?
                      @stacked
                    else
                      @drawn_this_turn[passer] ? 0 : 1
                    end
          increment(passer, penalty) if penalty.positive?
        end
        @turn_number += 1
        @last_turn_line = match[0]
        @phase = 'active'
        @current = current
        @top_card = new_top
        @already_picked = false
        @picked_card = nil
        @drawn_this_turn.clear
        @private_penalty_draw.clear
        @unsafe_reasons.delete('awaiting_penalty_pass')
        @double_pending = false
        if passer
          @mode = 'normal'
          @stacked = 0
        else
          mode_from_top(new_top, double: was_double)
        end
        reverse_players_for(new_top, was_double) unless passer
        rotate_to(current)
        @facts.merge!(current: 'derived', top_card: 'exact', game_state: 'derived',
                      stacked_cards: 'derived', already_picked: 'derived')
        @unsafe_reasons.delete('no_complete_state') if continuously_complete?
        if inconsistent
          reason = @unsafe_reasons.last.to_s.tr('_', ' ')
          Reduction.new(commands: resync_commands, changed: true, reason: reason)
        else
          reduction_with_request
        end
      end

      def drew(nick)
        increment(nick, 1)
        @drawn_this_turn[nick] = true
        if nick == own_nick
          @already_picked = true
          @picked_card = nil
          @facts[:already_picked] = 'exact'
          uncertain!('awaiting_private_draw')
        end
        reduction_with_request
      end

      def double_pending
        if @double_pending
          uncertain!('duplicate_double_marker')
          Reduction.new(commands: resync_commands, changed: true)
        else
          @double_pending = true
          Reduction.new(changed: true)
        end
      end

      def reverse_order(text)
        @facts[:players] = 'derived'
        Reduction.new(changed: true)
      end

      def game_end
        @phase = 'ended'
        @current = nil
        @unsafe_reasons = ['game_ended']
        Reduction.new(changed: true)
      end

      def lifecycle(kind)
        uncertain!('disconnected')
        @generation += 1
        commands = kind == :reconnect ? resync_commands : []
        Reduction.new(commands: commands, changed: true)
      end

      def rename(event)
        old_nick = event.old_nick.to_s
        new_nick = event.new_nick.to_s
        return Reduction.new if old_nick.empty? || new_nick.empty?

        @players.map! { |nick| nick.casecmp?(old_nick) ? new_nick : nick }
        if (count = @counts.delete(old_nick))
          @counts[new_nick] = count
        end
        @current = new_nick if @current&.casecmp?(old_nick)
        @own_nick = new_nick.freeze if own_nick.casecmp?(old_nick)
        @facts[:players] = 'exact'
        reduction_with_request
      end

      def parse_players(text)
        text.split(',').filter_map do |entry|
          match = /\A([^,:]+):(\d+)\z/.match(entry)
          [match[1], match[2].to_i] if match
        end
      end

      def continuously_complete?
        @hand && @top_card && @players.include?(own_nick) && @players.all? { |nick| @counts.key?(nick) }
      end

      def mode_from_top(card, double: false)
        multiplier = double ? 2 : 1
        case Canonical::Cards.base(card)
        when 'wd4'
          @mode = 'war_wd4'
          @stacked += 4 * multiplier
        when /\+2\z/
          @mode = 'war_+2' unless @mode == 'war_wd4'
          @stacked += 2 * multiplier
        else
          unless %w[war_+2 war_wd4].include?(@mode)
            @mode = 'normal'
            @stacked = 0
          end
        end
      end

      def expected_next(card, double)
        return unless @players.first == @current && @players.length > 1

        base = Canonical::Cards.base(card)
        figure = %w[w wd4].include?(base) ? base : base[1..]
        case figure
        when 'r'
          ordered = double ? @players : @players.reverse
          ordered.rotate(1).first
        when 's'
          @players.rotate(double ? 3 : 2).first
        else
          @players.rotate(1).first
        end
      end

      def rotate_to(nick)
        index = @players.index(nick)
        @players.rotate!(index) if index
      end

      def reverse_players_for(card, double)
        base = Canonical::Cards.base(card)
        @players.reverse! if !double && base.end_with?('r') && !%w[w wd4].include?(base)
      end

      def decrement(nick, count)
        return uncertain!('missing_player_count') unless @counts.key?(nick)

        @counts[nick] -= count
        uncertain!('negative_player_count') if @counts[nick].negative?
      end

      def increment(nick, count)
        return uncertain!('missing_player_count') unless @counts.key?(nick)

        @counts[nick] += count
      end

      def validate_count_assertion(nick)
        expected = @pending_count_assertions.delete(nick)
        return true unless expected && @counts[nick] != expected

        uncertain!('inconsistent_player_count')
        false
      end

      def remove_own_cards(card, count)
        return unless @hand

        mutable = @hand.dup
        count.times do
          index = mutable.index(card)
          return uncertain!('played_card_missing_from_hand') unless index

          mutable.delete_at(index)
        end
        @hand = mutable.freeze
        @facts[:hand] = 'derived'
      end

      def ordered_after_own
        index = @players.index(own_nick)
        return [] unless index

        @players.rotate(index).drop(1)
      end

      def overall_confidence
        @facts.values.include?('uncertain') ? 'uncertain' :
          (@facts.values.include?('derived') ? 'derived' : 'exact')
      end

      def uncertain!(reason)
        @unsafe_reasons << reason unless @unsafe_reasons.include?(reason)
        @facts[:coherence] = 'uncertain'
      end

      def reduction_with_request
        Reduction.new(request: current_request, changed: true)
      end

      def informational?(text)
        text.match?(/\A(?:Next player must respond|Player order reversed|.+ (?:was|were) skipped|Reshuffling discard pile|Sorry |You have to pick|Current (?:order|player order)|\x02?\x03\d+UNO|Hey )/)
      end
    end
  end
end
