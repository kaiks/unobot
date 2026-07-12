# frozen_string_literal: true

require_relative '../interfaces'
require_relative 'reducer'
require_relative 'action_encoder'

module UnobotV2
  module Human
    class Adapter < MessagingAdapter
      attr_reader :reducer
      attr_writer :lifecycle_token, :token_validator

      def initialize(channel:, own_nick:, host_nicks:, transport:, on_request: nil,
                     reducer: nil, encoder: ActionEncoder.new)
        @transport = transport
        @on_request = on_request
        @reducer = reducer || Reducer.new(channel: channel, own_nick: own_nick, host_nicks: host_nicks)
        @encoder = encoder
        @last_decision_id = nil
        @active_request = nil
        @submitted_decision_id = nil
      end

      def receive(event)
        reduction = reducer.receive(event)
        return reduction unless token_valid?(@lifecycle_token)

        reduction.commands.each { |command| @transport.call(reducer.channel, command) }
        request = reduction.request
        return reduction unless request && request.decision_id != @last_decision_id
        return reduction unless token_valid?(@lifecycle_token)

        @active_request = request
        @active_lifecycle_token = @lifecycle_token
        @last_decision_id = request.decision_id
        @on_request&.call(request)
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
          @submitted_decision_id = decision_id
        end
        result
      end

      def resync!(reason = 'manual_resync')
        reducer.invalidate!(reason)
        @active_request = nil
        @active_lifecycle_token = nil
        @submitted_decision_id = nil
        reducer.resync_commands.each { |command| @transport.call(reducer.channel, command) }
      end

      private

      def token_valid?(token)
        !@token_validator || @token_validator.call(token)
      end
    end
  end
end
