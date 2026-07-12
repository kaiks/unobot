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
      Control = Struct.new(:operation, :completion, keyword_init: true) do
        def initialize(**values)
          super
          @mutex = Mutex.new
          @canceled = false
          @claimed = false
        end

        def claim!
          @mutex.synchronize do
            return false if @canceled

            @claimed = true
          end
          true
        end

        def cancel!
          @mutex.synchronize do
            return false if @claimed

            @canceled = true
          end
          true
        end
      end
      ControlResult = Struct.new(:code, :value, :message, keyword_init: true) do
        def success? = code == :ok
        def error? = !success?
      end

      attr_reader :consumer, :adapters, :errors, :last_control_result

      def initialize(adapters:, own_nick:, host_nicks:, queue_capacity: 1_024, on_error: nil,
                     control_timeout: 5.0, on_own_nick_change: nil)
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
        @control_timeout = Float(control_timeout)
        raise ArgumentError, 'control timeout must be positive' unless @control_timeout.positive?
        @on_own_nick_change = on_own_nick_change
        configure_tokens
        @consumer = OrderedConsumer.new(capacity: queue_capacity, on_error: method(:consumer_error)) do |envelope|
          process(envelope)
        end
      end

      def start
        return self if @started

        consumer.start
        @started = true
        @last_control_result = execute { adapters.values.map(&:start) }
        self
      end

      def stop(graceful: true)
        return self unless @started

        @last_control_result = execute(invalidate: true) do
          if graceful
            adapters.each_value { |adapter| adapter.unregister! if adapter.can_unregister? }
          end
          adapters.each_value(&:stop!)
          @game_sessions.clear
        end
        if @last_control_result.success?
          consumer.stop
          @started = false
        end
        self
      end

      def prepare_fallback!
        execute(invalidate: true) do
          results = adapters.values.map { |adapter| adapter.unregister! if adapter.can_unregister? }.compact
          failures = results.select(&:error?)
          if failures.empty?
            adapters.each_value(&:stop!)
            @game_sessions.clear
            true
          else
            false
          end
        end
      end

      def synchronize
        execute { true }
      end

      def execute(invalidate: false, &operation)
        raise ArgumentError, 'control operation is required' unless operation

        invalidate_epoch! if invalidate
        return control_call(operation) if consumer.worker_thread?

        completion = Queue.new
        control = Control.new(operation: operation, completion: completion)
        deadline = monotonic_now + @control_timeout
        until consumer.push(control)
          if monotonic_now >= deadline
            control.cancel!
            return ControlResult.new(code: :control_timeout, message: 'control queue admission timed out')
          end
          Thread.pass
        end
        remaining = deadline - monotonic_now
        result = remaining.positive? ? completion.pop(timeout: remaining) : nil
        return result if result

        control.cancel!
        ControlResult.new(code: :control_timeout, message: 'control completion timed out')
      end

      def worker_thread? = consumer.worker_thread?

      def invalidate!
        invalidate_epoch!
        true
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
        if envelope.is_a?(Control)
          if envelope.claim!
            envelope.completion << control_call(envelope.operation)
          end
          return
        end
        return unless current_epoch?(envelope.epoch)

        event = envelope.event
        return process_lifecycle(event) unless event.kind == :notice
        return report(:public_frame, event.text) if event.channel
        return report(:unauthorized_host, event.text) unless host?(event.source)
        return report(:wrong_recipient, event.text) unless recipient?(event.recipient)

        parsed = Protocol.parse(event.text)
        return report(parsed.error.code, parsed.error.message) if parsed.failure?

        route(parsed.value, source: event.source)
      ensure
        handle_overflow
      end

      def route(message, source:)
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
        if message.kind != :registered && message.game_id != '-' && !adapter.accepts_source?(source)
          return report(:host_mismatch, source.to_s)
        end

        adapter.lifecycle_token = @mutex.synchronize { @epoch }
        result = adapter.receive(message, source: source)
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
          if event.old_nick.to_s.casecmp?(@own_nick)
            @own_nick = event.new_nick.to_s
            selected.each { |adapter| adapter.rename!(@own_nick) }
            safe_callback(@on_own_nick_change, @own_nick)
            @game_sessions.clear
          else
            selected.each { |adapter| adapter.host_renamed!(event.old_nick, event.new_nick) }
            cleanup_routes
          end
        when :part, :quit, :kick
          affected = event.affected_nick || (event.kind == :kick ? event.recipient : event.source)
          return unless affected.to_s.casecmp?(@own_nick)

          selected.each(&:disconnect!)
          @game_sessions.delete_if { |_game_id, adapter| selected.include?(adapter) }
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

      def invalidate_epoch!
        epoch = @mutex.synchronize do
          @epoch += 1
          @epoch
        end
        adapters.each_value { |adapter| adapter.lifecycle_token = epoch }
        epoch
      end

      def control_call(operation)
        ControlResult.new(code: :ok, value: operation.call)
      rescue StandardError => error
        report(:control_error, error.message)
        ControlResult.new(code: :control_error, message: error.message)
      end

      def safe_callback(callback, *arguments)
        callback&.call(*arguments)
      rescue StandardError => error
        report(:lifecycle_callback_failed, error.message)
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def current_epoch?(epoch)
        @mutex.synchronize { @epoch == epoch }
      end

      def host?(nick)
        @host_nicks.include?(nick.to_s.downcase)
      end

      def recipient?(nick)
        !nick.nil? && nick.to_s.casecmp?(@own_nick)
      end

      def report(code, message)
        error = Protocol::Error.new(code: code, message: message)
        errors << error
        begin
          @on_error&.call(error)
        rescue StandardError => callback_error
          errors << Protocol::Error.new(code: :error_callback_failed, message: callback_error.message)
        end
        error
      end

      def consumer_error(error, _envelope)
        report(:consumer_error, error.message)
      end
    end
  end
end
