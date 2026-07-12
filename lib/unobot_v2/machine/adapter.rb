# frozen_string_literal: true

require_relative '../interfaces'
require_relative 'frame_buffer'

module UnobotV2
  module Machine
    class Adapter < MessagingAdapter
      Result = Struct.new(:code, :message, :line, :request, :retryable, :event,
                          :game_id, :channel,
                          keyword_init: true) do
        def success? = code == :ok
        def error? = !success?
      end

      REASONS = %w[turn_started card_drawn registration_sync].freeze
      TERMINAL_EVENTS = %w[
        game_ended stopped unregistered nick_changed parted quit kicked
        disconnected plugin_unloaded
      ].freeze
      TRANSIENT_TERMINAL_EVENTS = %w[nick_changed parted quit kicked disconnected].freeze
      TERMINAL_ERROR_CODES = %w[
        no_game not_allowlisted not_player game_changed registration_taken
        not_registered unknown_game game_ended unauthorized
      ].freeze
      HISTORY_LIMIT = 64
      DEFAULT_ACK_TIMEOUT = 30.0
      DEFAULT_REGISTRATION_TIMEOUT = 30.0
      DEFAULT_RENAME_RECOVERY_TIMEOUT = 30.0
      DEFAULT_RENAME_RETRY_INTERVAL = 1.0

      attr_reader :channel, :own_nick, :host_nick, :game_id, :lifecycle,
                  :active_request, :last_error, :frame_buffer, :callback_errors
      attr_writer :lifecycle_token, :token_validator

      def initialize(channel:, own_nick:, host_nicks:, transport:, on_request: nil,
                     on_status: nil, frame_buffer: FrameBuffer.new,
                     clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                     ack_timeout: DEFAULT_ACK_TIMEOUT,
                     registration_timeout: DEFAULT_REGISTRATION_TIMEOUT,
                     rename_recovery_timeout: DEFAULT_RENAME_RECOVERY_TIMEOUT,
                     rename_retry_interval: DEFAULT_RENAME_RETRY_INTERVAL)
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
        @registration_timeout = Float(registration_timeout)
        raise ArgumentError, 'registration timeout must be positive' unless @registration_timeout.positive?
        @rename_recovery_timeout = Float(rename_recovery_timeout)
        @rename_retry_interval = Float(rename_retry_interval)
        if !@rename_recovery_timeout.positive? || !@rename_retry_interval.positive?
          raise ArgumentError, 'rename recovery limits must be positive'
        end
        @lifecycle = :unregistered
        @seen_decisions = []
        @submitted_decision_id = nil
        @active_lifecycle_token = nil
        @connected = true
        @callback_errors = Queue.new
      end

      def start
        @lifecycle = :unregistered if lifecycle == :stopped
        register!
      end

      def register!
        return failure(:disconnected, 'IRC is disconnected') unless @connected
        return failure(:stopped, 'adapter is stopped') if lifecycle == :stopped

        previous_request = @active_request
        previous_game_id = @game_id
        invalidate_decision!
        @game_id = nil
        @frame_buffer.clear
        @lifecycle = :registering
        result = send_line(channel, '.uno machine register')
        @registration_started_at = now if result.success?
        if previous_game_id
          status(:session_cancelled, event: 'registration_reset', request: previous_request,
                 game_id: previous_game_id, channel: channel)
        end
        result
      end

      def registering? = lifecycle == :registering
      def rename_recovering? = !@rename_recovery_deadline.nil?
      def registered? = !game_id.nil? && %i[registered active awaiting_ack].include?(lifecycle)
      def connected? = @connected
      def can_unregister? = connected? && !%i[unregistered stopped disconnected].include?(lifecycle)

      def receive(input, source: nil)
        message = input.is_a?(Protocol::Message) ? input : parse_input(input)
        return message if message.is_a?(Result)

        case message.kind
        when :registered then receive_registered(message, source)
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
        @submitted_action_type = canonical.action
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
        if rename_recovering? && now >= @rename_recovery_deadline
          @rename_recovery_deadline = nil
          @rename_retry_at = nil
          @lifecycle = :unregistered
          return failure(:rename_recovery_timeout, 'host player rename did not become visible')
        end
        if rename_recovering? && %i[registering rename_recovery].include?(lifecycle) &&
           @rename_retry_at && now >= @rename_retry_at
          @rename_retry_at = now + @rename_retry_interval
          retried = register!
          return retried if retried.error?

          return failure(:rename_retry, 'retrying registration after host rename', line: retried.line,
                          retryable: true)
        end
        if lifecycle == :awaiting_ack && @action_sent_at && now - @action_sent_at >= @ack_timeout
          return fail_closed!(:ack_timeout, 'action acknowledgement was lost', reregister: true)
        end
        if lifecycle == :registering && @registration_started_at &&
           now - @registration_started_at >= @registration_timeout
          retried = register!
          return retried if retried.error?

          return failure(:registration_timeout, 'registration response was lost', line: retried.line)
        end

        success
      end

      def resync!(reason = 'manual_resync')
        fail_closed!(reason.to_sym, reason.to_s, reregister: @connected)
      end

      def disconnect!
        request = @active_request
        previous_game_id = @game_id
        @connected = false
        invalidate_session!(:disconnected)
        status(:session_cancelled, event: 'disconnected', request: request,
               game_id: previous_game_id, channel: channel) if previous_game_id
        success(event: :disconnected)
      end

      def reconnect!
        @connected = true
        register!
      end

      def rename!(new_nick)
        @own_nick = new_nick.to_s.dup.freeze
        invalidate_session!(:nick_changed)
        @rename_recovery_deadline = now + @rename_recovery_timeout
        @rename_retry_at = now + @rename_retry_interval
        register!
      end

      def unregister!
        request = @active_request
        previous_game_id = @game_id
        result = send_line(channel, '.uno machine unregister')
        if result.success?
          invalidate_session!(:unregistered)
          status(:session_cancelled, event: 'unregistered', request: request,
                 game_id: previous_game_id, channel: channel) if previous_game_id
        end
        result
      end

      def accepts_source?(source)
        host_nick.to_s.casecmp?(source.to_s)
      end

      def host_renamed!(old_nick, new_nick)
        return success unless host_nick.to_s.casecmp?(old_nick.to_s)
        unless @host_nicks.include?(new_nick.to_s.downcase)
          return fail_closed!(:host_changed, 'bound host changed to an unconfigured nick', reregister: false)
        end

        @host_nick = new_nick.to_s.dup.freeze
        success(event: :host_renamed)
      end

      def stop!
        request = @active_request
        previous_game_id = @game_id
        invalidate_session!(:stopped)
        @lifecycle = :stopped
        status(:session_cancelled, event: 'stopped', request: request,
               game_id: previous_game_id, channel: channel) if previous_game_id
        success(event: :stopped)
      end

      private

      def parse_input(input)
        parsed = Protocol.parse(input.respond_to?(:text) ? input.text : input)
        return failure(parsed.error.code, parsed.error.message) if parsed.failure?

        parsed.value
      end

      def receive_registered(message, source)
        return failure(:unexpected_registration, 'no registration is pending') unless registering?
        return failure(:channel_mismatch, 'registration belongs to another channel') unless message.channel == channel
        return failure(:missing_host_source, 'registration source is required') if source.to_s.empty?
        return failure(:unauthorized_host, 'registration source is not configured') unless @host_nicks.include?(source.to_s.downcase)

        @host_nick = source.to_s.dup.freeze
        @game_id = message.game_id
        @registration_started_at = nil
        @rename_recovery_deadline = nil
        @rename_retry_at = nil
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
        unless Protocol.token?(decision_id, allow_dash: false)
          return fail_closed!(:invalid_decision_id, 'STATE decision ID is invalid', reregister: true)
        end
        unless REASONS.include?(reason)
          return fail_closed!(:invalid_reason, 'STATE reason is invalid', reregister: true)
        end
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
        begin
          @on_request&.call(request)
        rescue StandardError => error
          @callback_errors << error
          return fail_closed!(:strategy_error, error.message,
                              reregister: token_valid?(@active_lifecycle_token))
        end
        success(request: request)
      rescue Canonical::ValidationError, KeyError => error
        fail_closed!(:invalid_state, error.message, reregister: true)
      end

      def receive_ack(message)
        return failure(:unknown_game) unless message.game_id == game_id
        unless @submitted_decision_id == message.decision_id && lifecycle == :awaiting_ack
          return failure(:stale_ack)
        end
        if @submitted_action_type != message.action
          return fail_closed!(:ack_mismatch, 'ACK action does not match the submission', reregister: true)
        end

        invalidate_decision!
        @lifecycle = :registered
        status(:acknowledged, event: message.action)
        success(event: message.action.to_sym)
      end

      def receive_error(message)
        return receive_registration_error(message) if message.game_id == '-'
        return failure(:unknown_game) unless message.game_id == game_id

        @last_error = message.code.freeze
        if message.retryable
          unless lifecycle == :awaiting_ack && @submitted_decision_id == message.decision_id &&
                 active_request && message.decision_id == active_request.decision_id
            return fail_closed!(:invalid_retry, 'retryable error has no active decision', reregister: true)
          end
          @submitted_decision_id = nil
          @submitted_action_type = nil
          @action_sent_at = nil
          @lifecycle = :active
          status(:retryable_error, event: message.code)
          failure(message.code.to_sym, message.code, retryable: true)
        else
          if message.decision_id != '-' && active_request&.decision_id != message.decision_id
            return failure(:stale_error)
          end
          if TERMINAL_ERROR_CODES.include?(message.code)
            request = @active_request
            previous_game_id = @game_id
            invalidate_session!(message.code.to_sym)
            status(:terminal_error, event: message.code, request: request,
                   game_id: previous_game_id, channel: channel)
            return failure(message.code.to_sym, message.code)
          end
          fail_closed!(message.code.to_sym, message.code,
                       reregister: true)
        end
      end

      def receive_registration_error(message)
        return failure(:unexpected_error) unless registering?

        @last_error = message.code.freeze
        if message.code == 'not_player' && rename_recovering?
          @lifecycle = :rename_recovery
          @registration_started_at = nil
          @rename_retry_at = now + @rename_retry_interval
          status(:rename_retry_scheduled, event: message.code)
          return failure(:not_player, message.code, retryable: true)
        end

        @lifecycle = :unregistered
        @registration_started_at = nil
        @rename_recovery_deadline = nil
        @rename_retry_at = nil
        status(:registration_error, event: message.code)
        failure(message.code.to_sym, message.code, retryable: message.retryable)
      end

      def receive_event(payload)
        event = payload.fetch('event')
        return failure(:unknown_event) unless TERMINAL_EVENTS.include?(event)

        request = @active_request
        previous_game_id = @game_id
        invalidate_session!(event.to_sym)
        @lifecycle = :stopped if event == 'plugin_unloaded'
        status(:terminal_event, event: event, request: request,
               game_id: previous_game_id, channel: channel)
        if TRANSIENT_TERMINAL_EVENTS.include?(event) && @connected
          registration = register!
          return registration if registration.error?

          return success(event: event.to_sym, line: registration.line)
        end

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
        request = @active_request
        previous_game_id = @game_id
        @last_error = code.to_s.freeze
        invalidate_session!(:recovering)
        status(:fail_closed, event: code, request: request,
               game_id: previous_game_id, channel: channel)
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
        @registration_started_at = nil
        @rename_recovery_deadline = nil
        @rename_retry_at = nil
        @lifecycle = next_lifecycle
      end

      def invalidate_decision!
        @active_request = nil
        @submitted_decision_id = nil
        @submitted_action_type = nil
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
      rescue StandardError => error
        @callback_errors << error
        nil
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
