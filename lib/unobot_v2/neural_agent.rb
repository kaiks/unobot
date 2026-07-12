# frozen_string_literal: true

require 'thread'

require_relative 'process_agent'

module UnobotV2
  # Persistent MaskablePPO process with explicit cold/warm health and bounded
  # retry backoff. The upstream protocol has no ready frame, so the first valid
  # request after a spawn is the only truthful model-load health check.
  class NeuralAgent
    HEALTH_GAME_KEY = '__unobot_neural_startup_health__'
    DEFAULT_COLD_TIMEOUT = 15.0
    DEFAULT_WARM_TIMEOUT = 1.0
    DEFAULT_BACKOFF_INITIAL = 1.0
    DEFAULT_BACKOFF_MAX = 30.0

    attr_reader :name

    def initialize(process:, cold_timeout: DEFAULT_COLD_TIMEOUT,
                   warm_timeout: DEFAULT_WARM_TIMEOUT,
                   backoff_initial: DEFAULT_BACKOFF_INITIAL,
                   backoff_max: DEFAULT_BACKOFF_MAX,
                   stochastic: false,
                   clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @process = process
      @name = process.name
      @cold_timeout = positive_float(cold_timeout, 'cold timeout')
      @warm_timeout = positive_float(warm_timeout, 'warm timeout')
      @backoff_initial = positive_float(backoff_initial, 'initial backoff')
      @backoff_max = positive_float(backoff_max, 'maximum backoff')
      raise ArgumentError, 'maximum backoff must not be smaller than initial backoff' if @backoff_max < @backoff_initial
      raise ArgumentError, 'stochastic must be boolean' unless [true, false].include?(stochastic)

      @clock = clock
      @stochastic = stochastic
      @mutex = Mutex.new
      @decision_mutex = Mutex.new
      @health = :unverified
      @consecutive_failures = 0
      @next_retry_at = nil
      @current_backoff = nil
      @last_failure = nil
    end

    def lifecycle = :persistent
    def retry_capable? = false

    def start_game(game_key)
      @mutex.synchronize { enforce_backoff! }
      prior_process_generation = @process.process_generation
      @process.start_game(game_key)
      current_process_generation = @process.process_generation
      @mutex.synchronize do
        @health = :loading unless @process.running? && @health == :ready &&
                                  current_process_generation == prior_process_generation
      end
      self
    rescue ProcessAgent::Error => error
      record_failure(error) unless error.code == :restart_backoff
      raise
    end

    def decide(request)
      @decision_mutex.synchronize do
        begin
          validate_request!(request)
          timeout, expected_process_generation = @mutex.synchronize do
            enforce_backoff!
            if @health == :ready && @process.running?
              [@warm_timeout, @process.process_generation]
            else
              [@cold_timeout, nil]
            end
          end
          action = @process.decide(
            request, timeout: timeout, cold_timeout: @cold_timeout,
            expected_process_generation: expected_process_generation
          )
          @mutex.synchronize do
            @health = :ready
            @consecutive_failures = 0
            @next_retry_at = nil
            @current_backoff = nil
            @last_failure = nil
          end
          action
        rescue ProcessAgent::Error, Canonical::ValidationError => error
          code = error.code if error.respond_to?(:code)
          if %i[cancelled shutdown no_game].include?(code)
            @mutex.synchronize { @health = :unverified unless @process.running? }
          elsif !%i[restart_backoff unsupported_topology].include?(code)
            record_failure(error)
          end
          raise
        rescue StandardError => error
          record_failure(error)
          raise
        end
      end
    end

    def validate_request!(request)
      validate_topology!(request)
      true
    end

    # The upstream feed-forward policy has no ready frame and no per-game
    # memory. One reserved canonical decision is therefore the model-load
    # health check; game_end resets the protocol boundary while retaining the
    # verified warm process for the first live game.
    def startup_health_check!
      return self if @mutex.synchronize { @health == :ready } && @process.running?

      start_game(HEALTH_GAME_KEY)
      decide(startup_health_request)
      end_game(HEALTH_GAME_KEY, reason: 'startup_health_checked')
      unless @process.running? && @mutex.synchronize { @health == :ready }
        raise ProcessAgent::Error.new(
          :health_check_failed, 'neural process did not remain healthy after startup reset'
        )
      end
      self
    rescue StandardError
      @process.cancel(reason: 'startup_health_check_failed')
      raise
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

    private

    def validate_topology!(request)
      return if request.other_players.length == 1

      raise ProcessAgent::Error.new(
        :unsupported_topology,
        'neural strategy supports exactly one opponent (one human plus this bot)'
      )
    end

    def startup_health_request
      Canonical::DecisionRequest.new(
        your_id: 'unobot-neural-health', hand: ['r5'], top_card: 'b7',
        game_state: 'normal', stacked_cards: 0, already_picked: false,
        picked_card: nil,
        other_players: [{ id: 'human-health-opponent', card_count: 7 }],
        available_actions: ['draw'], playable_cards: [],
        metadata: {
          channel: '#unobot-health', transport: 'machine',
          game_id: HEALTH_GAME_KEY, decision_id: 'startup-health-decision'
        }
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
        @current_backoff = if @current_backoff
                             [@current_backoff * 2, @backoff_max].min
                           else
                             @backoff_initial
                           end
        delay = @current_backoff
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
