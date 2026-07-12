# frozen_string_literal: true

require_relative 'test_helper'
require 'base64'
require 'json'
require 'zlib'
require_relative '../lib/unobot_v2'

class UnobotV2MachineProtocolTest < Minitest::Test
  FIXTURE_PATH = File.expand_path('fixtures/host_machine_protocol_v1/frames.json', __dir__)
  JEDNA_PATH = File.expand_path('fixtures/jedna_protocol_v1/request_action_normal.json', __dir__)

  def setup
    @fixture = JSON.parse(File.read(FIXTURE_PATH))
  end

  def test_vendored_host_frames_parse_and_reassemble_shuffled_with_duplicates
    buffer = UnobotV2::Machine::FrameBuffer.new
    lines = @fixture.fetch('state_lines')
    results = [lines[2], lines[0], lines[0], lines[1]].map do |line|
      parsed = UnobotV2::Machine::Protocol.parse(line)
      assert_predicate parsed, :success?
      buffer.accept(parsed.value)
    end

    assert_equal %i[pending pending duplicate complete], results.map(&:status)
    payload = results.last.payload
    assert_predicate payload, :frozen?
    assert_equal JSON.parse(File.read(JEDNA_PATH)), payload.fetch('request')
    assert_equal 'registration_sync', payload.fetch('reason')
  end

  def test_vendored_control_frames_and_double_wd4_action_are_exact
    registered = UnobotV2::Machine::Protocol.parse(@fixture.fetch('registered_line')).value
    assert_equal :registered, registered.kind
    assert_equal '#uno', registered.channel

    ack = UnobotV2::Machine::Protocol.parse(@fixture.fetch('ack_line')).value
    assert_equal [:ack, 'play'], [ack.kind, ack.action]

    error = UnobotV2::Machine::Protocol.parse(@fixture.fetch('error_line')).value
    assert_equal [:error, 'card_not_playable', true], [error.kind, error.code, error.retryable]

    encoded = UnobotV2::Machine::Protocol.encode_action(
      game_id: 'gameFixture1', decision_id: 'decisionFixture1',
      action: { action: 'play', card: 'wd4', wild_color: 'red', double_play: true }
    )
    assert_predicate encoded, :success?
    assert_equal @fixture.fetch('action_line'), encoded.value
    assert_operator encoded.value.bytesize, :<=, 400
  end

  def test_event_frames_validate_inner_and_outer_event
    buffer = UnobotV2::Machine::FrameBuffer.new
    result = nil
    @fixture.fetch('event_lines').reverse_each do |line|
      result = buffer.accept(UnobotV2::Machine::Protocol.parse(line).value)
    end
    assert_predicate result, :complete?
    assert_equal 'game_ended', result.payload.fetch('event')
    assert_equal({ 'winner' => 'Alice' }, result.payload.fetch('payload'))
  end

  def test_strict_outer_grammar_and_wire_limits_return_structured_errors
    cases = {
      malformed_frame: 'UNO_MACHINE_V1 ACK game=g decision=d status=bad action=draw',
      unsupported_protocol: 'UNO_MACHINE_V2 ACK game=g decision=d status=ok action=draw',
      invalid_game_id: 'UNO_MACHINE_V1 ACK game=bad! decision=d status=ok action=draw',
      invalid_action_type: 'UNO_MACHINE_V1 ACK game=g decision=d status=ok action=nope',
      chunk_too_large: "UNO_MACHINE_V1 STATE game=g decision=d part=1/1 data=#{'a' * 129}",
      wire_too_large: "UNO_MACHINE_V1 ERROR game=g decision=d code=#{'a' * 380} retry=0"
    }
    cases.each do |code, line|
      result = UnobotV2::Machine::Protocol.parse(line)
      assert_predicate result, :failure?, code
      assert_equal code, result.error.code
    end
  end

  def test_conflicting_chunks_drop_only_their_frame_and_interleaved_frame_survives
    buffer = UnobotV2::Machine::FrameBuffer.new
    first = UnobotV2::Machine::Protocol.parse(@fixture.fetch('state_lines').first).value
    conflict_line = @fixture.fetch('state_lines').first.sub(/data=./, 'data=A')
    conflict = UnobotV2::Machine::Protocol.parse(conflict_line).value

    assert_equal :pending, buffer.accept(first).status
    result = buffer.accept(conflict)
    assert_equal :conflicting_chunk, result.error.code
    assert_empty buffer.frames

    event = @fixture.fetch('event_lines').map { |line| UnobotV2::Machine::Protocol.parse(line).value }
    state = @fixture.fetch('state_lines').map { |line| UnobotV2::Machine::Protocol.parse(line).value }
    assert_equal :pending, buffer.accept(event.first).status
    state_result = state.map { |part| buffer.accept(part) }.last
    event_result = buffer.accept(event.last)
    assert_predicate state_result, :complete?
    assert_predicate event_result, :complete?
  end

  def test_mixed_totals_corrupt_data_json_and_inner_correlation_are_rejected
    line = @fixture.fetch('state_lines').first
    buffer = UnobotV2::Machine::FrameBuffer.new
    assert_equal :pending, buffer.accept(UnobotV2::Machine::Protocol.parse(line).value).status
    mixed = line.sub('part=1/3', 'part=1/4')
    assert_equal :mixed_chunks, buffer.accept(UnobotV2::Machine::Protocol.parse(mixed).value).error.code

    corrupt = Base64.urlsafe_encode64('not zlib', padding: false)
    corrupt_wire = "UNO_MACHINE_V1 STATE game=g decision=d part=1/1 data=#{corrupt}"
    corrupt_result = UnobotV2::Machine::FrameBuffer.new
                                                  .accept(UnobotV2::Machine::Protocol.parse(corrupt_wire).value)
    assert_equal :corrupt_payload, corrupt_result.error.code

    {
      malformed_json: '[]',
      correlation_mismatch: JSON.generate(
        protocol: 'UNO_MACHINE_V1', protocol_version: 1, type: 'request_action',
        game_id: 'other', decision_id: 'd', request: {}
      )
    }.each do |expected, raw|
      encoded = Base64.urlsafe_encode64(Zlib::Deflate.deflate(raw), padding: false)
      chunks = encoded.scan(/.{1,128}/)
      frame_buffer = UnobotV2::Machine::FrameBuffer.new
      result = chunks.each_with_index.map do |chunk, index|
        wire = "UNO_MACHINE_V1 STATE game=g decision=d part=#{index + 1}/#{chunks.length} data=#{chunk}"
        frame_buffer.accept(UnobotV2::Machine::Protocol.parse(wire).value)
      end.last
      assert_equal expected, result.error.code
    end
  end

  def test_timeout_frame_count_and_byte_limits_are_deterministic
    time = 0.0
    clock = -> { time }
    source = UnobotV2::Machine::Protocol.parse(@fixture.fetch('state_lines').first).value
    buffer = UnobotV2::Machine::FrameBuffer.new(clock: clock, ttl: 5, max_frames: 1,
                                                 max_encoded_bytes: 130)
    assert_equal :pending, buffer.accept(source).status
    time = 6
    assert_equal [source.correlation], buffer.expire!
    assert_empty buffer.frames

    one = source
    two_line = @fixture.fetch('state_lines').first.sub('decision=decisionFixture1', 'decision=decisionFixture2')
    two = UnobotV2::Machine::Protocol.parse(two_line).value
    buffer.accept(one)
    buffer.accept(two)
    assert_equal [two.correlation], buffer.frames.keys

    tiny = UnobotV2::Machine::FrameBuffer.new(max_encoded_bytes: 1)
    assert_equal :frame_evicted, tiny.accept(one).error.code
  end

  def test_invalid_base64_and_decompressed_size_are_bounded
    invalid = 'UNO_MACHINE_V1 STATE game=g decision=d part=1/1 data=abcde'
    result = UnobotV2::Machine::FrameBuffer.new.accept(UnobotV2::Machine::Protocol.parse(invalid).value)
    assert_equal :invalid_base64, result.error.code

    compressed = Zlib::Deflate.deflate('x' * 5_000)
    encoded = Base64.urlsafe_encode64(compressed, padding: false)
    line = "UNO_MACHINE_V1 STATE game=g decision=d part=1/1 data=#{encoded}"
    result = UnobotV2::Machine::FrameBuffer.new(max_decompressed_bytes: 100)
                                                    .accept(UnobotV2::Machine::Protocol.parse(line).value)
    assert_equal :decompressed_too_large, result.error.code
  end

  def test_action_encoder_rejects_invalid_or_oversized_values_without_raising
    invalid = UnobotV2::Machine::Protocol.encode_action(game_id: '!', decision_id: 'd', action: { action: 'draw' })
    assert_equal :invalid_game_id, invalid.error.code

    oversized = UnobotV2::Machine::Protocol.encode_action(
      game_id: 'g' * 64, decision_id: 'd' * 64,
      action: { action: 'play', card: 'wd4', wild_color: 'yellow', double_play: true }
    )
    assert_predicate oversized, :success?
    assert_operator oversized.value.bytesize, :<=, 400
  end
end
