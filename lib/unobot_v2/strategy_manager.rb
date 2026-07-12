# frozen_string_literal: true

require 'thread'

require_relative 'action_validator'
require_relative 'configuration'
require_relative 'interfaces'
require_relative 'strategy_factory'

module UnobotV2
  # Owns strategy selection and independent game-scoped strategy lifecycles.
  # Messaging mode changes only the canonical session key, never the strategy
  # interface. Multiple IRC channels therefore cannot cancel each other.
  class StrategyManager < Strategy
    Result = Struct.new(:code, :message, :strategy, :game_key, keyword_init: true) do
      def success? = code == :ok
      def error? = !success?
    end
    Session = Struct.new(:key, :scope, :name, :strategy, keyword_init: true)

    def self.from_env(env: ENV, **options)
      selected = Configuration.strategy(env)
      new(selected: selected, factories: StrategyFactory.factories(env: env), **options)
    end

    def initialize(selected:, factories:, on_status: nil)
      @factories = factories.transform_keys { |key| key.to_s.downcase }.freeze
      @on_status = on_status
      @mutex = Mutex.new
      @sessions = {}
      @idle = Hash.new { |hash, key| hash[key] = [] }
      @all_instances = []
      @shutdown = false
      @selected_name = normalize(selected)
      validate_supported!(@selected_name)
      # Validate the selected executable/script before IRC can connect. This
      # constructs no child process; ProcessAgent spawning remains game-lazy.
      eager = @factories.fetch(@selected_name).call
      @all_instances << eager
      @idle[@selected_name] << eager
    end

    def selected_name = @mutex.synchronize { @selected_name }

    def decide(request)
      key, scope = identity_for(request)
      session = activate(key, scope)
      action = session.strategy.decide(request)
      ActionValidator.validate(action, request: request)
    rescue StandardError => error
      status(:decision_failed, error.message, game_key: key)
      raise
    end

    def select(name)
      requested = normalize(name)
      validate_supported!(requested)
      @mutex.synchronize do
        return Result.new(code: :shutdown, message: 'strategy manager is shut down', strategy: @selected_name) if @shutdown
        unless @sessions.empty?
          return Result.new(
            code: :game_active,
            message: 'strategy selection is frozen until every active game ends',
            strategy: @selected_name, game_key: @sessions.keys.sort.join(',')
          )
        end

        if @idle[requested].empty?
          begin
            eager = @factories.fetch(requested).call
            @all_instances << eager
            @idle[requested] << eager
          rescue StandardError => error
            return Result.new(code: :configuration_error, message: error.message,
                              strategy: @selected_name)
          end
        end

        @selected_name = requested
      end
      status(:selected, nil, strategy: requested)
      Result.new(code: :ok, strategy: requested)
    end

    def game_end(game_key = nil, reason: 'game_end')
      release(game_key, reason: reason, cancel: false)
    end

    def game_end_for(request, reason: 'game_end')
      key, = identity_for(request)
      game_end(key, reason: reason)
    end

    def cancel_game(game_key = nil, reason: 'cancelled')
      release(game_key, reason: reason, cancel: true)
    end

    def cancel_for(request, reason: 'cancelled')
      key, = identity_for(request)
      cancel_game(key, reason: reason)
    end

    def cancel_scope(scope, reason: 'cancelled')
      prefix = scope.to_s
      keys = @mutex.synchronize do
        @sessions.values.select { |session| session.scope == prefix }.map(&:key)
      end
      keys.map { |key| cancel_game(key, reason: reason) }
    end

    # Deterministic stock agents never invent another action after an executor
    # error which may follow an executed command. They request authoritative
    # registration without replaying or invoking #decide again.
    def retryable_error(request, code:)
      key, = identity_for(request)
      strategy = @mutex.synchronize { @sessions[key]&.strategy }
      return :reregister unless strategy&.respond_to?(:retry_capable?) && strategy.retry_capable?

      replacement = strategy.retry_action(request, code: code)
      ActionValidator.validate(replacement, request: request)
    rescue StandardError => error
      status(:retry_failed, error.message, game_key: key)
      :reregister
    end

    def shutdown
      instances = @mutex.synchronize do
        return self if @shutdown

        @shutdown = true
        @sessions.clear
        @idle.clear
        @all_instances.dup
      end
      instances.each { |strategy| strategy.shutdown if strategy.respond_to?(:shutdown) }
      status(:shutdown)
      self
    end

    def diagnostics
      @mutex.synchronize do
        {
          selected: @selected_name, active_games: @sessions.keys.sort.freeze,
          shutdown: @shutdown,
          sessions: @sessions.transform_values do |session|
            details = session.strategy.respond_to?(:diagnostics) ? session.strategy.diagnostics : { status: :available }
            { strategy: session.name, diagnostics: details }.freeze
          end.freeze
        }.freeze
      end
    end

    def active_game_keys = @mutex.synchronize { @sessions.keys.sort.freeze }
    def active? = @mutex.synchronize { !@sessions.empty? }

    private

    def activate(key, scope)
      replaced = nil
      started = false
      session = @mutex.synchronize do
        raise Configuration::Error, 'strategy manager is shut down' if @shutdown
        existing = @sessions[key]
        next existing if existing

        # A fresh generation/game in one channel replaces only that channel.
        stale_key, stale = @sessions.find { |_candidate, value| value.scope == scope }
        if stale
          @sessions.delete(stale_key)
          replaced = stale
          cancel_strategy(stale.strategy, stale.key, 'new_game_observed')
          retire_locked(stale)
        end

        name = @selected_name
        strategy = checkout_locked(name)
        created = Session.new(key: key, scope: scope, name: name, strategy: strategy).freeze
        # Start is bounded and serialized with publication. game_end/cancel can
        # interrupt a later blocked #decide, but can never start an orphan.
        strategy.start_game(key) if strategy.respond_to?(:start_game)
        @sessions[key] = created
        started = true
        created
      end
      status(:game_replaced, nil, game_key: replaced.key) if replaced
      status(:game_started, nil, strategy: session.name, game_key: key) if started
      session
    end

    def release(game_key, reason:, cancel:)
      session = @mutex.synchronize do
        return Result.new(code: :no_active_game, strategy: @selected_name) if @sessions.empty?
        key = resolve_key_locked(game_key)
        return key if key.is_a?(Result)

        found = @sessions.delete(key)
        if cancel
          cancel_strategy(found.strategy, found.key, reason)
        elsif found.strategy.respond_to?(:end_game)
          found.strategy.end_game(found.key, reason: reason)
        end
        retire_locked(found)
        found
      end
      event = cancel ? :game_cancelled : :game_ended
      status(event, reason, game_key: session.key)
      Result.new(code: :ok, strategy: selected_name, game_key: session.key)
    end

    def resolve_key_locked(game_key)
      return game_key.to_s if game_key && @sessions.key?(game_key.to_s)
      if game_key
        return Result.new(code: :stale_game, message: 'game key is no longer active',
                          strategy: @selected_name, game_key: game_key.to_s)
      end
      return @sessions.keys.first if @sessions.one?

      Result.new(code: :ambiguous_game, message: 'game key is required with multiple active games',
                 strategy: @selected_name)
    end

    def cancel_strategy(strategy, key, reason)
      if strategy.respond_to?(:cancel)
        strategy.cancel(reason: reason)
      elsif strategy.respond_to?(:end_game)
        strategy.end_game(key, reason: reason)
      end
    end

    def checkout_locked(name)
      strategy = @idle[name].pop || @factories.fetch(name).call
      @all_instances << strategy unless @all_instances.include?(strategy)
      strategy
    rescue KeyError
      raise Configuration::Error, "strategy #{name.inspect} is not available"
    end

    def retire_locked(session)
      if session.strategy.respond_to?(:lifecycle) && session.strategy.lifecycle == :persistent
        @idle[session.name] << session.strategy
      elsif session.strategy.respond_to?(:shutdown)
        session.strategy.shutdown
      end
    end

    def identity_for(request)
      metadata = request.metadata
      channel = metadata[:channel].to_s.downcase
      raise Canonical::ValidationError, 'request lacks channel' if channel.empty?

      if metadata[:transport] == 'machine'
        game_id = metadata[:game_id].to_s
        raise Canonical::ValidationError, 'machine request lacks game_id' if game_id.empty?

        ["machine:#{channel}:#{game_id}".freeze, "machine:#{channel}".freeze]
      else
        generation = metadata[:game_generation] || metadata[:generation]
        raise Canonical::ValidationError, 'human request lacks game generation' if generation.nil?

        ["human:#{channel}:#{generation}".freeze, "human:#{channel}".freeze]
      end
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

    def status(code, message = nil, **values)
      @on_status&.call(Result.new(code: code, message: message, **values))
    rescue StandardError
      nil
    end
  end
end
