# frozen_string_literal: true

require 'cinch'
require 'set'

require_relative 'runtime'

module UnobotV2
  # Concrete opt-in attachment for Cinch. A synchronous handler snapshots IRC
  # callbacks in wire-dispatch order and performs only a nonblocking queue push.
  # Runtime controls, parsing, strategy calls, and transport run elsewhere.
  class CinchBridge
    Snapshot = Struct.new(:kind, :command, :source, :recipient, :channel, :text,
                          :old_nick, :new_nick, :affected_nick, keyword_init: true) do
      def initialize(**values)
        super
        freeze
      end
    end

    STOP = Object.new.freeze

    # Cinch::Handler normally creates a thread for every callback, which can
    # reorder enqueue operations. This handler executes only the bounded bridge
    # snapshot callback inline on Cinch's ordered IRC dispatch boundary.
    class OrderedHandler < Cinch::Handler
      def call(message, captures, arguments)
        block.call(message, *args, *captures, *arguments)
      rescue StandardError => error
        bot.loggers.exception(error) if bot.respond_to?(:loggers)
        nil
      end
    end

    attr_reader :runtime, :errors

    def initialize(bot:, strategy:, env: ENV, channels: nil, own_nick: nil,
                   host_nicks: nil, queue_capacity: 1_024, tick_interval: 1.0,
                   control_timeout: 5.0, runtime: nil)
      @bot = bot
      @env = env
      configured_mode = Configuration.messaging(env)
      @channels = Array(channels || bot.config.channels).map { |value| value.to_s.downcase }.uniq.freeze
      @own_nick = (own_nick || bot.nick).to_s
      @host_nicks = Array(host_nicks || bot.config.host_nicks).map(&:to_s).freeze
      fallback = Configuration.fallback_enabled?(env)
      if configured_mode == 'human' && @channels.length != 1
        raise Configuration::Error, 'human v2 messaging requires exactly one channel for private notice correlation'
      end
      if fallback && @channels.length != 1
        raise Configuration::Error, 'machine to human fallback requires exactly one channel'
      end

      @runtime = runtime || Runtime.from_env(
        strategy: strategy, channels: @channels, own_nick: @own_nick,
        host_nicks: @host_nicks, transport: method(:transport), env: env,
        queue_capacity: queue_capacity, on_error: method(:runtime_error)
      )
      if @runtime.mode != configured_mode
        raise Configuration::Error,
              "injected runtime mode #{@runtime.mode.inspect} does not match UNO_MESSAGING #{configured_mode.inspect}"
      end
      @queue = SizedQueue.new(queue_capacity)
      @errors = Queue.new
      @tick_interval = Float(tick_interval)
      raise ArgumentError, 'tick interval must be positive' unless @tick_interval.positive?

      @joined = Set.new
      @control_timeout = Float(control_timeout)
      raise ArgumentError, 'control timeout must be positive' unless @control_timeout.positive?
      @overflowed = Set.new
      @overflow_mutex = Mutex.new
      @handlers = []
      @started = false
      @attached = false
      @stopped = false
      @accepting = true
      @connected_once = false
      @worker = nil
      @timer = nil
      @mutex = Mutex.new
    end

    def mode = runtime.mode

    def attach!
      @mutex.synchronize do
        raise RuntimeError, 'Cinch bridge has been stopped' if @stopped
        return self if @attached

        @attached = true
        @accepting = true
      end
      start_worker
      %i[channel private notice connect disconnect join nick leaving].each do |event|
        register_handler(event) { |message, *arguments| dispatch_callback(event, message, *arguments) }
      end
      self
    end

    def stop
      @mutex.synchronize do
        return self if @stopped

        @accepting = false
        @stopped = true
      end
      @handlers.each(&:unregister)
      @handlers.clear
      admitted = enqueue_control(STOP)
      if admitted && @worker&.join(@control_timeout).nil?
        report(:bridge_stop_timeout, 'bridge worker did not stop before deadline')
      end
      stop_timer
      self
    end

    # Public callback methods make the adapter testable and usable with an
    # external Cinch plugin that already owns event registration.
    def on_channel(message) = enqueue(snapshot_message(:channel, message))
    def on_private(message) = enqueue(snapshot_message(:private, message))
    def on_notice(message) = enqueue(snapshot_message(:notice, message))
    def on_connect(message = nil) = enqueue(snapshot_message(:connect, message))
    def on_disconnect(_message = nil) = enqueue(Snapshot.new(kind: :disconnect))
    def on_join(message) = enqueue(snapshot_message(:join, message))
    def on_nick(message) = enqueue(snapshot_nick(message))
    def on_leaving(message, affected_user) = enqueue(snapshot_leaving(message, affected_user))
    def tick = enqueue(Snapshot.new(kind: :tick))

    private

    def start_worker
      @mutex.synchronize do
        return if @worker&.alive?

        @worker = Thread.new { consume }
      end
    end

    def consume
      loop do
        snapshot = @queue.pop
        break shutdown if snapshot.equal?(STOP)

        handle_overflow
        process(snapshot)
      rescue StandardError => error
        report(:bridge_error, error.message)
      end
    end

    def process(snapshot)
      case snapshot.kind
      when :channel then process_channel(snapshot)
      when :private then process_private(snapshot)
      when :notice then process_notice(snapshot)
      when :connect then @connected_once = true
      when :disconnect then process_disconnect
      when :join then process_join(snapshot)
      when :nick then process_nick(snapshot)
      when :leaving then process_leaving(snapshot)
      when :tick then runtime.tick if @started
      end
    end

    def process_channel(snapshot)
      return unless snapshot.command == 'PRIVMSG'
      return report(:unconfigured_channel, snapshot.channel.to_s) unless configured_channel?(snapshot.channel)
      return unless trusted_host?(snapshot.source)

      if mode == 'human'
        runtime.enqueue(Human::Event.new(
          channel: snapshot.channel, source: snapshot.source, recipient: snapshot.recipient,
          text: snapshot.text, private: false, kind: :message
        ))
      elsif snapshot.text == "#{@own_nick} joins the game"
        runtime.resync(snapshot.channel, reason: 'uno_player_joined')
      end
    end

    def process_private(snapshot)
      return unless mode == 'human' && snapshot.command == 'PRIVMSG'

      process_human_private(snapshot)
    end

    def process_notice(snapshot)
      return if snapshot.channel

      if mode == 'machine'
        runtime.enqueue(Machine::Event.new(
          source: snapshot.source, recipient: snapshot.recipient, channel: snapshot.channel,
          text: snapshot.text, kind: :notice
        ))
      else
        process_human_private(snapshot)
      end
    end

    def process_human_private(snapshot)
      return report(:unauthorized_host, snapshot.source.to_s) unless trusted_host?(snapshot.source)
      return report(:wrong_recipient, snapshot.recipient.to_s) unless own?(snapshot.recipient)
      return report(:ambiguous_private_channel, snapshot.text) unless @channels.one?

      runtime.enqueue(Human::Event.new(
        channel: @channels.first, source: snapshot.source, recipient: snapshot.recipient,
        text: snapshot.text, private: true, kind: :message
      ))
    end

    def process_disconnect
      @joined.clear
      return unless @started

      lifecycle_each(:disconnect)
    end

    def process_join(snapshot)
      return unless own?(snapshot.source)
      return report(:unconfigured_channel, snapshot.channel.to_s) unless configured_channel?(snapshot.channel)

      @joined << snapshot.channel
      return unless (@channels - @joined.to_a).empty?

      if @started
        lifecycle_each(:reconnect)
      else
        runtime.start
        @started = true
        @channels.each { |channel| runtime.resync(channel, reason: 'initial_join') } if mode == 'human'
        start_timer
      end
    end

    def process_nick(snapshot)
      was_own = own?(snapshot.old_nick)
      lifecycle_each(:nick, old_nick: snapshot.old_nick, new_nick: snapshot.new_nick)
      @own_nick = snapshot.new_nick if was_own
    end

    def process_leaving(snapshot)
      return unless own?(snapshot.affected_nick)
      if snapshot.channel && !configured_channel?(snapshot.channel)
        return report(:unconfigured_channel, snapshot.channel.to_s)
      end

      @joined.delete(snapshot.channel) if snapshot.channel
      lifecycle_each(:disconnect, channel: snapshot.channel)
    end

    def lifecycle_each(kind, channel: nil, **values)
      if mode == 'machine'
        runtime.enqueue(Machine::Event.new(kind: kind, channel: channel, **values))
      else
        targets = channel ? [channel] : @channels
        targets.each do |target|
          runtime.enqueue(Human::Event.new(channel: target, kind: kind, text: '', **values))
        end
      end
    end

    def shutdown
      runtime.stop if @started
      @started = false
    end

    def start_timer
      return if @timer&.alive?

      @timer = Thread.new do
        loop do
          sleep @tick_interval
          break unless @started

          tick
        end
      end
    end

    def stop_timer
      @started = false
      @timer&.join(@tick_interval + 0.1)
      @timer&.kill if @timer&.alive?
      @timer = nil
    end

    def enqueue(snapshot)
      return report(:bridge_stopped, 'bridge is no longer accepting callbacks') unless accepting?

      @queue.push(snapshot, true)
      true
    rescue ThreadError
      overflow!(snapshot)
      report(:bridge_queue_overflow, snapshot.respond_to?(:kind) ? snapshot.kind.to_s : 'control')
      false
    end

    def enqueue_control(control)
      deadline = monotonic_now + @control_timeout
      loop do
        begin
          @queue.push(control, true)
          return true
        rescue ThreadError
          # Retry only until the bounded operator deadline.
        end
        return report(:bridge_control_timeout, 'bridge control queue admission timed out') if monotonic_now >= deadline

        Thread.pass
      end
    end

    def dispatch_callback(event, message, *arguments)
      case event
      when :channel then on_channel(message)
      when :private then on_private(message)
      when :notice then on_notice(message)
      when :connect then on_connect(message)
      when :disconnect then on_disconnect(message)
      when :join then on_join(message)
      when :nick then on_nick(message)
      when :leaving then on_leaving(message, arguments.first)
      end
    end

    def register_handler(event, &callback)
      pattern = Cinch::Pattern.new(nil, //, nil)
      handler = OrderedHandler.new(@bot, event, pattern, {}, &callback)
      @bot.handlers.register(handler)
      @handlers << handler
    end

    def snapshot_message(kind, message)
      return Snapshot.new(kind: kind) unless message

      Snapshot.new(
        kind: kind, command: message.command.to_s.upcase,
        source: message.user&.nick, recipient: Array(message.params).first,
        channel: message.channel&.name&.downcase, text: message.message.to_s
      )
    end

    def snapshot_nick(message)
      Snapshot.new(
        kind: :nick, old_nick: message.user&.last_nick,
        new_nick: message.user&.nick
      )
    end

    def snapshot_leaving(message, affected_user)
      Snapshot.new(
        kind: :leaving, command: message.command.to_s.upcase,
        source: message.user&.nick, affected_nick: affected_user&.nick,
        channel: message.channel&.name&.downcase
      )
    end

    def transport(target, line)
      normalized = target.to_s.downcase
      if @channels.include?(normalized)
        @bot.Channel(target).send(line)
      elsif @host_nicks.any? { |nick| nick.casecmp?(target.to_s) }
        @bot.User(target).send(line)
      else
        raise ArgumentError, "unsafe IRC transport target #{target.inspect}"
      end
    end

    def trusted_host?(nick)
      @host_nicks.any? { |host| host.casecmp?(nick.to_s) }
    end

    def configured_channel?(channel)
      @channels.include?(channel.to_s.downcase)
    end

    def accepting?
      @mutex.synchronize { @accepting }
    end

    def own?(nick)
      nick.to_s.casecmp?(@own_nick)
    end

    def runtime_error(error, *_arguments)
      report(error.respond_to?(:code) ? error.code : :runtime_error, error.message)
    end

    def overflow!(snapshot)
      scope = snapshot.respond_to?(:channel) ? snapshot.channel : nil
      scope = :all if scope.nil? || scope.empty?
      @overflow_mutex.synchronize { @overflowed << scope }
      runtime.invalidate(channel: scope == :all ? nil : scope) if @started
    rescue StandardError => error
      report(:bridge_invalidation_failed, error.message)
    end

    def handle_overflow
      scopes = @overflow_mutex.synchronize do
        current = @overflowed.dup
        @overflowed.clear
        current
      end
      return if scopes.empty? || !@started

      targets = scopes.include?(:all) ? @channels : scopes.to_a
      targets.each { |channel| runtime.resync(channel, reason: 'bridge_queue_overflow') }
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def report(code, message)
      errors << Machine::Protocol::Error.new(code: code, message: message)
      false
    end
  end
end
