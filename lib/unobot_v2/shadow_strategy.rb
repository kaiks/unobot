# frozen_string_literal: true

require 'thread'

require_relative 'action_validator'
require_relative 'interfaces'

module UnobotV2
  # Runs an observer strategy asynchronously against the same immutable
  # request while returning only the primary strategy's action. Shadow output
  # can therefore be compared and recorded, but can never reach IRC.
  class ShadowStrategy < Strategy
    Observation = Struct.new(
      :status, :channel, :game_id, :decision_id, :primary_action,
      :shadow_action, :agreement, :error_code, :error_message,
      keyword_init: true
    ) do
      def to_h
        members.to_h { |name| [name, public_send(name)] }.compact
      end
    end

    Decision = Struct.new(:request, :primary_action, keyword_init: true)
    Lifecycle = Struct.new(:method, :args, :keywords, keyword_init: true)
    STOP = Object.new.freeze

    attr_reader :primary, :shadow

    def initialize(primary:, shadow:, queue_capacity: 128, shutdown_timeout: 5.0,
                   on_observation: nil)
      raise ArgumentError, 'primary strategy must respond to decide' unless primary.respond_to?(:decide)
      raise ArgumentError, 'shadow strategy must respond to decide' unless shadow.respond_to?(:decide)

      @primary = primary
      @shadow = shadow
      @queue = SizedQueue.new(Integer(queue_capacity))
      @shutdown_timeout = Float(shutdown_timeout)
      raise ArgumentError, 'shutdown timeout must be positive' unless @shutdown_timeout.positive?

      @on_observation = on_observation
      @mutex = Mutex.new
      @shutdown = false
      @dropped = 0
      @observed = 0
      @worker = Thread.new { consume }
    end

    def selected_name = primary.respond_to?(:selected_name) ? primary.selected_name : nil

    def decide(request)
      action = ActionValidator.validate(primary.decide(request), request: request)
      enqueue(Decision.new(request: request, primary_action: action).freeze, request: request)
      action
    end

    def select(name)
      primary.select(name)
    end

    def game_end(game_key = nil, reason: 'game_end')
      result = primary.game_end(game_key, reason: reason)
      enqueue_lifecycle(:game_end, game_key, reason: reason)
      result
    end

    def game_end_for(request, reason: 'game_end')
      result = primary.game_end_for(request, reason: reason)
      enqueue_lifecycle(:game_end_for, request, reason: reason)
      result
    end

    def cancel_game(game_key = nil, reason: 'cancelled')
      result = primary.cancel_game(game_key, reason: reason)
      enqueue_lifecycle(:cancel_game, game_key, reason: reason)
      result
    end

    def cancel_for(request, reason: 'cancelled')
      result = primary.cancel_for(request, reason: reason)
      enqueue_lifecycle(:cancel_for, request, reason: reason)
      result
    end

    def cancel_scope(scope, reason: 'cancelled')
      result = primary.cancel_scope(scope, reason: reason)
      enqueue_lifecycle(:cancel_scope, scope, reason: reason)
      result
    end

    def retryable_error(request, code:)
      primary.retryable_error(request, code: code)
    end

    def shutdown
      worker = @mutex.synchronize do
        return self if @shutdown

        @shutdown = true
        begin
          @queue.push(STOP, true)
        rescue ThreadError
          @queue.pop(true) until @queue.empty?
          @queue.push(STOP, true)
        end
        @worker
      end
      worker.join(@shutdown_timeout)
      worker.kill if worker.alive?
      primary.shutdown if primary.respond_to?(:shutdown)
      shadow.shutdown if shadow.respond_to?(:shutdown)
      self
    end

    def diagnostics
      counters = @mutex.synchronize { { observed: @observed, dropped: @dropped, shutdown: @shutdown } }
      counters.merge(
        primary: primary.respond_to?(:diagnostics) ? primary.diagnostics : {},
        shadow: shadow.respond_to?(:diagnostics) ? shadow.diagnostics : {}
      ).freeze
    end

    private

    def enqueue_lifecycle(method, *args, **keywords)
      return unless shadow.respond_to?(method)

      enqueue(Lifecycle.new(method: method, args: args.freeze, keywords: keywords.freeze).freeze)
    end

    def enqueue(item, request: nil)
      return false if @mutex.synchronize { @shutdown }

      @queue.push(item, true)
      true
    rescue ThreadError
      @mutex.synchronize { @dropped += 1 }
      report(observation(request, status: :dropped, error_code: :shadow_queue_full,
                                  error_message: 'shadow observation queue is full')) if request
      false
    end

    def consume
      loop do
        item = @queue.pop
        break if item.equal?(STOP)

        item.is_a?(Decision) ? observe(item) : apply_lifecycle(item)
      rescue StandardError => error
        report(Observation.new(status: :worker_error, error_code: :shadow_worker_error,
                               error_message: error.message.to_s.byteslice(0, 256)))
      end
    end

    def observe(item)
      shadow_action = ActionValidator.validate(shadow.decide(item.request), request: item.request)
      @mutex.synchronize { @observed += 1 }
      report(observation(
        item.request, status: :ok, primary_action: item.primary_action.to_h,
        shadow_action: shadow_action.to_h, agreement: item.primary_action == shadow_action
      ))
    rescue StandardError => error
      @mutex.synchronize { @observed += 1 }
      report(observation(
        item.request, status: :error, primary_action: item.primary_action.to_h,
        error_code: error.respond_to?(:code) ? error.code : :shadow_error,
        error_message: error.message.to_s.byteslice(0, 256)
      ))
    end

    def apply_lifecycle(item)
      shadow.public_send(item.method, *item.args, **item.keywords)
    rescue StandardError => error
      report(Observation.new(status: :lifecycle_error, error_code: :shadow_lifecycle_error,
                             error_message: error.message.to_s.byteslice(0, 256)))
    end

    def observation(request, **values)
      metadata = request&.metadata || {}
      Observation.new(
        channel: metadata[:channel], game_id: metadata[:game_id],
        decision_id: metadata[:decision_id], **values
      )
    end

    def report(result)
      @on_observation&.call(result)
    rescue StandardError
      nil
    end
  end
end
