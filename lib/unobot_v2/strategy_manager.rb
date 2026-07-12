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
    MaintenanceLease = Struct.new(:manager, :token, keyword_init: true)

    def self.from_env(env: ENV, **options)
      selected = Configuration.strategy(env)
      new(selected: selected, factories: StrategyFactory.factories(env: env),
          limits: StrategyFactory.limits, **options)
    end

    def initialize(selected:, factories:, limits: {}, on_status: nil)
      @factories = factories.transform_keys { |key| key.to_s.downcase }.freeze
      @limits = limits.transform_keys { |key| key.to_s.downcase }.transform_values { |value| Integer(value) }.freeze
      @on_status = on_status
      @mutex = Mutex.new
      @sessions = {}
      @idle = Hash.new { |hash, key| hash[key] = [] }
      @all_instances = []
      @shutdown = false
      @maintenance = nil
      @selected_name = normalize(selected)
      validate_supported!(@selected_name)
      # Validate the selected executable/script before IRC can connect. This
      # keeps stock processes game-lazy. Neural additionally performs its
      # model-load inference health check before IRC bridge attachment.
      eager = prepare_strategy(@selected_name)
      @all_instances << eager
      @idle[@selected_name] << eager
    end

    def selected_name = @mutex.synchronize { @selected_name }

    def decide(request)
      key, scope = identity_for(request)
      session = activate(key, scope, request)
      action = session.strategy.decide(request)
      ActionValidator.validate(action, request: request)
    rescue StandardError => error
      status(:decision_failed, error.message, game_key: key)
      raise
    end

    def select(name, maintenance: nil)
      requested = normalize(name)
      validate_supported!(requested)
      lease, owned = maintenance_lease(maintenance)
      return lease if lease.is_a?(Result)

      needs_prepare = @mutex.synchronize { @idle[requested].empty? }
      eager = prepare_strategy(requested) if needs_prepare
      result = @mutex.synchronize do
        if @shutdown
          eager&.shutdown if eager&.respond_to?(:shutdown)
          Result.new(code: :shutdown, message: 'strategy manager is shut down', strategy: @selected_name)
        else
          if eager
            @all_instances << eager
            @idle[requested] << eager
          end
          @selected_name = requested
          Result.new(code: :ok, strategy: requested)
        end
      end
      status(:selected, nil, strategy: requested) if result.success?
      result
    rescue StandardError => error
      eager&.shutdown if eager&.respond_to?(:shutdown)
      Result.new(code: :configuration_error, message: error.message, strategy: selected_name)
    ensure
      release_maintenance(lease) if owned && lease.is_a?(MaintenanceLease)
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
        @maintenance = nil
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
          shutdown: @shutdown, maintenance: !@maintenance.nil?,
          standby: @idle.transform_values do |strategies|
            strategies.map do |strategy|
              strategy.respond_to?(:diagnostics) ? strategy.diagnostics : { status: :available }
            end.freeze
          end.freeze,
          sessions: @sessions.transform_values do |session|
            details = session.strategy.respond_to?(:diagnostics) ? session.strategy.diagnostics : { status: :available }
            { strategy: session.name, diagnostics: details }.freeze
          end.freeze
        }.freeze
      end
    end

    def active_game_keys = @mutex.synchronize { @sessions.keys.sort.freeze }
    def active? = @mutex.synchronize { !@sessions.empty? }

    # Linearizes an idle-only operator mutation with game activation. The
    # lease is acquired under the same mutex used by #activate, but the caller
    # performs maintenance outside that mutex so lifecycle callbacks can call
    # cancel_scope/game_end without lock recursion.
    def acquire_maintenance
      @mutex.synchronize do
        return Result.new(code: :shutdown, message: 'strategy manager is shut down',
                          strategy: @selected_name) if @shutdown
        unless @sessions.empty?
          return Result.new(code: :game_active, message: 'maintenance is disabled during a game',
                            strategy: @selected_name, game_key: @sessions.keys.sort.join(','))
        end
        if @maintenance
          return Result.new(code: :maintenance_busy, message: 'strategy maintenance is already active',
                            strategy: @selected_name)
        end

        @maintenance = Object.new
        MaintenanceLease.new(manager: self, token: @maintenance).freeze
      end
    end

    def release_maintenance(lease)
      return false unless lease.is_a?(MaintenanceLease) && lease.manager.equal?(self)

      @mutex.synchronize do
        return false unless @maintenance.equal?(lease.token)

        @maintenance = nil
      end
      true
    end

    # Re-run the selected strategy's bounded startup health check without
    # allowing a game to activate midway through it. Stock strategies have no
    # active health operation; neural performs a real checkpoint inference.
    def health_check(maintenance: nil)
      lease, owned = maintenance_lease(maintenance)
      return lease if lease.is_a?(Result)

      strategy = @mutex.synchronize do
        found = @idle[@selected_name].first
        raise Configuration::Error, "no standby #{@selected_name} strategy is available" unless found

        found
      end
      if strategy.respond_to?(:health_check!)
        strategy.health_check!
      elsif strategy.respond_to?(:startup_health_check!)
        strategy.startup_health_check!
      end
      status(:health_checked, nil, strategy: selected_name)
      Result.new(code: :ok, strategy: selected_name)
    rescue StandardError => error
      status(:health_failed, error.message, strategy: selected_name)
      Result.new(code: :health_failed, message: 'strategy health check failed', strategy: selected_name)
    ensure
      release_maintenance(lease) if owned && lease.is_a?(MaintenanceLease)
    end

    private

    def maintenance_lease(provided)
      if provided
        valid = @mutex.synchronize do
          provided.is_a?(MaintenanceLease) && provided.manager.equal?(self) &&
            @maintenance.equal?(provided.token)
        end
        return [Result.new(code: :maintenance_required, message: 'maintenance lease is stale',
                           strategy: selected_name), false] unless valid

        return [provided, false]
      end

      acquired = acquire_maintenance
      [acquired, acquired.is_a?(MaintenanceLease)]
    end

    def prepare_strategy(name)
      strategy = @factories.fetch(name).call
      strategy.startup_health_check! if strategy.respond_to?(:startup_health_check!)
      strategy
    rescue StandardError => error
      strategy&.shutdown if strategy&.respond_to?(:shutdown)
      raise Configuration::Error, "#{name} startup health check failed: #{error.message}"
    end

    def activate(key, scope, request)
      replaced = nil
      started = false
      session = @mutex.synchronize do
        raise Configuration::Error, 'strategy manager is shut down' if @shutdown
        raise Configuration::Error, 'strategy manager is under operator maintenance' if @maintenance
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
        limit = @limits[name]
        active_count = @sessions.values.count { |active| active.name == name }
        if limit && active_count >= limit
          raise Configuration::Error,
                "#{name} strategy supports at most #{limit} active game#{limit == 1 ? '' : 's'}"
        end
        strategy = checkout_locked(name)
        created = Session.new(key: key, scope: scope, name: name, strategy: strategy).freeze
        # Start is bounded and serialized with publication. game_end/cancel can
        # interrupt a later blocked #decide, but can never start an orphan.
        begin
          strategy.validate_request!(request) if strategy.respond_to?(:validate_request!)
          strategy.start_game(key) if strategy.respond_to?(:start_game)
        rescue StandardError
          failed_start_locked(name, strategy)
          raise
        end
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

    def discard_locked(strategy)
      @idle.each_value { |strategies| strategies.delete(strategy) }
      @all_instances.delete(strategy)
      strategy.shutdown if strategy.respond_to?(:shutdown)
    rescue StandardError
      nil
    end

    def failed_start_locked(name, strategy)
      if strategy.respond_to?(:lifecycle) && strategy.lifecycle == :persistent
        @idle[name] << strategy unless @idle[name].include?(strategy)
      else
        discard_locked(strategy)
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
            "invalid strategy #{name.inspect}; expected legacy, simple, crushing, or neural"
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
