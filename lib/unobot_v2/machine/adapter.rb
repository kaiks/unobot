# frozen_string_literal: true

require_relative '../interfaces'
require_relative 'frame_buffer'

module UnobotV2
  module Machine
    class Adapter < MessagingAdapter
      Result = Struct.new(:code, :message, :line, :request, :retryable, :event,
                          keyword_init: true) do
        def success? = code == :ok
        def error? = !success?
      end

      REASONS = %w[turn_started card_drawn registration_sync].freeze
      TERMINAL_EVENTS = %w[
        game_ended stopped unregistered nick_changed parted quit kicked
        disconnected plugin_unloaded
      ].freeze
      HISTORY_LIMIT = 64
      DEFAULT_ACK_TIMEOUT = 30.0

      attr_reader :channel, :own_nick, :host_nick, :game_id, :lifecycle,
                  :active_request, :last_error, :frame_buffer
      attr_writer :lifecycle_token, :token_validator

      def initialize(channel:, own_nick:, host_nicks:, transport:, on_request: nil,
                     on_status: nil, frame_buffer: FrameBuffer.new,
                     clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                     ack_timeout: DEFAULT_ACK_TIMEOUT)
        @channel = channel.to_s.downcase.freeze
        @own_nick = own_nick.to_s.dup.freeze
        @host_nicks = Array(host_nicks).map { |nick| nick.to_s.downcase }.freeze
        raise ArgumentError, 'at least one host nick is required' if @host_nicks.empty?

        @host_nick = Array(host_nicks).first.to_s.dup.freeze
        @transport = transport
        @on_request = on_request
        @on_status = on_status
        @frame_buffer = frame_buffer
        @clock = clock
        @ack_timeout = Float(ack_timeout)
        raise ArgumentError, 'ack timeout must be positive' unless @ack_timeout.positive?
        @lifecycle = :unregistered
        @seen_decisions = []
        @submitted_decision_id = nil
        @active_lifecycle_token = nil
        @connected = true
      end

      def start
        @lifecycle = :unregistered if lifecycle == :stopped
        register!
      end

      def register!
        return failure(:disconnected, 'IRC is disconnected') unless @connected
        return failure(:stopped, 'adapter is stopped') if lifecycle == :stopped

        invalidate_decision!
        @game_id = nil
        @frame_buffer.clear
        @lifecycle = :registering
        send_line(channel, '.uno machine register')
      end

      def registering? = lifecycle == :registering
      def registered? = !game_id.nil? && %i[registered active awaiting_ack].include?(lifecycle)

      def receive(input)
        message = input.is_a?(Protocol::Message) ? input : parse_input(input)
        return message if message.is_a?(Result)

        case message.kind
        when :registered then receive_registered(message)
        when :state, :event then receive_chunk(message)
        when :ack then receive_ack(message)
        when :error then receive_error(message)
        else failure(:unsupported_message)
        end
      rescue StandardError => error
        fail_closed!(:adapter_error, error.message, reregister: false)
      end

      def submit(action, decision_id:)
        return failure(:unregistered, 'machine session is not registered') unless registered?
        unless active_request && decision_id == active_request.decision_id
          return failure(:stale_decision, 'decision is no longer active')
        end
        unless token_valid?(@active_lifecycle_token)
          return failure(:invalidated_decision, 'session was invalidated')
        end
        if @submitted_decision_id == decision_id
          return failure(:duplicate_action, 'action is awaiting acknowledgement')
        end

        canonical = Canonical::Action.from(action)
        validation = validate_action(canonical)
        return validation if validation

        encoded = Protocol.encode_action(game_id: game_id, decision_id: decision_id, action: canonical)
        return failure(encoded.error.code, encoded.error.message) if encoded.failure?
        return failure(:invalidated_decision, 'session was invalidated') unless token_valid?(@active_lifecycle_token)

        sent = send_line(host_nick, encoded.value)
        return sent if sent.error?

        @submitted_decision_id = decision_id
        @action_sent_at = now
        @lifecycle = :awaiting_ack
        success(line: encoded.value)
      rescue Canonical::ValidationError => error
        failure(:invalid_action, error.message)
      end

      def tick
        expired = frame_buffer.expire!
        unless expired.empty?
          return fail_closed!(:missing_chunks, 'machine frame expired before completion', reregister: true)
        end
        if lifecycle == :awaiting_ack && @action_sent_at && now - @action_sent_at >= @ack_timeout
          return fail_closed!(:ack_timeout, 'action acknowledgement was lost', reregister: true)
        end

        success
      end

      def resync!(reason = 'manual_resync')
        fail_closed!(reason.to_sym, reason.to_s, reregister: @connected)
      end

      def disconnect!
        @connected = false
        invalidate_session!(:disconnected)
        success(event: :disconnected)
      end

      def reconnect!
        @connected = true
        register!
      end

      def rename!(new_nick)
        @own_nick = new_nick.to_s.dup.freeze
        invalidate_session!(:nick_changed)
        register!
      end

      def unregister!
        result = send_line(channel, '.uno machine unregister')
        invalidate_session!(:unregistered)
        result
      end

      def stop!
        invalidate_session!(:stopped)
        @lifecycle = :stopped
        success(event: :stopped)
      end

      private

      def parse_input(input)
        parsed = Protocol.parse(input.respond_to?(:text) ? input.text : input)
        return failure(parsed.error.code, parsed.error.message) if parsed.failure?

        parsed.value
      end

      def receive_registered(message)
        return failure(:unexpected_registration, 'no registration is pending') unless registering?
        return failure(:channel_mismatch, 'registration belongs to another channel') unless message.channel == channel

        @game_id = message.game_id
        @lifecycle = :registered
        @last_error = nil
        status(:registered)
        success
      end

      def receive_chunk(message)
        return failure(:unknown_game, 'frame is not for this session') unless game_id == message.game_id

        assembled = frame_buffer.accept(message)
        if assembled.expired.any? || assembled.evicted.any?
          return fail_closed!(:missing_chunks, 'an incomplete machine frame was lost', reregister: true)
        end
        if assembled.failure?
          return fail_closed!(assembled.error.code, assembled.error.message, reregister: true)
        end
        return success unless assembled.complete?

        message.kind == :state ? receive_state(assembled.payload) : receive_event(assembled.payload)
      end

      def receive_state(payload)
        decision_id = payload.fetch('decision_id')
        reason = payload.fetch('reason')
        return failure(:invalid_decision_id) unless Protocol.token?(decision_id, allow_dash: false)
        return failure(:invalid_reason) unless REASONS.include?(reason)
        decision_key = [game_id, decision_id]
        return success if @seen_decisions.include?(decision_key)

        request = Canonical::DecisionRequest.from_protocol(
          payload.fetch('request'),
          metadata: {
            channel: channel, transport: 'machine', safe: true,
            game_id: game_id, decision_id: decision_id, reason: reason,
            lifecycle: lifecycle.to_s
          }
        )
        remember_decision(decision_key)
        @active_request = request
        @submitted_decision_id = nil
        @active_lifecycle_token = @lifecycle_token
        @lifecycle = :active
        status(:action_required, request: request)
        @on_request&.call(request)
        success(request: request)
      rescue Canonical::ValidationError, KeyError => error
        fail_closed!(:invalid_state, error.message, reregister: true)
      end

      def receive_ack(message)
        return failure(:unknown_game) unless message.game_id == game_id
        unless @submitted_decision_id == message.decision_id && lifecycle == :awaiting_ack
          return failure(:stale_ack)
        end

        invalidate_decision!
        @lifecycle = :registered
        status(:acknowledged, event: message.action)
        success(event: message.action.to_sym)
      end

      def receive_error(message)
        return receive_registration_error(message) if message.game_id == '-'
        return failure(:unknown_game) unless message.game_id == game_id
        if message.decision_id != '-' && active_request&.decision_id != message.decision_id
          return failure(:stale_error)
        end

        @last_error = message.code.freeze
        if message.retryable
          @submitted_decision_id = nil
          @lifecycle = :active
          status(:retryable_error, event: message.code)
          failure(message.code.to_sym, message.code, retryable: true)
        else
          fail_closed!(message.code.to_sym, message.code,
                       reregister: true)
        end
      end

      def receive_registration_error(message)
        return failure(:unexpected_error) unless registering?

        @last_error = message.code.freeze
        @lifecycle = :unregistered
        status(:registration_error, event: message.code)
        failure(message.code.to_sym, message.code, retryable: message.retryable)
      end

      def receive_event(payload)
        event = payload.fetch('event')
        return failure(:unknown_event) unless TERMINAL_EVENTS.include?(event)

        invalidate_session!(event.to_sym)
        @connected = false if event == 'disconnected'
        @lifecycle = :stopped if event == 'plugin_unloaded'
        status(:terminal_event, event: event)
        success(event: event.to_sym)
      end

      def validate_action(action)
        request = active_request
        return failure(:action_unavailable) unless request.available_actions.include?(action.action)
        return nil unless action.action == 'play'
        return failure(:card_not_playable) unless request.playable_cards.include?(action.card)
        if action.double_play && (request.already_picked || request.hand.count(action.card) < 2)
          return failure(:double_unavailable)
        end
        nil
      end

      def fail_closed!(code, message, reregister:)
        @last_error = code.to_s.freeze
        invalidate_session!(:recovering)
        status(:fail_closed, event: code)
        if reregister && @connected && lifecycle != :stopped
          recovery = register!
          return recovery if recovery.error?

          return failure(code, message, line: recovery.line)
        end

        failure(code, message)
      end

      def invalidate_session!(next_lifecycle)
        invalidate_decision!
        @frame_buffer.clear
        @game_id = nil
        @lifecycle = next_lifecycle
      end

      def invalidate_decision!
        @active_request = nil
        @submitted_decision_id = nil
        @action_sent_at = nil
        @active_lifecycle_token = nil
      end

      def remember_decision(decision_key)
        @seen_decisions << decision_key.freeze
        @seen_decisions.shift while @seen_decisions.length > HISTORY_LIMIT
      end

      def send_line(target, line)
        @transport.call(target, line)
        success(line: line)
      rescue StandardError => error
        invalidate_session!(:recovering)
        failure(:transport_unavailable, error.message)
      end

      def token_valid?(token)
        !@token_validator || @token_validator.call(token)
      end

      def now
        Float(@clock.call)
      end

      def status(code, **values)
        @on_status&.call(Result.new(code: code, **values))
      end

      def success(**values)
        Result.new(code: :ok, **values)
      end

      def failure(code, message = code.to_s, **values)
        Result.new(code: code.to_sym, message: message, **values)
      end
    end
  end
end
