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
      :shadow_action, :agreement, :latency_ms, :error_code, :error_message,
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
      @queue_capacity = Integer(queue_capacity)
      raise ArgumentError, 'queue capacity must be positive' unless @queue_capacity.positive?

      @queue = Queue.new
      @shutdown_timeout = Float(shutdown_timeout)
      raise ArgumentError, 'shutdown timeout must be positive' unless @shutdown_timeout.positive?

      @on_observation = on_observation
      @mutex = Mutex.new
      @shutdown = false
      @dropped = 0
      @observed = 0
      @pending_decisions = 0
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
        @queue << STOP
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

      item = Lifecycle.new(method: method, args: args.freeze, keywords: keywords.freeze).freeze
      @mutex.synchronize do
        return false if @shutdown

        @queue << item
      end
      true
    end

    def enqueue(item, request: nil)
      admitted = @mutex.synchronize do
        next false if @shutdown
        if item.is_a?(Decision) && @pending_decisions >= @queue_capacity
          @dropped += 1
          next false
        end

        @pending_decisions += 1 if item.is_a?(Decision)
        @queue << item
        true
      end
      return true if admitted

      report(observation(request, status: :dropped, error_code: :shadow_queue_full,
                                  error_message: 'shadow observation queue is full')) if request
      false
    end

    def consume
      loop do
        item = @queue.pop
        break if item.equal?(STOP)

        if item.is_a?(Decision)
          begin
            observe(item)
          ensure
            @mutex.synchronize { @pending_decisions -= 1 }
          end
        else
          apply_lifecycle(item)
        end
      rescue StandardError => error
        report(Observation.new(status: :worker_error, error_code: :shadow_worker_error,
                               error_message: error.message.to_s.byteslice(0, 256)))
      end
    end

    def observe(item)
      started = monotonic_now
      shadow_action = ActionValidator.validate(shadow.decide(item.request), request: item.request)
      @mutex.synchronize { @observed += 1 }
      report(observation(
        item.request, status: :ok, primary_action: item.primary_action.to_h,
        shadow_action: shadow_action.to_h, agreement: item.primary_action == shadow_action,
        latency_ms: elapsed_ms(started)
      ))
    rescue StandardError => error
      @mutex.synchronize { @observed += 1 }
      report(observation(
        item.request, status: :error, primary_action: item.primary_action.to_h,
        latency_ms: elapsed_ms(started),
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

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def elapsed_ms(started)
      ((monotonic_now - started) * 1_000).round(3)
    end
  end
end
