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
    Transition = Struct.new(:code, :message, :mode, keyword_init: true) do
      def success? = code == :ok
      def restart_required? = code == :restart_required
    end

    attr_reader :mode, :ingress, :last_submission

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
      install_ingress
    end

    def start
      ingress.start
      self
    end

    def stop
      ingress.stop
      self
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

    # Live machine -> human fallback is intentionally explicit and disabled by
    # default. It unregisters and invalidates every machine session before a
    # completely fresh human reducer requests `us` + `ca`. No state is merged.
    # Human -> machine needs an explicit runtime restart/registration so no
    # active human decision can be accidentally reused.
    def transition_to(requested_mode)
      requested = Configuration.normalize_messaging(requested_mode)
      return Transition.new(code: :ok, mode: mode) if requested == mode
      if mode == 'human'
        return Transition.new(code: :restart_required,
                              message: 'human to machine requires an explicit runtime restart', mode: mode)
      end
      unless @fallback_enabled
        return Transition.new(code: :fallback_disabled,
                              message: 'machine to human fallback is disabled', mode: mode)
      end

      failures = ingress.adapters.values.map(&:unregister!).select(&:error?)
      unless failures.empty?
        return Transition.new(code: :transport_unavailable,
                              message: 'machine unregister could not be delivered', mode: mode)
      end

      ingress.stop
      @mode = 'human'
      install_ingress
      ingress.start
      @channels.each { |channel| adapter_for(channel).resync!('machine_fallback') }
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
            on_request: callback
          )
        end
      )
    end

    def build_machine_ingress
      adapters = @channels.to_h do |channel|
        adapter = nil
        callback = ->(request) { dispatch(adapter, request) }
        adapter = MessagingFactory.build(
          mode: 'machine', channel: channel, own_nick: @own_nick,
          host_nicks: @host_nicks, transport: @transport,
          on_request: callback
        )
        [channel, adapter]
      end
      Machine::Ingress.new(
        adapters: adapters, own_nick: @own_nick, host_nicks: @host_nicks,
        queue_capacity: @queue_capacity, on_error: @on_error
      )
    end

    def dispatch(adapter, request)
      action = @strategy.decide(request)
      @last_submission = adapter.submit(action, decision_id: request.decision_id)
      @on_submission&.call(@last_submission, request)
      @last_submission
    end
  end
end
