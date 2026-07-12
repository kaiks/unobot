# frozen_string_literal: true

require 'thread'

require_relative 'process_agent'

module UnobotV2
  # Persistent MaskablePPO process with explicit cold/warm health and bounded
  # retry backoff. The upstream protocol has no ready frame, so the first valid
  # request after a spawn is the only truthful model-load health check.
  class NeuralAgent
    DEFAULT_COLD_TIMEOUT = 15.0
    DEFAULT_WARM_TIMEOUT = 1.0
    DEFAULT_BACKOFF_INITIAL = 1.0
    DEFAULT_BACKOFF_MAX = 30.0

    attr_reader :name

    def initialize(process:, cold_timeout: DEFAULT_COLD_TIMEOUT,
                   warm_timeout: DEFAULT_WARM_TIMEOUT,
                   backoff_initial: DEFAULT_BACKOFF_INITIAL,
                   backoff_max: DEFAULT_BACKOFF_MAX,
                   clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @process = process
      @name = process.name
      @cold_timeout = positive_float(cold_timeout, 'cold timeout')
      @warm_timeout = positive_float(warm_timeout, 'warm timeout')
      @backoff_initial = positive_float(backoff_initial, 'initial backoff')
      @backoff_max = positive_float(backoff_max, 'maximum backoff')
      raise ArgumentError, 'maximum backoff must not be smaller than initial backoff' if @backoff_max < @backoff_initial

      @clock = clock
      @mutex = Mutex.new
      @health = :unverified
      @consecutive_failures = 0
      @next_retry_at = nil
      @last_failure = nil
    end

    def lifecycle = :persistent
    def retry_capable? = false

    def start_game(game_key)
      @mutex.synchronize { enforce_backoff! }
      @process.start_game(game_key)
      @mutex.synchronize { @health = :loading unless @process.running? && @health == :ready }
      self
    rescue ProcessAgent::Error => error
      record_failure(error) unless error.code == :restart_backoff
      raise
    end

    def decide(request)
      validate_request!(request)
      timeout = @mutex.synchronize do
        enforce_backoff!
        @health == :ready && @process.running? ? @warm_timeout : @cold_timeout
      end
      action = @process.decide(request, timeout: timeout)
      @mutex.synchronize do
        @health = :ready
        @consecutive_failures = 0
        @next_retry_at = nil
        @last_failure = nil
      end
      action
    rescue ProcessAgent::Error, Canonical::ValidationError => error
      unless error.respond_to?(:code) &&
             %i[restart_backoff unsupported_topology cancelled shutdown].include?(error.code)
        record_failure(error)
      end
      raise
    rescue StandardError => error
      record_failure(error)
      raise
    end

    def validate_request!(request)
      validate_topology!(request)
      true
    end

    def end_game(game_key = nil, reason: 'game_end')
      result = @process.end_game(game_key, reason: reason)
      @mutex.synchronize { @health = :unverified unless @process.running? }
      result
    end

    def cancel(reason: 'cancelled')
      @process.cancel(reason: reason)
      @mutex.synchronize { @health = :unverified }
      true
    end

    def shutdown
      @process.shutdown
      @mutex.synchronize { @health = :shutdown }
      self
    end

    def diagnostics
      neural = @mutex.synchronize do
        remaining = @next_retry_at ? [@next_retry_at - now, 0.0].max : nil
        {
          health: @health, deterministic: !@stochastic,
          consecutive_failures: @consecutive_failures,
          retry_in_seconds: remaining&.round(3), last_failure: @last_failure,
          cold_timeout: @cold_timeout, warm_timeout: @warm_timeout
        }
      end
      @process.diagnostics.merge(neural).freeze
    end

    def stochastic=(value)
      @stochastic = !!value
    end

    private

    def validate_topology!(request)
      return if request.other_players.length == 1

      raise ProcessAgent::Error.new(
        :unsupported_topology,
        'neural strategy supports exactly one opponent (one human plus this bot)'
      )
    end

    def enforce_backoff!
      return unless @next_retry_at && now < @next_retry_at

      remaining = @next_retry_at - now
      raise ProcessAgent::Error.new(
        :restart_backoff,
        format('neural strategy restart is backed off for %.3f seconds', remaining)
      )
    end

    def record_failure(error)
      @mutex.synchronize do
        @consecutive_failures += 1
        delay = [@backoff_initial * (2**(@consecutive_failures - 1)), @backoff_max].min
        @next_retry_at = now + delay
        @health = :failed
        @last_failure = {
          code: error.respond_to?(:code) ? error.code : :strategy_error,
          message: error.message.to_s.byteslice(0, 256)
        }.freeze
      end
    end

    def positive_float(value, label)
      parsed = Float(value)
      raise ArgumentError, "#{label} must be positive" unless parsed.positive?

      parsed
    end

    def now = Float(@clock.call)
  end
end
