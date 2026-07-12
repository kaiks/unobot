# frozen_string_literal: true

require 'base64'
require 'digest'
require 'json'
require 'zlib'

require_relative '../canonical'

module UnobotV2
  module Machine
    module Protocol
      NAME = 'UNO_MACHINE_V1'
      VERSION = 1
      MAX_WIRE_BYTES = 400
      CHUNK_BYTES = 128
      MAX_CHUNKS = 999
      MAX_ACTION_DATA_BYTES = 220
      MAX_DECOMPRESSED_BYTES = 512 * 1_024
      TOKEN = /\A[A-Za-z0-9_-]{1,64}\z/
      EVENT_NAMES = %w[
        game_ended stopped unregistered nick_changed parted quit kicked
        disconnected plugin_unloaded
      ].freeze

      Error = Struct.new(:code, :message, :correlation, keyword_init: true) do
        def initialize(code:, message: code.to_s, correlation: nil)
          super
          freeze
        end
      end
      class InflateLimitError < StandardError; end

      Result = Struct.new(:value, :error, keyword_init: true) do
        def success? = error.nil?
        def failure? = !success?
      end

      Message = Struct.new(
        :kind, :game_id, :decision_id, :channel, :event, :part, :total,
        :data, :code, :retryable, :action, keyword_init: true
      ) do
        def initialize(**values)
          super
          freeze
        end

        def chunk? = %i[state event].include?(kind)
        def correlation = [kind, game_id, decision_id, event].freeze
      end

      module_function

      def parse(line)
        text = line.to_s
        return failure(:wire_too_large) if text.bytesize > MAX_WIRE_BYTES
        return failure(:unsupported_protocol) unless text.start_with?("#{NAME} ")

        case text
        when /\A#{NAME} REGISTERED game=([^ ]+) channel=([^ ]+)\z/
          parse_registered(Regexp.last_match(1), Regexp.last_match(2))
        when /\A#{NAME} ACK game=([^ ]+) decision=([^ ]+) status=ok action=([^ ]+)\z/
          parse_ack(*Regexp.last_match.captures)
        when /\A#{NAME} ERROR game=([^ ]+) decision=([^ ]+) code=([^ ]+) retry=([01])\z/
          parse_error(*Regexp.last_match.captures)
        when /\A#{NAME} (STATE|EVENT) game=([^ ]+) decision=([^ ]+) (?:event=([^ ]+) )?part=(\d+)\/(\d+) data=([^ ]+)\z/
          parse_chunk(*Regexp.last_match.captures)
        else
          failure(:malformed_frame)
        end
      rescue StandardError => error
        failure(:parser_error, error.message)
      end

      def encode_action(game_id:, decision_id:, action:)
        return failure(:invalid_game_id) unless token?(game_id, allow_dash: false)
        return failure(:invalid_decision_id) unless token?(decision_id, allow_dash: false)

        canonical = Canonical::Action.from(action)
        envelope = {
          protocol: NAME,
          protocol_version: VERSION,
          correlation: action_correlation(game_id, decision_id),
          action: canonical.to_h
        }
        data = encode64(JSON.generate(envelope))
        return failure(:action_too_large) if data.bytesize > MAX_ACTION_DATA_BYTES

        line = "#{NAME} ACTION game=#{game_id} decision=#{decision_id} data=#{data}"
        return failure(:wire_too_large) if line.bytesize > MAX_WIRE_BYTES

        Result.new(value: line.freeze)
      rescue Canonical::ValidationError => error
        failure(:invalid_action, error.message)
      rescue StandardError => error
        failure(:encoder_error, error.message)
      end

      def action_correlation(game_id, decision_id)
        digest = Digest::SHA256.digest("#{game_id}\0#{decision_id}").byteslice(0, 12)
        encode64(digest)
      end

      def decode_payload(encoded, max_decompressed_bytes: MAX_DECOMPRESSED_BYTES)
        compressed = decode64(encoded)
        return compressed if compressed.is_a?(Error)

        json = bounded_inflate(compressed, max_decompressed_bytes)
        parsed = JSON.parse(json)
        return Error.new(code: :malformed_json) unless parsed.is_a?(Hash)

        parsed
      rescue JSON::ParserError
        Error.new(code: :malformed_json)
      rescue InflateLimitError
        Error.new(code: :decompressed_too_large)
      rescue Zlib::Error
        Error.new(code: :corrupt_payload)
      end

      def validate_payload(payload, message)
        return Error.new(code: :unsupported_protocol) unless payload['protocol'] == NAME &&
                                                               payload['protocol_version'] == VERSION
        return Error.new(code: :correlation_mismatch) unless payload['game_id'] == message.game_id &&
                                                               (payload['decision_id'] || '-') == message.decision_id

        if message.kind == :state
          return Error.new(code: :unexpected_frame_type) unless payload['type'] == 'request_action'
          return Error.new(code: :malformed_state) unless payload['request'].is_a?(Hash)
        else
          return Error.new(code: :unexpected_frame_type) unless payload['type'] == 'event'
          return Error.new(code: :correlation_mismatch) unless payload['event'] == message.event
          return Error.new(code: :unknown_event) unless EVENT_NAMES.include?(payload['event'])
        end
        nil
      end

      def decode_channel(encoded)
        decoded = decode64(encoded)
        return decoded if decoded.is_a?(Error)
        return Error.new(code: :invalid_channel) if decoded.empty? || decoded.bytesize > 128 || !decoded.valid_encoding?

        decoded.downcase.freeze
      end

      def token?(value, allow_dash: true)
        text = value.to_s
        (allow_dash && text == '-') || TOKEN.match?(text)
      end

      def failure(code, message = code.to_s)
        Result.new(error: Error.new(code: code, message: message))
      end
      private_class_method :failure

      def parse_registered(game_id, encoded_channel)
        return failure(:invalid_game_id) unless token?(game_id, allow_dash: false)

        channel = decode_channel(encoded_channel)
        return Result.new(error: channel) if channel.is_a?(Error)

        Result.new(value: Message.new(kind: :registered, game_id: game_id, channel: channel))
      end
      private_class_method :parse_registered

      def parse_ack(game_id, decision_id, action)
        return failure(:invalid_game_id) unless token?(game_id, allow_dash: false)
        return failure(:invalid_decision_id) unless token?(decision_id, allow_dash: false)
        return failure(:invalid_action_type) unless Canonical::Action::TYPES.include?(action)

        Result.new(value: Message.new(kind: :ack, game_id: game_id, decision_id: decision_id, action: action))
      end
      private_class_method :parse_ack

      def parse_error(game_id, decision_id, code, retry_flag)
        return failure(:invalid_game_id) unless token?(game_id)
        return failure(:invalid_decision_id) unless token?(decision_id)
        return failure(:invalid_error_code) unless token?(code, allow_dash: false)

        Result.new(value: Message.new(kind: :error, game_id: game_id,
                                      decision_id: decision_id, code: code,
                                      retryable: retry_flag == '1'))
      end
      private_class_method :parse_error

      def parse_chunk(kind, game_id, decision_id, event, part, total, data)
        return failure(:invalid_game_id) unless token?(game_id, allow_dash: false)
        return failure(:invalid_decision_id) unless token?(decision_id)
        return failure(:invalid_event) if event && !token?(event, allow_dash: false)
        return failure(:malformed_chunk) if kind == 'EVENT' ? event.nil? : !event.nil?
        return failure(:invalid_base64) unless base64url?(data)
        return failure(:chunk_too_large) if data.bytesize > CHUNK_BYTES

        part_number = Integer(part, 10)
        total_parts = Integer(total, 10)
        return failure(:invalid_part) if total_parts < 1 || total_parts > MAX_CHUNKS ||
                                         part_number < 1 || part_number > total_parts

        Result.new(value: Message.new(
          kind: kind.downcase.to_sym, game_id: game_id, decision_id: decision_id,
          event: event, part: part_number, total: total_parts, data: data.freeze
        ))
      rescue ArgumentError
        failure(:invalid_part)
      end
      private_class_method :parse_chunk

      def base64url?(data)
        !data.to_s.empty? && /\A[A-Za-z0-9_-]+\z/.match?(data)
      end
      private_class_method :base64url?

      def encode64(data)
        Base64.urlsafe_encode64(data, padding: false)
      end
      private_class_method :encode64

      def decode64(data)
        return Error.new(code: :invalid_base64) unless base64url?(data)

        decoded = Base64.urlsafe_decode64(data.ljust((data.length + 3) / 4 * 4, '='))
        return Error.new(code: :invalid_base64) unless encode64(decoded) == data

        decoded
      rescue ArgumentError
        Error.new(code: :invalid_base64)
      end
      private_class_method :decode64

      # Feeding small compressed slices bounds transient expansion as well as
      # the accumulated result. Deflate's 32 KiB window keeps each expansion
      # bounded before the explicit output limit is checked.
      def bounded_inflate(compressed, limit)
        inflater = Zlib::Inflate.new
        output = +''
        compressed.bytes.each_slice(16) do |slice|
          output << inflater.inflate(slice.pack('C*'))
          raise InflateLimitError, 'decompressed payload too large' if output.bytesize > limit
        end
        output << inflater.finish
        raise InflateLimitError, 'decompressed payload too large' if output.bytesize > limit

        output
      ensure
        inflater&.close
      end
      private_class_method :bounded_inflate
    end
  end
end
