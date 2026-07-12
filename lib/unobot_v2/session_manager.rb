# frozen_string_literal: true

require_relative 'ordered_consumer'

module UnobotV2
  class SessionManager
    attr_reader :consumer

    def initialize(adapter_factory:, queue_capacity: 1_024, on_error: nil)
      @adapter_factory = adapter_factory
      @sessions = {}
      @mutex = Mutex.new
      @consumer = OrderedConsumer.new(capacity: queue_capacity, on_error: on_error) do |event|
        adapter_for(event.channel).receive(event)
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
      accepted = consumer.push(event)
      adapter_for(event.channel).resync! unless accepted
      accepted
    end

    def adapter_for(channel)
      normalized = channel.to_s.downcase
      @mutex.synchronize { @sessions[normalized] ||= @adapter_factory.call(normalized) }
    end

    def remove(channel)
      @mutex.synchronize { @sessions.delete(channel.to_s.downcase) }
    end
  end
end
