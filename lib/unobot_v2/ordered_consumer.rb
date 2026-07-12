# frozen_string_literal: true

require 'thread'

module UnobotV2
  class OrderedConsumer
    STOP = Object.new.freeze
    attr_reader :errors

    def initialize(capacity: 1_024, on_error: nil, &consumer)
      raise ArgumentError, 'consumer is required' unless consumer

      @queue = SizedQueue.new(capacity)
      @consumer = consumer
      @on_error = on_error
      @errors = Queue.new
      @mutex = Mutex.new
      @thread = nil
    end

    def start
      @mutex.synchronize do
        return self if @thread&.alive?

        @thread = Thread.new { consume }
      end
      self
    end

    # Network callbacks never run strategy/reducer work. When capacity is
    # exhausted the event is refused, allowing the caller to trigger resync.
    def push(event, nonblock: true)
      @queue.push(event, nonblock)
      true
    rescue ThreadError
      false
    end

    def stop
      thread = @mutex.synchronize do
        current = @thread
        @queue.push(STOP) if current&.alive?
        current
      end
      thread&.join
      @mutex.synchronize { @thread = nil if @thread == thread }
      self
    end

    def restart
      stop
      start
    end

    def alive?
      @mutex.synchronize { !!@thread&.alive? }
    end

    private

    def consume
      loop do
        event = @queue.pop
        break if event.equal?(STOP)

        begin
          @consumer.call(event)
        rescue StandardError => error
          @errors << error
          @on_error&.call(error, event)
        end
      end
    end
  end
end
