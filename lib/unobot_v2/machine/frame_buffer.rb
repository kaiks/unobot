# frozen_string_literal: true

require_relative 'protocol'

module UnobotV2
  module Machine
    class FrameBuffer
      DEFAULT_TTL = 30.0
      DEFAULT_MAX_FRAMES = 64
      DEFAULT_MAX_ENCODED_BYTES = 512 * 1_024

      Frame = Struct.new(:message, :parts, :bytes, :created_at, :updated_at, keyword_init: true)
      Result = Struct.new(:status, :payload, :message, :error, :expired, :evicted, keyword_init: true) do
        def complete? = status == :complete
        def failure? = status == :error
      end

      attr_reader :frames

      def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                     ttl: DEFAULT_TTL, max_frames: DEFAULT_MAX_FRAMES,
                     max_encoded_bytes: DEFAULT_MAX_ENCODED_BYTES,
                     max_decompressed_bytes: Protocol::MAX_DECOMPRESSED_BYTES)
        @clock = clock
        @ttl = Float(ttl)
        @max_frames = Integer(max_frames)
        @max_encoded_bytes = Integer(max_encoded_bytes)
        @max_decompressed_bytes = Integer(max_decompressed_bytes)
        raise ArgumentError, 'frame limits must be positive' if [@ttl, @max_frames, @max_encoded_bytes,
                                                                 @max_decompressed_bytes].any? { |v| v <= 0 }

        @frames = {}
        @total_bytes = 0
      end

      def accept(message)
        return result(:error, error: Protocol::Error.new(code: :not_chunk)) unless message&.chunk?

        expired = expire!
        key = message.correlation
        frame = frames[key]
        if frame && frame.message.total != message.total
          delete(key)
          return result(:error, message: message, error: Protocol::Error.new(code: :mixed_chunks), expired: expired)
        end
        frame ||= create_frame(message)

        existing = frame.parts[message.part]
        if existing && existing != message.data
          delete(key)
          return result(:error, message: message, error: Protocol::Error.new(code: :conflicting_chunk), expired: expired)
        end
        return result(:duplicate, message: message, expired: expired) if existing

        frame.parts[message.part] = message.data
        frame.bytes += message.data.bytesize
        frame.updated_at = now
        @total_bytes += message.data.bytesize
        evicted = enforce_limits(except: key)
        unless frames.key?(key)
          return result(:error, message: message, error: Protocol::Error.new(code: :frame_evicted),
                         expired: expired, evicted: evicted)
        end
        return result(:pending, message: message, expired: expired, evicted: evicted) unless complete?(frame)

        encoded = (1..message.total).map { |part| frame.parts.fetch(part) }.join
        delete(key)
        payload = Protocol.decode_payload(encoded, max_decompressed_bytes: @max_decompressed_bytes)
        if payload.is_a?(Protocol::Error)
          return result(:error, message: message, error: payload, expired: expired, evicted: evicted)
        end
        validation = Protocol.validate_payload(payload, message)
        return result(:error, message: message, error: validation, expired: expired, evicted: evicted) if validation

        result(:complete, message: message, payload: deep_freeze(payload), expired: expired, evicted: evicted)
      rescue StandardError => error
        delete(message.correlation) if message
        result(:error, message: message,
               error: Protocol::Error.new(code: :reassembly_error, message: error.message))
      end

      def expire!
        cutoff = now - @ttl
        expired = frames.select { |_key, frame| frame.updated_at <= cutoff }.keys
        expired.each { |key| delete(key) }
        expired.freeze
      end

      def clear
        frames.clear
        @total_bytes = 0
      end

      private

      def create_frame(message)
        evict_oldest while frames.length >= @max_frames
        timestamp = now
        frames[message.correlation] = Frame.new(message: message, parts: {}, bytes: 0,
                                                created_at: timestamp, updated_at: timestamp)
      end

      def complete?(frame)
        frame.parts.length == frame.message.total &&
          frame.parts.keys.sort == (1..frame.message.total).to_a
      end

      def enforce_limits(except:)
        evicted = []
        while @total_bytes > @max_encoded_bytes && !frames.empty?
          key = evict_oldest(except: except)
          key ||= evict_oldest
          evicted << key if key
        end
        evicted.freeze
      end

      def evict_oldest(except: nil)
        candidate = frames.reject { |key, _frame| key == except }.min_by { |_key, frame| frame.updated_at }
        return unless candidate

        delete(candidate.first)
        candidate.first
      end

      def delete(key)
        frame = frames.delete(key)
        @total_bytes -= frame.bytes if frame
        frame
      end

      def now
        Float(@clock.call)
      end

      def result(status, **values)
        Result.new(**{ status: status, expired: [], evicted: [] }.merge(values))
      end

      def deep_freeze(value)
        case value
        when Hash
          value.each { |key, child| deep_freeze(key); deep_freeze(child) }
        when Array
          value.each { |child| deep_freeze(child) }
        else
          value.freeze
        end
        value.freeze
      end
    end
  end
end
