# frozen_string_literal: true

require 'thread'

module UnobotV2
  class OrderedConsumer
    STOP = Object.new.freeze
    attr_reader :errors

    def initialize(capacity: 1_024, on_error: nil, &consumer)
      raise ArgumentError, 'consumer is required' unless consumer

      @capacity = Integer(capacity)
      raise ArgumentError, 'capacity must be positive' unless @capacity.positive?

      @queue = SizedQueue.new(@capacity)
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

    def worker_thread?
      @mutex.synchronize { @thread == Thread.current }
    end

    def diagnostics
      @mutex.synchronize do
        {
          alive: !!@thread&.alive?, queue_depth: @queue.length,
          queue_capacity: @capacity, error_count: @errors.length
        }.freeze
      end
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
          begin
            @on_error&.call(error, event)
          rescue StandardError => callback_error
            @errors << callback_error
          end
        end
      end
    end
  end
end
