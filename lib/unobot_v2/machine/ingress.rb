# frozen_string_literal: true

require_relative '../ordered_consumer'
require_relative 'event'
require_relative 'adapter'

module UnobotV2
  module Machine
    class Ingress
      Envelope = Struct.new(:event, :epoch, keyword_init: true) do
        def initialize(**values)
          super
          freeze
        end
      end

      attr_reader :consumer, :adapters, :errors

      def initialize(adapters:, own_nick:, host_nicks:, queue_capacity: 1_024, on_error: nil)
        @adapters = adapters.to_h { |channel, adapter| [channel.to_s.downcase, adapter] }.freeze
        @own_nick = own_nick.to_s
        @host_nicks = Array(host_nicks).map { |nick| nick.to_s.downcase }.freeze
        @game_sessions = {}
        @epoch = 0
        @overflowed = false
        @mutex = Mutex.new
        @errors = Queue.new
        @on_error = on_error
        @started = false
        configure_tokens
        @consumer = OrderedConsumer.new(capacity: queue_capacity, on_error: method(:consumer_error)) do |envelope|
          process(envelope)
        end
      end

      def start
        return self if @started

        consumer.start
        adapters.each_value(&:start)
        @started = true
        self
      end

      def stop
        return self unless @started

        consumer.stop
        adapters.each_value(&:stop!)
        @started = false
        self
      end

      def tick
        enqueue(Event.new(kind: :tick))
      end

      # IRC callbacks only allocate this envelope and perform a nonblocking
      # queue push. Parsing, strategy calls, and transport output are ordered on
      # the consumer worker.
      def enqueue(event)
        @mutex.synchronize do
          accepted = consumer.push(Envelope.new(event: event, epoch: @epoch))
          unless accepted
            @epoch += 1
            @overflowed = true
          end
          accepted
        end
      end

      def adapter_for(channel)
        adapters[channel.to_s.downcase]
      end

      private

      def process(envelope)
        handle_overflow
        return unless current_epoch?(envelope.epoch)

        event = envelope.event
        return process_lifecycle(event) unless event.kind == :notice
        return report(:unauthorized_host, event.text) unless host?(event.source)
        return report(:wrong_recipient, event.text) unless recipient?(event.recipient)

        parsed = Protocol.parse(event.text)
        return report(parsed.error.code, parsed.error.message) if parsed.failure?

        route(parsed.value)
      ensure
        handle_overflow
      end

      def route(message)
        if message.kind == :registered
          prior = @game_sessions[message.game_id]
          candidate = registration_adapter(message)
          return report(:game_collision, message.game_id) if prior && prior != candidate
        end
        adapter = case message.kind
                  when :registered then registration_adapter(message)
                  when :error then error_adapter(message)
                  else @game_sessions[message.game_id]
                  end
        return report(:unroutable_frame, message.kind.to_s) unless adapter

        adapter.lifecycle_token = @mutex.synchronize { @epoch }
        result = adapter.receive(message)
        if message.kind == :registered && result.success?
          @game_sessions[message.game_id] = adapter
        end
        cleanup_routes
        report(result.code, result.message) if result.error?
        result
      end

      def registration_adapter(message)
        adapter = adapters[message.channel]
        adapter if adapter&.registering?
      end

      def error_adapter(message)
        return @game_sessions[message.game_id] unless message.game_id == '-'

        pending = adapters.values.select(&:registering?)
        pending.one? ? pending.first : nil
      end

      def process_lifecycle(event)
        selected = event.channel ? [adapter_for(event.channel)].compact : adapters.values
        case event.kind
        when :tick
          selected.each(&:tick)
        when :disconnect
          selected.each(&:disconnect!)
          @game_sessions.clear
        when :reconnect
          selected.each(&:reconnect!)
        when :nick
          return unless event.old_nick.to_s.casecmp?(@own_nick)

          @own_nick = event.new_nick.to_s
          selected.each { |adapter| adapter.rename!(@own_nick) }
          @game_sessions.clear
        when :part, :quit, :kick
          selected.each { |adapter| adapter.resync!(event.kind.to_s) }
          cleanup_routes
        else
          report(:unknown_lifecycle, event.kind.to_s)
        end
      end

      def handle_overflow
        overflow = @mutex.synchronize do
          current = @overflowed
          @overflowed = false
          current
        end
        return unless overflow

        @game_sessions.clear
        epoch = @mutex.synchronize { @epoch }
        adapters.each_value do |adapter|
          adapter.lifecycle_token = epoch
          adapter.resync!('queue_overflow')
        end
        report(:queue_overflow, 'machine ingress queue overflowed')
      end

      def cleanup_routes
        @game_sessions.delete_if { |_game_id, adapter| adapter.game_id.nil? }
      end

      def configure_tokens
        adapters.each_value do |adapter|
          adapter.token_validator = ->(token) { current_epoch?(token) }
          adapter.lifecycle_token = @epoch
        end
      end

      def current_epoch?(epoch)
        @mutex.synchronize { @epoch == epoch }
      end

      def host?(nick)
        @host_nicks.include?(nick.to_s.downcase)
      end

      def recipient?(nick)
        nick.nil? || nick.to_s.casecmp?(@own_nick)
      end

      def report(code, message)
        error = Protocol::Error.new(code: code, message: message)
        errors << error
        @on_error&.call(error)
        error
      end

      def consumer_error(error, _envelope)
        report(:consumer_error, error.message)
      end
    end
  end
end
