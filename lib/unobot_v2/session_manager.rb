# frozen_string_literal: true

require_relative 'ordered_consumer'

module UnobotV2
  class SessionManager
    Envelope = Struct.new(:event, :epoch, keyword_init: true) do
      def initialize(**)
        super
        freeze
      end
    end
    Control = Struct.new(:operation, :completion, keyword_init: true) do
      def initialize(**values)
        super
        freeze
      end
    end
    ControlResult = Struct.new(:code, :value, :message, keyword_init: true) do
      def success? = code == :ok
      def error? = !success?
    end

    attr_reader :consumer

    def initialize(adapter_factory:, queue_capacity: 1_024, on_error: nil)
      @adapter_factory = adapter_factory
      @sessions = {}
      @epochs = Hash.new(0)
      @overflowed = {}
      @mutex = Mutex.new
      @consumer = OrderedConsumer.new(capacity: queue_capacity, on_error: on_error) do |envelope|
        process(envelope)
      end
    end

    def start
      consumer.start
      self
    end

    def stop
      consumer.stop
      self
    end

    def enqueue(event)
      channel = normalize(event.channel)
      @mutex.synchronize do
        epoch = @epochs[channel]
        accepted = consumer.push(Envelope.new(event: event, epoch: epoch))
        unless accepted
          @epochs[channel] = epoch + 1
          @overflowed[channel] = @epochs[channel]
        end
        accepted
      end
    end

    def adapter_for(channel)
      normalized = channel.to_s.downcase
      adapter = @mutex.synchronize { @sessions[normalized] ||= @adapter_factory.call(normalized) }
      configure(adapter, normalized)
      adapter
    end

    def execute(channel: nil, invalidate: false, &operation)
      raise ArgumentError, 'control operation is required' unless operation

      invalidate_channel(channel) if invalidate && channel
      return control_call(operation) if consumer.worker_thread?

      completion = Queue.new
      consumer.push(Control.new(operation: operation, completion: completion), nonblock: false)
      completion.pop
    end

    def synchronize
      execute { true }
    end

    def remove(channel)
      normalized = normalize(channel)
      @mutex.synchronize do
        @epochs[normalized] += 1
        @overflowed.delete(normalized)
        @sessions.delete(normalized)
      end
    end

    private

    def process(envelope)
      handle_overflows
      if envelope.is_a?(Control)
        envelope.completion << control_call(envelope.operation)
        return
      end
      channel = normalize(envelope.event.channel)
      return unless current_epoch?(channel, envelope.epoch)

      adapter = adapter_for(channel)
      adapter.lifecycle_token = envelope.epoch if adapter.respond_to?(:lifecycle_token=)
      adapter.receive(envelope.event)
    ensure
      handle_overflows
    end

    def handle_overflows
      pending = @mutex.synchronize do
        result = @overflowed.dup
        @overflowed.clear
        result
      end
      pending.each do |channel, epoch|
        adapter = adapter_for(channel)
        adapter.lifecycle_token = epoch if adapter.respond_to?(:lifecycle_token=)
        adapter.resync!('queue_overflow')
      end
    end

    def configure(adapter, channel)
      return unless adapter.respond_to?(:token_validator=)

      adapter.token_validator = ->(token) { current_epoch?(channel, token) }
    end

    def current_epoch?(channel, epoch)
      @mutex.synchronize { @epochs[channel] == epoch }
    end

    def invalidate_channel(channel)
      normalized = normalize(channel)
      @mutex.synchronize { @epochs[normalized] += 1 }
    end

    def control_call(operation)
      ControlResult.new(code: :ok, value: operation.call)
    rescue StandardError => error
      ControlResult.new(code: :control_error, message: error.message)
    end

    def normalize(channel)
      channel.to_s.downcase
    end
  end
end
