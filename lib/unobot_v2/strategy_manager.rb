# frozen_string_literal: true

require 'thread'

require_relative 'action_validator'
require_relative 'configuration'
require_relative 'interfaces'
require_relative 'strategy_factory'

module UnobotV2
  # Owns strategy selection and game-scoped process lifecycle. Messaging mode
  # is deliberately absent from selection: it appears only in the game key.
  class StrategyManager < Strategy
    Result = Struct.new(:code, :message, :strategy, :game_key, keyword_init: true) do
      def success? = code == :ok
      def error? = !success?
    end

    attr_reader :selected_name

    def self.from_env(env: ENV, **options)
      selected = Configuration.strategy(env)
      new(selected: selected, factories: StrategyFactory.factories(env: env), **options)
    end

    def initialize(selected:, factories:, on_status: nil)
      @factories = factories.transform_keys { |key| key.to_s.downcase }.freeze
      @on_status = on_status
      @mutex = Mutex.new
      @instances = {}
      @active_game_key = nil
      @active_name = nil
      @active_strategy = nil
      @shutdown = false
      @selected_name = normalize(selected)
      validate_supported!(@selected_name)
    end

    def decide(request)
      game_key = game_key_for(request)
      strategy = activate(game_key)
      action = strategy.decide(request)
      ActionValidator.validate(action, request: request)
    rescue StandardError => error
      status(:decision_failed, error.message, game_key: game_key)
      raise
    end

    def select(name)
      requested = normalize(name)
      validate_supported!(requested)
      @mutex.synchronize do
        return Result.new(code: :shutdown, message: 'strategy manager is shut down', strategy: @selected_name) if @shutdown
        if @active_game_key
          return Result.new(
            code: :game_active,
            message: "strategy #{@active_name} is frozen until the active game ends",
            strategy: @active_name, game_key: @active_game_key
          )
        end

        @selected_name = requested
      end
      status(:selected, nil, strategy: requested)
      Result.new(code: :ok, strategy: requested)
    end

    def game_end(game_key = nil, reason: 'game_end')
      strategy, key = @mutex.synchronize do
        return Result.new(code: :no_active_game, strategy: @selected_name) unless @active_game_key
        if game_key && @active_game_key != game_key.to_s
          return Result.new(code: :stale_game, message: 'game key is no longer active',
                            strategy: @active_name, game_key: @active_game_key)
        end

        values = [@active_strategy, @active_game_key]
        clear_active_locked
        values
      end
      strategy.end_game(key, reason: reason) if strategy.respond_to?(:end_game)
      status(:game_ended, reason, game_key: key)
      Result.new(code: :ok, strategy: selected_name, game_key: key)
    end

    def cancel_game(game_key = nil, reason: 'cancelled')
      strategy, key = @mutex.synchronize do
        return Result.new(code: :no_active_game, strategy: @selected_name) unless @active_game_key
        if game_key && @active_game_key != game_key.to_s
          return Result.new(code: :stale_game, strategy: @active_name, game_key: @active_game_key)
        end

        values = [@active_strategy, @active_game_key]
        clear_active_locked
        values
      end
      if strategy.respond_to?(:cancel)
        strategy.cancel(reason: reason)
      elsif strategy.respond_to?(:end_game)
        strategy.end_game(key, reason: reason)
      end
      status(:game_cancelled, reason, game_key: key)
      Result.new(code: :ok, strategy: selected_name, game_key: key)
    end

    # Deterministic stock agents do not invent another action after the host
    # may have executed one. They invalidate the game and request authority.
    def retryable_error(request, code:)
      strategy = @mutex.synchronize { @active_strategy }
      return :reregister unless strategy&.respond_to?(:retry_capable?) && strategy.retry_capable?

      replacement = strategy.retry_action(request, code: code)
      ActionValidator.validate(replacement, request: request)
    rescue StandardError => error
      status(:retry_failed, error.message, game_key: game_key_for(request))
      :reregister
    end

    def shutdown
      instances = @mutex.synchronize do
        return self if @shutdown

        @shutdown = true
        clear_active_locked
        @instances.values.dup
      end
      instances.each { |strategy| strategy.shutdown if strategy.respond_to?(:shutdown) }
      status(:shutdown)
      self
    end

    def diagnostics
      @mutex.synchronize do
        {
          selected: @selected_name, active_strategy: @active_name,
          active_game: @active_game_key, shutdown: @shutdown,
          strategies: @instances.transform_values do |strategy|
            strategy.respond_to?(:diagnostics) ? strategy.diagnostics : { status: :available }
          end
        }.freeze
      end
    end

    def active_game_key = @mutex.synchronize { @active_game_key }
    def active? = !active_game_key.nil?

    private

    def activate(game_key)
      replaced = nil
      strategy = @mutex.synchronize do
        raise Configuration::Error, 'strategy manager is shut down' if @shutdown
        return @active_strategy if @active_game_key == game_key

        replaced = [@active_strategy, @active_game_key] if @active_game_key
        @active_name = @selected_name
        @active_strategy = instance_for_locked(@active_name)
        @active_game_key = game_key
        @active_strategy
      end
      if replaced
        old_strategy, old_key = replaced
        old_strategy.cancel(reason: 'new_game_observed') if old_strategy.respond_to?(:cancel)
        status(:game_replaced, nil, game_key: old_key)
      end
      strategy.start_game(game_key) if strategy.respond_to?(:start_game)
      status(:game_started, nil, strategy: @active_name, game_key: game_key)
      strategy
    end

    def game_key_for(request)
      metadata = request.metadata
      if metadata[:transport] == 'machine'
        game_id = metadata[:game_id].to_s
        raise Canonical::ValidationError, 'machine request lacks game_id' if game_id.empty?

        "machine:#{metadata[:channel]}:#{game_id}"
      else
        generation = metadata[:game_generation] || metadata[:generation]
        raise Canonical::ValidationError, 'human request lacks game generation' if generation.nil?

        "human:#{metadata[:channel]}:#{generation}"
      end.freeze
    end

    def instance_for_locked(name)
      @instances[name] ||= @factories.fetch(name).call
    rescue KeyError
      raise Configuration::Error, "strategy #{name.inspect} is not available"
    end

    def normalize(name)
      value = name.to_s.downcase
      return value if Configuration::STRATEGIES.include?(value)

      raise Configuration::Error,
            "invalid strategy #{name.inspect}; expected legacy, simple, or crushing"
    end

    def validate_supported!(name)
      return if @factories.key?(name)

      if name == 'legacy'
        raise Configuration::Error,
              'UNO_RUNTIME=v2 with UNO_STRATEGY=legacy is unsupported: UnoAI requires historical IRC tracker state'
      end
      raise Configuration::Error, "strategy #{name.inspect} is not configured"
    end

    def clear_active_locked
      @active_game_key = @active_name = @active_strategy = nil
    end

    def status(code, message = nil, **values)
      @on_status&.call(Result.new(code: code, message: message, **values))
    rescue StandardError
      nil
    end
  end
end
