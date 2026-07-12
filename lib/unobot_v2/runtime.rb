# frozen_string_literal: true

require_relative 'configuration'
require_relative 'messaging_factory'
require_relative 'session_manager'
require_relative 'machine/ingress'

module UnobotV2
  # Opt-in v2 runtime. IRC integrations translate callbacks into Human::Event
  # or Machine::Event and enqueue them here; all strategy work is delegated to
  # the selected ordered ingress worker.
  class Runtime
    class ControlError < StandardError
      attr_reader :code

      def initialize(code, message)
        @code = code
        super(message)
      end
    end
    Transition = Struct.new(:code, :message, :mode, keyword_init: true) do
      def success? = code == :ok
      def restart_required? = code == :restart_required
    end

    attr_reader :mode, :ingress, :last_submission, :callback_errors

    def self.from_env(strategy:, channels:, own_nick:, host_nicks:, transport:,
                      env: ENV, **options)
      new(
        messaging: Configuration.messaging(env), strategy: strategy,
        channels: channels, own_nick: own_nick, host_nicks: host_nicks,
        transport: transport,
        fallback_enabled: Configuration.fallback_enabled?(env), **options
      )
    end

    def initialize(messaging:, strategy:, channels:, own_nick:, host_nicks:, transport:,
                   queue_capacity: 1_024, fallback_enabled: false, on_error: nil,
                   on_submission: nil)
      raise ArgumentError, 'strategy must respond to decide' unless strategy.respond_to?(:decide)

      @mode = Configuration.normalize_messaging(messaging)
      @strategy = strategy
      @channels = Array(channels).map { |channel| channel.to_s.downcase }.uniq.freeze
      raise ArgumentError, 'at least one channel is required' if @channels.empty?

      @own_nick = own_nick.to_s
      @host_nicks = Array(host_nicks).freeze
      @transport = transport
      @queue_capacity = Integer(queue_capacity)
      @fallback_enabled = !!fallback_enabled
      @on_error = on_error
      @on_submission = on_submission
      @callback_errors = Queue.new
      install_ingress
    end

    def start
      ingress.start
      result = ingress.respond_to?(:last_control_result) ? ingress.last_control_result : nil
      raise ControlError.new(result.code, result.message) if result&.error?

      self
    end

    def stop
      invalidate
      @strategy.shutdown if @strategy.respond_to?(:shutdown)
      if ingress.respond_to?(:worker_thread?) && ingress.worker_thread?
        Thread.new do
          ingress.stop
        end
        return Transition.new(code: :ok, message: 'stop deferred from ingress worker', mode: mode)
      end

      ingress.stop
      result = ingress.respond_to?(:last_control_result) ? ingress.last_control_result : nil
      return Transition.new(code: result.code, message: result.message, mode: mode) if result&.error?

      Transition.new(code: :ok, mode: mode)
    end

    def enqueue(event)
      ingress.enqueue(event)
    end

    # Integrations should call this from their existing periodic timer. It is
    # enqueued like any IRC event so frame expiry and recovery remain ordered.
    def tick
      return true unless mode == 'machine'

      ingress.tick
    end

    def adapter_for(channel)
      ingress.adapter_for(channel)
    end

    def resync(channel, reason: 'bridge_resync')
      normalized = channel.to_s.downcase
      if mode == 'machine'
        ingress.execute(invalidate: true) { adapter_for(normalized).register! }
      else
        ingress.execute(channel: normalized, invalidate: true) do
          adapter_for(normalized).resync!(reason)
        end
      end
    end

    def invalidate(channel: nil)
      if mode == 'machine'
        ingress.invalidate!
      elsif channel
        ingress.invalidate(channel)
      else
        @channels.each { |configured| ingress.invalidate(configured) }
      end
      true
    end

    # Live machine -> human fallback is intentionally explicit and disabled by
    # default. It unregisters and invalidates every machine session before a
    # completely fresh human reducer requests `us` + `ca`. No state is merged.
    # Human -> machine needs an explicit runtime restart/registration so no
    # active human decision can be accidentally reused.
    def transition_to(requested_mode)
      requested = Configuration.normalize_messaging(requested_mode)
      return Transition.new(code: :ok, mode: mode) if requested == mode
      if ingress.respond_to?(:worker_thread?) && ingress.worker_thread?
        return Transition.new(code: :restart_required,
                              message: 'messaging transition cannot join its ingress worker', mode: mode)
      end
      if mode == 'human'
        return Transition.new(code: :restart_required,
                              message: 'human to machine requires an explicit runtime restart', mode: mode)
      end
      unless @fallback_enabled
        return Transition.new(code: :fallback_disabled,
                              message: 'machine to human fallback is disabled', mode: mode)
      end

      if @strategy.respond_to?(:cancel_scope)
        @channels.each { |channel| @strategy.cancel_scope("machine:#{channel}", reason: 'machine_fallback') }
      end
      prepared = ingress.prepare_fallback!
      unless prepared.success?
        return Transition.new(code: prepared.code, message: prepared.message, mode: mode)
      end
      unless prepared.value
        return Transition.new(code: :transport_unavailable,
                              message: 'machine unregister could not be delivered', mode: mode)
      end

      ingress.stop(graceful: false)
      stopped = ingress.last_control_result
      unless stopped&.success?
        return Transition.new(code: stopped&.code || :control_error,
                              message: stopped&.message || 'machine ingress did not stop', mode: mode)
      end
      @mode = 'human'
      install_ingress
      ingress.start
      @channels.each do |channel|
        synchronized = ingress.execute(channel: channel, invalidate: true) do
          adapter_for(channel).resync!('machine_fallback')
        end
        unless synchronized.success?
          return Transition.new(code: synchronized.code, message: synchronized.message, mode: mode)
        end
      end
      Transition.new(code: :ok, message: 'fresh human snapshot required', mode: mode)
    end

    private

    def install_ingress
      @ingress = mode == 'human' ? build_human_ingress : build_machine_ingress
    end

    def build_human_ingress
      SessionManager.new(
        queue_capacity: @queue_capacity, on_error: @on_error,
        adapter_factory: lambda do |channel|
          adapter = nil
          callback = ->(request) { dispatch(adapter, request) }
          adapter = MessagingFactory.build(
            mode: 'human', channel: channel, own_nick: @own_nick,
            host_nicks: @host_nicks, transport: @transport,
            on_request: callback,
            on_lifecycle: ->(kind, request, reason) { strategy_lifecycle(kind, request, reason) }
          )
        end
      )
    end

    def build_machine_ingress
      adapters = @channels.to_h do |channel|
        adapter = nil
        callback = ->(request) { dispatch(adapter, request) }
        status_callback = ->(result) { machine_status(adapter, result) }
        adapter = MessagingFactory.build(
          mode: 'machine', channel: channel, own_nick: @own_nick,
          host_nicks: @host_nicks, transport: @transport,
          on_request: callback, on_status: status_callback
        )
        [channel, adapter]
      end
      Machine::Ingress.new(
        adapters: adapters, own_nick: @own_nick, host_nicks: @host_nicks,
        queue_capacity: @queue_capacity, on_error: @on_error,
        on_own_nick_change: ->(nick) { @own_nick = nick }
      )
    end

    def dispatch(adapter, request)
      action = @strategy.decide(request)
      @last_submission = adapter.submit(action, decision_id: request.decision_id)
      begin
        @on_submission&.call(@last_submission, request)
      rescue StandardError => error
        @callback_errors << error
      end
      @last_submission
    end

    def strategy_lifecycle(kind, request, reason)
      return unless request

      if kind == :end && @strategy.respond_to?(:game_end_for)
        @strategy.game_end_for(request, reason: reason)
      elsif kind == :cancel && @strategy.respond_to?(:cancel_for)
        @strategy.cancel_for(request, reason: reason)
      end
    end

    def machine_status(adapter, result)
      case result.code
      when :retryable_error
        request = adapter.active_request
        policy = if request && @strategy.respond_to?(:retryable_error)
                   @strategy.retryable_error(request, code: result.event)
                 else
                   :reregister
                 end
        if policy == :reregister
          if request && @strategy.respond_to?(:cancel_for)
            @strategy.cancel_for(request, reason: 'retryable_executor_error')
          end
          adapter.register!
        elsif request
          adapter.submit(policy, decision_id: request.decision_id)
        end
      when :terminal_event
        if result.game_id && @strategy.respond_to?(:game_end)
          @strategy.game_end(machine_game_key(result), reason: result.event.to_s)
        elsif result.request && @strategy.respond_to?(:game_end_for)
          @strategy.game_end_for(result.request, reason: result.event.to_s)
        end
      when :terminal_error, :fail_closed, :session_cancelled
        if result.game_id && @strategy.respond_to?(:cancel_game)
          @strategy.cancel_game(machine_game_key(result), reason: result.event.to_s)
        elsif result.request && @strategy.respond_to?(:cancel_for)
          @strategy.cancel_for(result.request, reason: result.event.to_s)
        end
      end
    rescue StandardError => error
      @callback_errors << error
      adapter.register! if result.code == :retryable_error
    end


    def machine_game_key(result)
      "machine:#{result.channel}:#{result.game_id}"
    end
  end
end
