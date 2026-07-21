# frozen_string_literal: true

require 'thread'

require_relative '../interfaces'
require_relative 'reducer'
require_relative 'action_encoder'

module UnobotV2
  module Human
    class Adapter < MessagingAdapter
      attr_reader :reducer, :callback_errors, :last_error
      attr_writer :lifecycle_token, :token_validator

      def initialize(channel:, own_nick:, host_nicks:, transport:, on_request: nil,
                     on_lifecycle: nil, reducer: nil, encoder: ActionEncoder.new,
                     resync_delay: 0, sleeper: Kernel.method(:sleep))
        @transport = transport
        @on_request = on_request
        @on_lifecycle = on_lifecycle
        @reducer = reducer || Reducer.new(channel: channel, own_nick: own_nick, host_nicks: host_nicks)
        @encoder = encoder
        @resync_delay = Float(resync_delay)
        unless @resync_delay.finite? && @resync_delay >= 0 && @resync_delay <= 10
          raise ArgumentError, 'resync delay must be between 0 and 10 seconds'
        end
        @sleeper = sleeper
        @last_decision_id = nil
        @active_request = nil
        @submitted_decision_id = nil
        @callback_errors = Queue.new
        @last_error = nil
      end

      def receive(event)
        prior_phase = reducer.phase
        prior_request = @active_request
        reduction = reducer.receive(event)
        lifecycle(event, prior_phase, prior_request)
        return reduction unless token_valid?(@lifecycle_token)

        reduction.commands.each { |command| @transport.call(reducer.channel, command) }
        request = reduction.request
        if request
          request = @encoder.mask_request(request)
          if request.available_actions.empty?
            @last_error = :no_encodable_action
            safe_lifecycle(:cancel, prior_request, 'no_encodable_action') if prior_request
            resync!('no_encodable_action')
            return Reduction.new(changed: true, reason: 'no_encodable_action')
          end
          reduction = Reduction.new(
            request: request, commands: reduction.commands,
            changed: reduction.changed, reason: reduction.reason
          )
        end
        return reduction unless request && request.decision_id != @last_decision_id
        return reduction unless token_valid?(@lifecycle_token)

        @active_request = request
        @active_lifecycle_token = @lifecycle_token
        @last_decision_id = request.decision_id
        begin
          @on_request&.call(request)
        rescue StandardError => error
          @callback_errors << error
          @last_error = :strategy_error
          if token_valid?(@active_lifecycle_token)
            safe_lifecycle(:cancel, @active_request, 'strategy_error')
            resync!('strategy_error')
          else
            reducer.invalidate!('strategy_error_after_invalidation')
            @active_request = nil
            @active_lifecycle_token = nil
            @submitted_decision_id = nil
          end
          return Reduction.new(changed: true, reason: "strategy_error: #{error.message}")
        end
        reduction
      end

      def submit(action, decision_id:)
        unless @active_request && decision_id == @active_request.decision_id
          return ActionEncoder::Result.new(code: :stale_decision, message: 'decision is no longer active')
        end
        unless reducer.safe?
          return ActionEncoder::Result.new(code: :unsafe_state, message: 'state requires resynchronization')
        end
        unless token_valid?(@active_lifecycle_token)
          return ActionEncoder::Result.new(code: :invalidated_decision, message: 'session was invalidated')
        end
        if @submitted_decision_id == decision_id
          return ActionEncoder::Result.new(code: :duplicate_action, message: 'action already submitted')
        end

        result = @encoder.encode(action, request: @active_request)
        if result.success?
          unless token_valid?(@active_lifecycle_token)
            return ActionEncoder::Result.new(code: :invalidated_decision, message: 'session was invalidated')
          end
          @transport.call(reducer.channel, result.command)
          reducer.action_submitted!
          @submitted_decision_id = decision_id
        end
        result
      end

      def resync!(reason = 'manual_resync')
        reducer.invalidate!(reason)
        @active_request = nil
        @active_lifecycle_token = nil
        @submitted_decision_id = nil
        commands = reducer.resync_commands
        commands.each_with_index do |command, index|
          @transport.call(reducer.channel, command)
          @sleeper.call(@resync_delay) if @resync_delay.positive? && index < commands.length - 1
        end
      end

      private

      def lifecycle(event, prior_phase, prior_request)
        if event.kind == :disconnect
          safe_lifecycle(:cancel, prior_request, 'irc_disconnected')
        elsif prior_phase != 'waiting' && reducer.phase == 'waiting'
          safe_lifecycle(:cancel, prior_request, 'new_game_observed') if prior_request
        elsif prior_phase != 'ended' && reducer.phase == 'ended'
          safe_lifecycle(:end, prior_request, 'game_ended')
        end
      end

      def safe_lifecycle(kind, request, reason)
        @on_lifecycle&.call(kind, request, reason)
      rescue StandardError => error
        @callback_errors << error
      end

      def token_valid?(token)
        !@token_validator || @token_validator.call(token)
      end
    end
  end
end
