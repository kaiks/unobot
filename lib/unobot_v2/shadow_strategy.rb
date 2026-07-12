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

    Decision = Struct.new(:request, :primary_action, :scope, :epoch, keyword_init: true)
    Lifecycle = Struct.new(:method, :args, :keywords, :scope, :prefix, keyword_init: true)
    STOP = Object.new.freeze
    FAIL_CLOSED = Object.new.freeze

    attr_reader :primary, :shadow

    def initialize(primary:, shadow:, queue_capacity: 128, shutdown_timeout: 5.0,
                   on_observation: nil)
      raise ArgumentError, 'primary strategy must respond to decide' unless primary.respond_to?(:decide)
      raise ArgumentError, 'shadow strategy must respond to decide' unless shadow.respond_to?(:decide)

      @primary = primary
      @shadow = shadow
      @queue_capacity = Integer(queue_capacity)
      raise ArgumentError, 'queue capacity must be positive' unless @queue_capacity.positive?

      @decision_queue = Queue.new
      @control_queue = Queue.new
      @shutdown_timeout = Float(shutdown_timeout)
      raise ArgumentError, 'shutdown timeout must be positive' unless @shutdown_timeout.positive?

      @on_observation = on_observation
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @shutdown = false
      @dropped = 0
      @observed = 0
      @pending_decisions = 0
      @pending_controls = {}
      @enqueued_controls = {}
      @inflight = {}
      @scope_epochs = Hash.new(0)
      @global_epoch = 0
      @shadow_disabled = false
      @decision_worker = Thread.new { consume_decisions }
      @control_worker = Thread.new { consume_controls }
    end

    def selected_name = primary.respond_to?(:selected_name) ? primary.selected_name : nil

    def decide(request)
      action = ActionValidator.validate(primary.decide(request), request: request)
      enqueue_decision(request, action)
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
      workers = @mutex.synchronize do
        return self if @shutdown

        @shutdown = true
        @global_epoch += 1
        clear_decisions_locked
        @pending_controls.clear
        @enqueued_controls.clear
        @control_queue.clear
        [@decision_worker, @control_worker]
      end
      primary.shutdown if primary.respond_to?(:shutdown)
      shadow.shutdown if shadow.respond_to?(:shutdown)
      @decision_queue << STOP
      @control_queue << STOP
      workers.each { |worker| join_worker(worker) }
      self
    end

    def diagnostics
      counters = @mutex.synchronize do
        {
          observed: @observed, dropped: @dropped, shutdown: @shutdown,
          shadow_disabled: @shadow_disabled,
          queued_decisions: @pending_decisions,
          queued_controls: @pending_controls.length,
          decision_worker_alive: @decision_worker.alive?,
          control_worker_alive: @control_worker.alive?
        }
      end
      counters.merge(
        primary: primary.respond_to?(:diagnostics) ? primary.diagnostics : {},
        shadow: shadow.respond_to?(:diagnostics) ? shadow.diagnostics : {}
      ).freeze
    end

    private

    def enqueue_lifecycle(method, *args, **keywords)
      return unless shadow.respond_to?(method)

      scope = lifecycle_scope(method, args)
      prefix = method == :cancel_scope
      item = Lifecycle.new(
        method: method, args: args.freeze, keywords: keywords.freeze,
        scope: scope, prefix: prefix
      ).freeze
      overflow = false
      @mutex.synchronize do
        return false if @shutdown || @shadow_disabled

        invalidate_scope_locked(scope, prefix: prefix)
        key = prefix ? [:prefix, scope].freeze : (scope || :global)
        if @pending_controls.key?(key)
          @pending_controls[key] = stronger_control(@pending_controls[key], item)
        elsif @pending_controls.length >= @queue_capacity
          overflow = true
          disable_shadow_locked
        else
          @pending_controls[key] = item
          @enqueued_controls[key] = true
          @control_queue << key
        end
      end
      if overflow
        report(Observation.new(
          status: :lifecycle_error, error_code: :shadow_control_overflow,
          error_message: 'shadow lifecycle queue overflowed and was disabled'
        ))
        return false
      end
      true
    end

    def enqueue_decision(request, action)
      scope = request_scope(request)
      item = nil
      admitted = @mutex.synchronize do
        next false if @shutdown || @shadow_disabled
        if @pending_decisions >= @queue_capacity
          @dropped += 1
          next false
        end

        epoch = [@global_epoch, @scope_epochs[scope]].freeze
        item = Decision.new(request: request, primary_action: action, scope: scope, epoch: epoch).freeze
        @pending_decisions += 1
        @decision_queue << item
        true
      end
      return true if admitted

      report(observation(request, status: :dropped, error_code: :shadow_queue_full,
                                  error_message: 'shadow observation queue is full')) if request
      false
    end

    def consume_decisions
      loop do
        item = @decision_queue.pop
        break if item.equal?(STOP)

        begin
          observe(item)
        ensure
          @mutex.synchronize do
            @pending_decisions -= 1 if @pending_decisions.positive?
            @inflight.delete(item.scope) if @inflight[item.scope] == item.epoch
            @condition.broadcast
          end
        end
      rescue StandardError => error
        report(Observation.new(status: :worker_error, error_code: :shadow_worker_error,
                               error_message: error.message.to_s.byteslice(0, 256)))
      end
    end

    def consume_controls
      loop do
        key = @control_queue.pop
        break if key.equal?(STOP)
        if key.equal?(FAIL_CLOSED)
          shadow.shutdown if shadow.respond_to?(:shutdown)
          next
        end

        item = @mutex.synchronize do
          @enqueued_controls.delete(key)
          @pending_controls.delete(key)
        end
        apply_lifecycle(item) if item
      rescue StandardError => error
        report(Observation.new(status: :worker_error, error_code: :shadow_control_worker_error,
                               error_message: error.message.to_s.byteslice(0, 256)))
      end
    end

    def observe(item)
      started = monotonic_now
      current = @mutex.synchronize do
        valid = !@shutdown && !@shadow_disabled && current_epoch_locked?(item)
        @inflight[item.scope] = item.epoch if valid
        valid
      end
      unless current
        report(observation(
          item.request, status: :dropped, primary_action: item.primary_action.to_h,
          latency_ms: elapsed_ms(started), error_code: :shadow_decision_invalidated,
          error_message: 'shadow decision was invalidated by lifecycle control'
        ))
        return
      end
      shadow_action = ActionValidator.validate(shadow.decide(item.request), request: item.request)
      still_current = @mutex.synchronize { current_epoch_locked?(item) && !@shadow_disabled && !@shutdown }
      unless still_current
        report(observation(
          item.request, status: :dropped, primary_action: item.primary_action.to_h,
          latency_ms: elapsed_ms(started), error_code: :shadow_decision_invalidated,
          error_message: 'shadow decision completed after lifecycle invalidation'
        ))
        return
      end
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
      deadline = monotonic_now + @shutdown_timeout
      loop do
        shadow.public_send(item.method, *item.args, **item.keywords)
        active = @mutex.synchronize do
          found = inflight_for_control_locked?(item)
          if found
            remaining = deadline - monotonic_now
            @condition.wait(@mutex, [remaining, 0.01].min) if remaining.positive?
          end
          found
        end
        break unless active
        if monotonic_now >= deadline
          @mutex.synchronize { disable_shadow_locked }
          report(Observation.new(
            status: :lifecycle_error, error_code: :shadow_lifecycle_timeout,
            error_message: 'shadow lifecycle could not preempt an in-flight decision'
          ))
          break
        end
        Thread.pass
      end
    rescue StandardError => error
      @mutex.synchronize { disable_shadow_locked unless @shadow_disabled || @shutdown }
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

    def request_scope(request)
      metadata = request.metadata
      channel = metadata[:channel].to_s.downcase
      if metadata[:transport] == 'machine'
        "machine:#{channel}:#{metadata[:game_id]}".freeze
      else
        generation = metadata[:game_generation] || metadata[:generation]
        "human:#{channel}:#{generation}".freeze
      end
    end

    def lifecycle_scope(method, args)
      case method
      when :game_end_for, :cancel_for then request_scope(args.first)
      when :game_end, :cancel_game, :cancel_scope
        value = args.first
        value.nil? ? nil : value.to_s.freeze
      end
    end

    def current_epoch_locked?(item)
      item.epoch == [@global_epoch, @scope_epochs[item.scope]]
    end

    def invalidate_scope_locked(scope, prefix: false)
      if scope.nil? || prefix
        @global_epoch += 1
      else
        @scope_epochs[scope] += 1
      end
    end

    def inflight_for_control_locked?(item)
      return !@inflight.empty? if item.scope.nil?
      return @inflight.keys.any? { |scope| scope.start_with?(item.scope) } if item.prefix

      @inflight.key?(item.scope)
    end

    def stronger_control(existing, candidate)
      return candidate if candidate.method.to_s.start_with?('cancel')
      return existing if existing.method.to_s.start_with?('cancel')

      candidate
    end

    def disable_shadow_locked
      return if @shadow_disabled

      @shadow_disabled = true
      @global_epoch += 1
      clear_decisions_locked
      @pending_controls.clear
      @enqueued_controls.clear
      @control_queue.clear
      @control_queue << FAIL_CLOSED
    end

    def clear_decisions_locked
      @decision_queue.clear
      @pending_decisions = @inflight.length
    end

    def join_worker(worker)
      worker.join(@shutdown_timeout)
      if worker.alive?
        worker.kill
        worker.join
      end
      raise RuntimeError, 'shadow worker did not terminate' if worker.alive?
    end
  end
end
