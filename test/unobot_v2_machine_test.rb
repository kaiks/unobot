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
      invalid_part: 'UNO_MACHINE_V1 STATE game=g decision=d part=1/1000 data=a',
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
    second = buffer.accept(two)
    assert_equal [two.correlation], buffer.frames.keys
    assert_equal [one.correlation], second.evicted

    tiny = UnobotV2::Machine::FrameBuffer.new(max_encoded_bytes: 1)
    assert_equal :frame_evicted, tiny.accept(one).error.code
  end

  def test_incomplete_frames_for_multiple_games_and_decisions_are_isolated
    buffer = UnobotV2::Machine::FrameBuffer.new
    original = @fixture.fetch('state_lines').first
    lines = [
      original,
      original.sub('decision=decisionFixture1', 'decision=decisionFixture2'),
      original.sub('game=gameFixture1', 'game=gameFixture2')
    ]
    lines.each do |line|
      assert_equal :pending, buffer.accept(UnobotV2::Machine::Protocol.parse(line).value).status
    end
    assert_equal 3, buffer.frames.length
    assert_equal 3, buffer.frames.keys.uniq.length
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

class UnobotV2MachineAdapterTest < Minitest::Test
  FIXTURE_PATH = UnobotV2MachineProtocolTest::FIXTURE_PATH

  def setup
    @fixture = JSON.parse(File.read(FIXTURE_PATH))
    @sent = []
    @requests = []
    @statuses = []
    @adapter = build_adapter
  end

  def build_adapter(channel: '#uno', on_request: ->(request) { @requests << request },
                    frame_buffer: nil, **extra)
    options = {
      channel: channel, own_nick: 'Alice', host_nicks: ['Host'],
      transport: ->(target, line) { @sent << [target, line, Thread.current] },
      on_request: on_request, on_status: ->(status) { @statuses << status }
    }
    options[:frame_buffer] = frame_buffer if frame_buffer
    options.merge!(extra)
    UnobotV2::Machine::Adapter.new(**options)
  end

  def register(adapter = @adapter, line = @fixture.fetch('registered_line'))
    assert_predicate adapter.start, :success?
    assert_equal ['#uno', '.uno machine register'], @sent.last.first(2)
    result = adapter.receive(UnobotV2::Machine::Protocol.parse(line).value, source: 'Host')
    assert_predicate result, :success?
    assert_equal :registered, adapter.lifecycle
  end

  def deliver_state(adapter = @adapter, lines = @fixture.fetch('state_lines'))
    lines.map { |line| adapter.receive(UnobotV2::Machine::Protocol.parse(line).value) }.last
  end

  def test_registration_state_metadata_deduplication_and_action_ack
    register
    result = deliver_state
    assert_predicate result, :success?
    request = result.request
    assert_equal 1, @requests.length
    assert_equal 'machine', request.metadata[:transport]
    assert_equal 'gameFixture1', request.metadata[:game_id]
    assert_equal 'decisionFixture1', request.decision_id
    assert_predicate request, :frozen?

    @fixture.fetch('state_lines').each do |line|
      @adapter.receive(UnobotV2::Machine::Protocol.parse(line).value)
    end
    assert_equal 1, @requests.length, 'replayed decision must not invoke strategy twice'

    action = @adapter.submit(
      { action: 'play', card: 'wd4', wild_color: 'red' },
      decision_id: request.decision_id
    )
    assert_predicate action, :success?
    assert_includes @sent.last[1], 'UNO_MACHINE_V1 ACTION game=gameFixture1 decision=decisionFixture1'
    assert_equal :awaiting_ack, @adapter.lifecycle
    assert_equal :duplicate_action,
                 @adapter.submit({ action: 'draw' }, decision_id: request.decision_id).code

    ack = @adapter.receive(UnobotV2::Machine::Protocol.parse(@fixture.fetch('ack_line')).value)
    assert_predicate ack, :success?
    assert_equal :registered, @adapter.lifecycle
    assert_nil @adapter.active_request
    assert_equal :stale_decision,
                 @adapter.submit({ action: 'draw' }, decision_id: request.decision_id).code
  end

  def test_retryable_error_reopens_exact_decision_but_does_not_reinvoke_strategy
    register
    request = deliver_state.request
    @adapter.submit({ action: 'draw' }, decision_id: request.decision_id)
    result = @adapter.receive(UnobotV2::Machine::Protocol.parse(@fixture.fetch('error_line')).value)
    assert_predicate result, :error?
    assert_predicate result.retryable, :itself
    assert_equal :active, @adapter.lifecycle
    assert_equal 1, @requests.length

    retried = @adapter.submit({ action: 'draw' }, decision_id: request.decision_id)
    assert_predicate retried, :success?
    assert_equal 2, @sent.count { |_target, line, _thread| line.include?(' ACTION ') }
  end

  def test_nonretryable_error_and_expired_chunks_fail_closed_and_reregister_without_replay
    register
    request = deliver_state.request
    @adapter.submit({ action: 'draw' }, decision_id: request.decision_id)
    stale = 'UNO_MACHINE_V1 ERROR game=gameFixture1 decision=decisionFixture1 code=stale_decision retry=0'
    result = @adapter.receive(UnobotV2::Machine::Protocol.parse(stale).value)
    assert_predicate result, :error?
    assert_nil @adapter.game_id
    refute @sent.last[1].include?(' ACTION ')

    @requests.clear
    time = 0.0
    expiring = build_adapter(frame_buffer: UnobotV2::Machine::FrameBuffer.new(clock: -> { time }, ttl: 1))
    register(expiring)
    expiring.receive(UnobotV2::Machine::Protocol.parse(@fixture.fetch('state_lines').first).value)
    time = 2
    result = expiring.tick
    assert_nil expiring.game_id
    assert_equal '.uno machine register', @sent.last[1]
    assert_empty @requests
  end

  def test_invalid_canonical_state_fails_closed_and_requests_authoritative_registration_sync
    register
    payload = {
      protocol: 'UNO_MACHINE_V1', protocol_version: 1, type: 'request_action',
      game_id: 'gameFixture1', decision_id: 'badDecision', reason: 'turn_started',
      request: { type: 'request_action', protocol_version: 1, state: {} }
    }
    encoded = Base64.urlsafe_encode64(Zlib::Deflate.deflate(JSON.generate(payload)), padding: false)
    chunks = encoded.scan(/.{1,128}/)
    result = chunks.each_with_index.map do |chunk, index|
      line = "UNO_MACHINE_V1 STATE game=gameFixture1 decision=badDecision " \
             "part=#{index + 1}/#{chunks.length} data=#{chunk}"
      @adapter.receive(UnobotV2::Machine::Protocol.parse(line).value)
    end.last
    assert_predicate result, :error?
    assert_nil @adapter.game_id
    assert_equal '.uno machine register', @sent.last[1]
    assert_empty @requests
  end

  def test_terminal_events_clear_session_and_require_explicit_reconnect_registration
    register
    deliver_state
    result = nil
    @fixture.fetch('event_lines').each do |line|
      result = @adapter.receive(UnobotV2::Machine::Protocol.parse(line).value)
    end
    assert_equal :game_ended, result.event
    assert_nil @adapter.game_id
    assert_equal :game_ended, @adapter.lifecycle

    @adapter.disconnect!
    assert_equal :disconnected, @adapter.lifecycle
    reconnect = @adapter.reconnect!
    assert_predicate reconnect, :success?
    assert_equal :registering, @adapter.lifecycle
    assert_equal '.uno machine register', @sent.last[1]
  end

  def test_delayed_transient_terminal_after_new_registration_registers_fresh_again
    register
    assert_predicate @adapter.register!, :success?
    @adapter.receive(UnobotV2::Machine::Protocol.parse(@fixture.fetch('registered_line')).value,
                     source: 'Host')
    before = @sent.count { |_target, line, _thread| line == '.uno machine register' }
    result = deliver_event('nick_changed')
    assert_predicate result, :success?
    assert_equal :nick_changed, result.event
    assert_equal :registering, @adapter.lifecycle
    assert_nil @adapter.game_id
    assert_equal before + 1, @sent.count { |_target, line, _thread| line == '.uno machine register' }
  end

  def test_transient_terminal_does_not_register_while_locally_disconnected
    register
    messages = event_messages('disconnected')
    @adapter.disconnect!
    before = @sent.length
    result = messages.map { |message| @adapter.receive(message) }.last
    assert_equal :unknown_game, result.code
    assert_equal :disconnected, @adapter.lifecycle
    assert_equal before, @sent.length
    assert_predicate @adapter.reconnect!, :success?
    assert_equal '.uno machine register', @sent.last[1]
  end

  def test_lost_ack_times_out_into_registration_sync_without_replaying_action
    time = 0.0
    adapter = build_adapter(clock: -> { time }, ack_timeout: 1)
    register(adapter)
    request = deliver_state(adapter).request
    adapter.submit({ action: 'draw' }, decision_id: request.decision_id)
    assert_equal 1, @sent.count { |_target, line, _thread| line.include?(' ACTION ') }
    time = 2
    result = adapter.tick
    assert_equal :ack_timeout, result.code
    assert_equal :registering, adapter.lifecycle
    assert_equal '.uno machine register', @sent.last[1]
    assert_equal 1, @sent.count { |_target, line, _thread| line.include?(' ACTION ') }
  end

  def test_lost_registration_response_retries_only_after_bounded_timeout
    time = 0.0
    adapter = build_adapter(clock: -> { time }, registration_timeout: 2)
    assert_predicate adapter.start, :success?
    assert_equal 1, @sent.count { |_target, line, _thread| line == '.uno machine register' }
    time = 1.9
    assert_predicate adapter.tick, :success?
    assert_equal 1, @sent.count { |_target, line, _thread| line == '.uno machine register' }
    time = 2.1
    result = adapter.tick
    assert_equal :registration_timeout, result.code
    assert_equal :registering, adapter.lifecycle
    assert_equal 2, @sent.count { |_target, line, _thread| line == '.uno machine register' }
  end

  def test_ordinary_not_player_registration_error_remains_terminal
    time = 0.0
    adapter = build_adapter(clock: -> { time }, rename_retry_interval: 1)
    adapter.start
    error = 'UNO_MACHINE_V1 ERROR game=- decision=- code=not_player retry=0'
    result = adapter.receive(UnobotV2::Machine::Protocol.parse(error).value)
    assert_equal :not_player, result.code
    assert_equal :unregistered, adapter.lifecycle
    refute_predicate adapter, :rename_recovering?
    before = @sent.length
    time = 5
    assert_predicate adapter.tick, :success?
    assert_equal before, @sent.length
  end

  def test_immediate_post_rename_not_player_schedules_bounded_retry_then_registered_succeeds
    time = 0.0
    adapter = build_adapter(
      clock: -> { time }, rename_retry_interval: 1, rename_recovery_timeout: 5
    )
    register(adapter)
    adapter.rename!('Alice2')
    error = 'UNO_MACHINE_V1 ERROR game=- decision=- code=not_player retry=0'
    result = adapter.receive(UnobotV2::Machine::Protocol.parse(error).value)
    assert_equal :not_player, result.code
    assert_predicate result.retryable, :itself
    assert_equal :rename_recovery, adapter.lifecycle
    assert_predicate adapter, :rename_recovering?

    before = @sent.length
    time = 0.9
    assert_predicate adapter.tick, :success?
    assert_equal before, @sent.length
    time = 1.1
    retry_result = adapter.tick
    assert_equal :rename_retry, retry_result.code
    assert_equal :registering, adapter.lifecycle
    assert_equal before + 1, @sent.length
    registered = adapter.receive(
      UnobotV2::Machine::Protocol.parse(@fixture.fetch('registered_line')).value, source: 'Host'
    )
    assert_predicate registered, :success?
    assert_equal :registered, adapter.lifecycle
    refute_predicate adapter, :rename_recovering?
  end

  def test_rename_recovery_stops_at_its_deadline
    time = 0.0
    adapter = build_adapter(
      clock: -> { time }, rename_retry_interval: 1, rename_recovery_timeout: 2
    )
    register(adapter)
    adapter.rename!('Alice2')
    error = 'UNO_MACHINE_V1 ERROR game=- decision=- code=not_player retry=0'
    adapter.receive(UnobotV2::Machine::Protocol.parse(error).value)
    before = @sent.length
    time = 2.1
    result = adapter.tick
    assert_equal :rename_recovery_timeout, result.code
    assert_equal :unregistered, adapter.lifecycle
    refute_predicate adapter, :rename_recovering?
    assert_equal before, @sent.length
  end

  def test_wrong_game_stale_ack_and_unsafe_actions_are_structured_refusals
    register
    request = deliver_state.request
    wrong = @fixture.fetch('ack_line').sub('game=gameFixture1', 'game=other')
    assert_equal :unknown_game, @adapter.receive(UnobotV2::Machine::Protocol.parse(wrong).value).code
    assert_equal :stale_ack,
                 @adapter.receive(UnobotV2::Machine::Protocol.parse(@fixture.fetch('ack_line')).value).code
    assert_equal :card_not_playable,
                 @adapter.submit({ action: 'play', card: 'g3' }, decision_id: request.decision_id).code
    assert_equal :action_unavailable,
                 @adapter.submit({ action: 'pass' }, decision_id: request.decision_id).code
  end

  def test_ack_action_mismatch_and_invalid_state_metadata_fail_closed
    register
    request = deliver_state.request
    @adapter.submit({ action: 'draw' }, decision_id: request.decision_id)
    mismatch = @fixture.fetch('ack_line')
    result = @adapter.receive(UnobotV2::Machine::Protocol.parse(mismatch).value)
    assert_equal :ack_mismatch, result.code
    assert_equal :registering, @adapter.lifecycle
    assert_equal '.uno machine register', @sent.last[1]

    register(@adapter)
    payload = {
      protocol: 'UNO_MACHINE_V1', protocol_version: 1, type: 'request_action',
      game_id: 'gameFixture1', decision_id: 'decisionFixture2', reason: 'future_reason',
      request: JSON.parse(File.read(UnobotV2MachineProtocolTest::JEDNA_PATH))
    }
    result = deliver_payload(payload)
    assert_equal :invalid_reason, result.code
    assert_equal :registering, @adapter.lifecycle
  end

  def test_retryable_error_without_an_active_decision_is_rejected_and_resynchronized
    register
    error = 'UNO_MACHINE_V1 ERROR game=gameFixture1 decision=decisionFixture1 ' \
            'code=card_not_playable retry=1'
    result = @adapter.receive(UnobotV2::Machine::Protocol.parse(error).value)
    assert_equal :invalid_retry, result.code
    assert_equal :registering, @adapter.lifecycle
  end

  def test_retryable_error_requires_a_real_submission_in_awaiting_ack_lifecycle
    register
    request = deliver_state.request
    error = "UNO_MACHINE_V1 ERROR game=gameFixture1 decision=#{request.decision_id} " \
            'code=card_not_playable retry=1'
    result = @adapter.receive(UnobotV2::Machine::Protocol.parse(error).value)
    assert_equal :invalid_retry, result.code
    assert_equal :registering, @adapter.lifecycle
    assert_equal '.uno machine register', @sent.last[1]
  end

  def test_strategy_exception_is_structured_and_recovers_with_fresh_registration
    adapter = build_adapter(on_request: ->(_request) { raise 'strategy boom' })
    register(adapter)
    result = deliver_state(adapter)
    assert_equal :strategy_error, result.code
    assert_equal :registering, adapter.lifecycle
    assert_nil adapter.active_request
    assert_equal '.uno machine register', @sent.last[1]
    assert_equal 'strategy boom', adapter.callback_errors.pop.message
  end

  def deliver_payload(payload)
    encoded = Base64.urlsafe_encode64(Zlib::Deflate.deflate(JSON.generate(payload)), padding: false)
    chunks = encoded.scan(/.{1,128}/)
    chunks.each_with_index.map do |chunk, index|
      line = "UNO_MACHINE_V1 STATE game=#{payload.fetch(:game_id)} " \
             "decision=#{payload.fetch(:decision_id)} part=#{index + 1}/#{chunks.length} data=#{chunk}"
      @adapter.receive(UnobotV2::Machine::Protocol.parse(line).value)
    end.last
  end


  def deliver_event(event)
    event_messages(event).map { |message| @adapter.receive(message) }.last
  end

  def event_messages(event)
    payload = {
      protocol: 'UNO_MACHINE_V1', protocol_version: 1, type: 'event',
      event: event, game_id: @adapter.game_id, decision_id: nil, payload: {}
    }
    encoded = Base64.urlsafe_encode64(Zlib::Deflate.deflate(JSON.generate(payload)), padding: false)
    chunks = encoded.scan(/.{1,128}/)
    chunks.each_with_index.map do |chunk, index|
      line = "UNO_MACHINE_V1 EVENT game=#{@adapter.game_id} decision=- event=#{event} " \
             "part=#{index + 1}/#{chunks.length} data=#{chunk}"
      UnobotV2::Machine::Protocol.parse(line).value
    end
  end
end

class UnobotV2MachineIngressTest < Minitest::Test
  FIXTURE_PATH = UnobotV2MachineProtocolTest::FIXTURE_PATH

  def setup
    @fixture = JSON.parse(File.read(FIXTURE_PATH))
    @sent = Queue.new
    @requests = Queue.new
    @errors = Queue.new
    @producer = Thread.current
  end

  def adapter(channel, on_request: ->(request) { @requests << [request, Thread.current] },
              host_nicks: ['Host'], on_status: nil, **options)
    UnobotV2::Machine::Adapter.new(
      channel: channel, own_nick: 'Alice', host_nicks: host_nicks,
      transport: ->(target, line) { @sent << [target, line, Thread.current] },
      on_request: on_request, on_status: on_status, **options
    )
  end

  def notice(text, source: 'Host', recipient: 'Alice', **values)
    UnobotV2::Machine::Event.new(source: source, recipient: recipient, text: text, **values)
  end

  def registered_line(game:, channel:)
    encoded = Base64.urlsafe_encode64(channel, padding: false)
    "UNO_MACHINE_V1 REGISTERED game=#{game} channel=#{encoded}"
  end

  def test_ordered_private_notice_routing_and_thread_separation
    uno = adapter('#uno')
    ingress = UnobotV2::Machine::Ingress.new(
      adapters: { '#uno' => uno }, own_nick: 'Alice', host_nicks: ['Host'],
      on_error: ->(error) { @errors << error }
    ).start
    registration = @sent.pop
    assert_equal ['#uno', '.uno machine register'], registration.first(2)

    ingress.enqueue(notice(@fixture.fetch('registered_line')))
    @fixture.fetch('state_lines').each { |line| ingress.enqueue(notice(line)) }
    request, callback_thread = @requests.pop
    refute_same @producer, callback_thread
    assert_equal 'decisionFixture1', request.decision_id
    ingress.stop
  end

  def test_host_recipient_channel_and_game_isolation_with_ambiguous_registration_error
    uno = adapter('#uno')
    other = adapter('#other')
    ingress = UnobotV2::Machine::Ingress.new(
      adapters: { '#uno' => uno, '#other' => other }, own_nick: 'Alice', host_nicks: ['Host'],
      on_error: ->(error) { @errors << error }
    ).start
    2.times { @sent.pop }

    ingress.enqueue(notice(@fixture.fetch('registered_line'), source: 'Mallory'))
    ingress.enqueue(notice(@fixture.fetch('registered_line'), recipient: 'Bob'))
    ingress.enqueue(notice(@fixture.fetch('registered_line'), recipient: nil))
    ingress.enqueue(notice(@fixture.fetch('registered_line'), channel: '#uno'))
    ingress.enqueue(notice('UNO_MACHINE_V1 ERROR game=- decision=- code=no_game retry=0'))
    until @errors.size >= 5
      Thread.pass
    end
    assert_equal %i[unauthorized_host wrong_recipient wrong_recipient public_frame unroutable_frame],
                 5.times.map { @errors.pop.code }
    assert_nil uno.game_id
    assert_nil other.game_id

    ingress.enqueue(notice(@fixture.fetch('registered_line')))
    until uno.game_id
      Thread.pass
    end
    assert_equal 'gameFixture1', uno.game_id
    assert_nil other.game_id
    ingress.stop
  end

  def test_queue_overflow_invalidates_inflight_strategy_before_action_can_escape
    started = Queue.new
    release = Queue.new
    adapter_instance = nil
    strategy = lambda do |request|
      started << true
      release.pop
      result = adapter_instance.submit({ action: 'draw' }, decision_id: request.decision_id)
      @requests << result
    end
    adapter_instance = adapter('#uno', on_request: strategy)
    ingress = UnobotV2::Machine::Ingress.new(
      adapters: { '#uno' => adapter_instance }, own_nick: 'Alice', host_nicks: ['Host'],
      queue_capacity: 1, on_error: ->(error) { @errors << error }
    ).start
    @sent.pop
    ingress.enqueue(notice(@fixture.fetch('registered_line')))
    until adapter_instance.game_id
      Thread.pass
    end
    lines = @fixture.fetch('state_lines')
    lines.first(2).each_with_index do |line, index|
      assert ingress.enqueue(notice(line))
      until adapter_instance.frame_buffer.frames.values.first&.parts&.length == index + 1
        Thread.pass
      end
    end
    assert ingress.enqueue(notice(lines.last))
    started.pop
    assert ingress.enqueue(notice(@fixture.fetch('ack_line')))
    refute ingress.enqueue(notice(@fixture.fetch('ack_line')))
    release << true
    action_result = @requests.pop
    assert_equal :invalidated_decision, action_result.code
    until @errors.size.positive?
      Thread.pass
    end
    assert_equal :queue_overflow, @errors.pop.code
    sent = []
    sent << @sent.pop until @sent.empty?
    refute sent.any? { |_target, line, _thread| line.include?(' ACTION ') }
    assert sent.any? { |_target, line, _thread| line == '.uno machine register' }
    ingress.stop
  end

  def test_queue_overflow_during_reassembly_discards_every_partial_frame
    started = Queue.new
    release = Queue.new
    uno = adapter('#uno')
    uno.define_singleton_method(:receive) do |input, **options|
      if input.is_a?(UnobotV2::Machine::Protocol::Message) && input.kind == :ack
        started << true
        release.pop
      end
      super(input, **options)
    end
    ingress = UnobotV2::Machine::Ingress.new(
      adapters: { '#uno' => uno }, own_nick: 'Alice', host_nicks: ['Host'],
      queue_capacity: 1, on_error: ->(error) { @errors << error }
    ).start
    @sent.pop
    ingress.enqueue(notice(@fixture.fetch('registered_line')))
    wait_until { uno.game_id }
    first, second, third = @fixture.fetch('state_lines')
    ingress.enqueue(notice(first))
    wait_until { uno.frame_buffer.frames.values.first&.parts&.length == 1 }
    ingress.enqueue(notice(@fixture.fetch('ack_line')))
    started.pop
    assert ingress.enqueue(notice(second))
    refute ingress.enqueue(notice(third))
    release << true
    codes = []
    wait_until do
      codes << @errors.pop.code until @errors.empty?
      codes.include?(:queue_overflow)
    end
    assert_includes codes, :queue_overflow
    assert_empty uno.frame_buffer.frames
    assert_equal :registering, uno.lifecycle
    ingress.stop
  end

  def test_blocked_worker_returns_bounded_control_timeout_and_invalidates_decision_epoch
    started = Queue.new
    release = Queue.new
    result_queue = Queue.new
    uno = nil
    uno = adapter('#uno', on_request: lambda do |request|
      started << true
      release.pop
      result_queue << uno.submit({ action: 'draw' }, decision_id: request.decision_id)
    end)
    ingress = UnobotV2::Machine::Ingress.new(
      adapters: { '#uno' => uno }, own_nick: 'Alice', host_nicks: ['Host'],
      queue_capacity: 1, control_timeout: 0.02
    ).start
    @sent.pop
    ingress.enqueue(notice(@fixture.fetch('registered_line')))
    wait_until { uno.game_id }
    lines = @fixture.fetch('state_lines')
    lines.first(2).each_with_index do |line, index|
      assert ingress.enqueue(notice(line))
      wait_until { uno.frame_buffer.frames.values.first&.parts&.length == index + 1 }
    end
    assert ingress.enqueue(notice(lines.last))
    started.pop
    assert ingress.enqueue(notice(@fixture.fetch('ack_line')))
    control = ingress.execute(invalidate: true) { flunk 'timed-out control must be canceled' }
    assert_equal :control_timeout, control.code
    release << true
    assert_equal :invalidated_decision, result_queue.pop.code
    wait_until { ingress.consumer.alive? }
    ingress.synchronize
    ingress.stop
  end

  def test_disconnect_reconnect_and_nick_lifecycle_are_ordered
    uno = adapter('#uno')
    ingress = UnobotV2::Machine::Ingress.new(
      adapters: { '#uno' => uno }, own_nick: 'Alice', host_nicks: ['Host']
    ).start
    @sent.pop
    ingress.enqueue(notice('', kind: :disconnect))
    ingress.enqueue(notice('', kind: :reconnect))
    until @sent.size.positive?
      Thread.pass
    end
    assert_equal '.uno machine register', @sent.pop[1]
    ingress.enqueue(notice('', kind: :nick, old_nick: 'Alice', new_nick: 'Alice2'))
    until @sent.size.positive?
      Thread.pass
    end
    assert_equal '.uno machine register', @sent.pop[1]
    assert_equal 'Alice2', uno.own_nick
    ingress.stop
  end

  def test_unrelated_part_quit_and_kick_do_not_resync_our_session
    uno = adapter('#uno')
    ingress = UnobotV2::Machine::Ingress.new(
      adapters: { '#uno' => uno }, own_nick: 'Alice', host_nicks: ['Host']
    ).start
    @sent.pop
    ingress.enqueue(notice(@fixture.fetch('registered_line')))
    wait_until { uno.game_id }

    ingress.enqueue(notice('', kind: :part, source: 'Bob', affected_nick: 'Bob', channel: '#uno'))
    ingress.enqueue(notice('', kind: :quit, source: 'Carol', affected_nick: 'Carol'))
    ingress.enqueue(notice('', kind: :kick, source: 'Op', recipient: 'Bob', affected_nick: 'Bob', channel: '#uno'))
    ingress.synchronize
    assert_equal :registered, uno.lifecycle
    assert_equal 'gameFixture1', uno.game_id
    assert @sent.empty?, 'unrelated lifecycle must not emit registration traffic'

    ingress.enqueue(notice('', kind: :kick, source: 'Op', recipient: 'Alice', channel: '#uno'))
    ingress.synchronize
    assert_equal :disconnected, uno.lifecycle
    assert @sent.empty?, 'departure must wait for a later join/reconnect before registration'
    ingress.enqueue(notice('', kind: :reconnect, channel: '#uno'))
    ingress.synchronize
    assert_equal :registering, uno.lifecycle
    assert_equal '.uno machine register', @sent.pop[1]
    ingress.stop
  end

  def test_bound_registration_host_alias_owns_frames_actions_and_trusted_nick_change
    uno = adapter('#uno', host_nicks: %w[Host Host2 Host3])
    ingress = UnobotV2::Machine::Ingress.new(
      adapters: { '#uno' => uno }, own_nick: 'Alice', host_nicks: %w[Host Host2 Host3],
      on_error: ->(error) { @errors << error }
    ).start
    @sent.pop
    ingress.enqueue(notice(@fixture.fetch('registered_line'), source: 'Host2'))
    wait_until { uno.game_id }
    assert_equal 'Host2', uno.host_nick

    ingress.enqueue(notice(@fixture.fetch('state_lines').first, source: 'Host'))
    ingress.synchronize
    assert_equal :host_mismatch, @errors.pop.code
    assert_empty uno.frame_buffer.frames

    @fixture.fetch('state_lines').each { |line| ingress.enqueue(notice(line, source: 'Host2')) }
    request, = @requests.pop
    result = uno.submit({ action: 'draw' }, decision_id: request.decision_id)
    assert_predicate result, :success?
    assert_equal 'Host2', @sent.pop[0]

    ingress.enqueue(notice('', kind: :nick, old_nick: 'Host2', new_nick: 'Host3'))
    ingress.synchronize
    assert_equal 'Host3', uno.host_nick
    ingress.enqueue(notice(@fixture.fetch('ack_line'), source: 'Host2'))
    ingress.synchronize
    assert_equal :host_mismatch, @errors.pop.code
    ingress.stop
  end

  def test_reregistration_to_new_game_removes_old_game_route
    uno = adapter('#uno')
    ingress = UnobotV2::Machine::Ingress.new(
      adapters: { '#uno' => uno }, own_nick: 'Alice', host_nicks: ['Host'],
      on_error: ->(error) { @errors << error }
    ).start
    @sent.pop
    ingress.enqueue(notice(@fixture.fetch('registered_line')))
    wait_until { uno.game_id == 'gameFixture1' }
    ingress.execute(invalidate: true) { uno.register! }
    @sent.pop
    second = @fixture.fetch('registered_line').sub('game=gameFixture1', 'game=gameFixture2')
    ingress.enqueue(notice(second))
    wait_until { uno.game_id == 'gameFixture2' }
    ingress.synchronize
    routes = ingress.instance_variable_get(:@game_sessions)
    assert_equal ['gameFixture2'], routes.keys

    ingress.enqueue(notice(@fixture.fetch('state_lines').first))
    ingress.synchronize
    assert_equal :unroutable_frame, @errors.pop.code
    assert_empty uno.frame_buffer.frames
    ingress.stop
  end

  def test_two_channel_rename_recovery_proactively_retries_ambiguous_errors
    time = 0.0
    clock = -> { time }
    options = { clock: clock, rename_retry_interval: 1, rename_recovery_timeout: 3 }
    one = adapter('#one', **options)
    two = adapter('#two', **options)
    ingress = UnobotV2::Machine::Ingress.new(
      adapters: { '#one' => one, '#two' => two }, own_nick: 'Alice', host_nicks: ['Host'],
      on_error: ->(error) { @errors << error }
    ).start
    2.times { @sent.pop }
    ingress.enqueue(notice(registered_line(game: 'gameOne', channel: '#one')))
    ingress.enqueue(notice(registered_line(game: 'gameTwo', channel: '#two')))
    wait_until { one.registered? && two.registered? }

    ingress.enqueue(notice('', kind: :nick, old_nick: 'Alice', new_nick: 'Alice2'))
    ingress.synchronize
    assert_equal %i[registering registering], [one.lifecycle, two.lifecycle]
    2.times { @sent.pop }
    ingress.enqueue(notice('UNO_MACHINE_V1 ERROR game=- decision=- code=not_player retry=0', recipient: 'Alice2'))
    ingress.synchronize
    assert_equal :unroutable_frame, @errors.pop.code

    time = 1.1
    ingress.tick
    ingress.synchronize
    assert_equal ['.uno machine register', '.uno machine register'], 2.times.map { @sent.pop[1] }
    ingress.enqueue(notice(registered_line(game: 'gameOne', channel: '#one'), recipient: 'Alice2'))
    ingress.enqueue(notice(registered_line(game: 'gameTwo', channel: '#two'), recipient: 'Alice2'))
    wait_until { one.registered? && two.registered? }
    refute_predicate one, :rename_recovering?
    refute_predicate two, :rename_recovering?

    ingress.enqueue(notice('', kind: :nick, old_nick: 'Alice2', new_nick: 'Alice3'))
    ingress.synchronize
    2.times { @sent.pop }
    time = 4.2
    ingress.tick
    ingress.synchronize
    assert_equal %i[unregistered unregistered], [one.lifecycle, two.lifecycle]
    assert @sent.empty?, 'deadline expiry must not emit another registration attempt'
    ingress.stop
  end

  def test_error_and_status_callback_exceptions_do_not_kill_ordered_ingress
    uno = adapter('#uno', on_status: ->(_status) { raise 'status callback boom' })
    ingress = UnobotV2::Machine::Ingress.new(
      adapters: { '#uno' => uno }, own_nick: 'Alice', host_nicks: ['Host'],
      on_error: ->(_error) { raise 'error callback boom' }
    ).start
    @sent.pop
    ingress.enqueue(notice('broken'))
    ingress.enqueue(notice(@fixture.fetch('registered_line')))
    ingress.synchronize
    assert_predicate ingress.consumer, :alive?
    assert_equal 'gameFixture1', uno.game_id
    assert_equal 'status callback boom', uno.callback_errors.pop.message
    error_codes = []
    error_codes << ingress.errors.pop.code until ingress.errors.empty?
    assert_includes error_codes, :unsupported_protocol
    assert_includes error_codes, :error_callback_failed
    ingress.stop
  end


  private

  def wait_until(timeout: 1)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise 'timed out' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      Thread.pass
    end
  end
end

class UnobotV2MessagingContractTest < Minitest::Test
  FIXTURE_PATH = UnobotV2MachineProtocolTest::FIXTURE_PATH

  def setup
    @fixture = JSON.parse(File.read(FIXTURE_PATH))
  end

  def test_machine_human_and_jedna_fixture_states_are_identical
    machine_requests = []
    machine = UnobotV2::MessagingFactory.build(
      mode: 'machine', channel: '#uno', own_nick: 'Alice', host_nicks: ['Host'],
      transport: ->(_target, _line) {}, on_request: ->(request) { machine_requests << request }
    )
    machine.start
    machine.receive(UnobotV2::Machine::Protocol.parse(@fixture.fetch('registered_line')).value, source: 'Host')
    @fixture.fetch('state_lines').each do |line|
      machine.receive(UnobotV2::Machine::Protocol.parse(line).value)
    end

    human_requests = []
    human = UnobotV2::MessagingFactory.build(
      mode: 'human', channel: '#uno', own_nick: 'Alice', host_nicks: ['Host'],
      transport: ->(_target, _line) {}, on_request: ->(request) { human_requests << request }
    )
    human.receive(human_event(
      'UNO_STATUS_V1 phase=active current=Alice top=r7 mode=normal ' \
      'stacked_cards=0 already_picked=0 players=Alice:3,Bob:2,Carol:1', private: true
    ))
    human.receive(human_event('UNO_STATUS_PRIVATE_V1 picked_card=-', private: true))
    human.receive(human_event("\x034[2] \x0312[5] \x0313[WD4]", private: true))

    fixture_state = JSON.parse(File.read(UnobotV2MachineProtocolTest::JEDNA_PATH)).fetch('state')
    expected = fixture_state.transform_keys(&:to_sym)
    expected[:other_players] = expected[:other_players].map { |player| player.transform_keys(&:to_sym) }
    assert_equal 1, machine_requests.length
    assert_equal 1, human_requests.length
    assert_equal expected, machine_requests.first.state_h
    assert_equal machine_requests.first.state_h, human_requests.first.state_h
  end

  def test_same_fake_strategy_and_adapter_boundary_accept_canonical_draw_for_both_modes
    seen = []
    strategy = UnobotV2::LegacyStrategyAdapter.new do |request|
      seen << request
      { action: 'draw' }
    end

    human_sent = []
    human = nil
    human = UnobotV2::MessagingFactory.build(
      mode: 'human', channel: '#uno', own_nick: 'Alice', host_nicks: ['Host'],
      transport: ->(target, line) { human_sent << [target, line] },
      on_request: lambda do |request|
        human.submit(strategy.decide(request), decision_id: request.decision_id)
      end
    )
    human.receive(human_event(
      'UNO_STATUS_V1 phase=active current=Alice top=r7 mode=normal ' \
      'stacked_cards=0 already_picked=0 players=Alice:3,Bob:2,Carol:1', private: true
    ))
    human.receive(human_event('UNO_STATUS_PRIVATE_V1 picked_card=-', private: true))
    human.receive(human_event("\x034[2] \x0312[5] \x0313[WD4]", private: true))
    assert_equal ['#uno', 'pe'], human_sent.last

    machine_sent = []
    machine = nil
    machine = UnobotV2::MessagingFactory.build(
      mode: 'machine', channel: '#uno', own_nick: 'Alice', host_nicks: ['Host'],
      transport: ->(target, line) { machine_sent << [target, line] },
      on_request: lambda do |request|
        machine.submit(strategy.decide(request), decision_id: request.decision_id)
      end
    )
    machine.start
    machine.receive(UnobotV2::Machine::Protocol.parse(@fixture.fetch('registered_line')).value, source: 'Host')
    @fixture.fetch('state_lines').each do |line|
      machine.receive(UnobotV2::Machine::Protocol.parse(line).value)
    end
    assert_equal 2, seen.length
    assert_equal seen.first.state_h, seen.last.state_h
    assert_equal 'Host', machine_sent.last.first
    assert_includes machine_sent.last.last, 'UNO_MACHINE_V1 ACTION '
  end

  private

  def human_event(text, private: false)
    UnobotV2::Human::Event.new(
      channel: '#uno', source: 'Host', recipient: 'Alice', text: text, private: private
    )
  end
end

class UnobotV2RuntimeSelectionTest < Minitest::Test
  FIXTURE_PATH = UnobotV2MachineProtocolTest::FIXTURE_PATH

  RecordingStrategy = Struct.new(:seen) do
    def decide(request)
      seen << [request, Thread.current]
      UnobotV2::Canonical::Action.new(action: 'draw')
    end
  end

  def setup
    @fixture = JSON.parse(File.read(FIXTURE_PATH))
    @sent = Queue.new
    @submitted = Queue.new
    @seen = []
    @strategy = RecordingStrategy.new(@seen)
    @producer = Thread.current
  end

  def test_environment_default_explicit_selection_and_invalid_values
    assert_equal 'human', UnobotV2::Configuration.messaging({})
    assert_equal 'machine', UnobotV2::Configuration.messaging('UNO_MESSAGING' => 'machine')
    assert_equal true,
                 UnobotV2::Configuration.fallback_enabled?('UNO_MACHINE_HUMAN_FALLBACK' => 'yes')
    assert_raises(UnobotV2::Configuration::Error) do
      UnobotV2::Configuration.messaging('UNO_MESSAGING' => 'automatic')
    end
    assert_raises(UnobotV2::Configuration::Error) do
      UnobotV2::Runtime.from_env(
        strategy: @strategy, channels: ['#uno'], own_nick: 'Alice', host_nicks: ['Host'],
        transport: method(:send_line), env: { 'UNO_MESSAGING' => 'broken' }
      )
    end
  end

  def test_opt_in_runtime_runs_same_strategy_off_callback_thread_in_both_modes
    human = runtime('human').start
    enqueue_human_snapshot(human)
    wait_for { @submitted.size == 1 }
    human_submission, = @submitted.pop
    assert_predicate human_submission, :success?
    assert_equal 'pe', @sent.pop[1]
    refute_same @producer, @seen.last[1]
    human.stop

    machine = runtime('machine').start
    registration = @sent.pop
    assert_equal '.uno machine register', registration[1]
    refute_same @producer, registration[2]
    machine.enqueue(machine_notice(@fixture.fetch('registered_line')))
    @fixture.fetch('state_lines').each { |line| machine.enqueue(machine_notice(line)) }
    wait_for { @submitted.size == 1 }
    machine_submission, = @submitted.pop
    assert_predicate machine_submission, :success?
    assert_includes @sent.pop[1], 'UNO_MACHINE_V1 ACTION '
    refute_same @producer, @seen.last[1]
    assert_equal @seen[-2][0].state_h, @seen[-1][0].state_h
    machine.stop
  end

  def test_machine_start_and_graceful_stop_output_are_serialized_on_worker
    machine = runtime('machine').start
    registration = @sent.pop
    assert_equal '.uno machine register', registration[1]
    refute_same @producer, registration[2]
    machine.stop
    unregister = @sent.pop
    assert_equal '.uno machine unregister', unregister[1]
    refute_same @producer, unregister[2]
    assert_same registration[2], unregister[2]
  end

  def test_blocked_strategy_is_epoch_invalidated_before_machine_to_human_fallback
    started = Queue.new
    release = Queue.new
    blocking = Class.new(UnobotV2::Strategy) do
      define_method(:initialize) { |started_queue, release_queue| @started = started_queue; @release = release_queue }
      define_method(:decide) do |_request|
        @started << true
        @release.pop
        UnobotV2::Canonical::Action.new(action: 'draw')
      end
    end.new(started, release)
    runtime = UnobotV2::Runtime.new(
      messaging: 'machine', strategy: blocking, channels: ['#uno'], own_nick: 'Alice',
      host_nicks: ['Host'], transport: method(:send_line), fallback_enabled: true,
      on_submission: ->(result, request) { @submitted << [result, request] }
    ).start
    @sent.pop
    runtime.enqueue(machine_notice(@fixture.fetch('registered_line')))
    @fixture.fetch('state_lines').each { |line| runtime.enqueue(machine_notice(line)) }
    started.pop

    transition_result = Queue.new
    operator = Thread.new { transition_result << runtime.transition_to('human') }
    wait_for { operator.status == 'sleep' }
    release << true
    result = transition_result.pop
    operator.join
    assert_predicate result, :success?
    submission, = @submitted.pop
    assert_equal :invalidated_decision, submission.code

    outputs = []
    outputs << @sent.pop until @sent.empty?
    refute outputs.any? { |_target, line, _thread| line.include?(' ACTION ') }
    assert_equal ['.uno machine unregister', 'us', 'ca'], outputs.map { |entry| entry[1] }
    outputs.each do |_target, _line, thread|
      refute_same @producer, thread
      refute_same operator, thread
    end
    runtime.stop
  end

  def test_controlled_machine_to_human_fallback_never_merges_partial_state
    runtime = runtime('machine', fallback_enabled: true).start
    assert_equal '.uno machine register', @sent.pop[1]
    result = runtime.transition_to('human')
    assert_predicate result, :success?
    assert_equal 'human', runtime.mode
    assert_equal ['.uno machine unregister', 'us', 'ca'], 3.times.map { @sent.pop[1] }
    assert_empty @seen

    runtime.enqueue(human_event(
      'UNO_STATUS_V1 phase=active current=Alice top=r7 mode=normal ' \
      'stacked_cards=0 already_picked=0 players=Alice:3,Bob:2,Carol:1', private: true
    ))
    runtime.enqueue(human_event('UNO_STATUS_PRIVATE_V1 picked_card=-', private: true))
    sleep 0.01
    assert_empty @seen, 'partial fallback snapshot must not invoke strategy'
    runtime.enqueue(human_event("\x034[2] \x0312[5] \x0313[WD4]", private: true))
    wait_for { @submitted.size == 1 }
    assert_equal 1, @seen.length
    assert_equal 'human', @seen.first.first.metadata[:transport]
    runtime.stop
  end

  def test_fallback_defaults_disabled_and_human_to_machine_requires_restart
    machine = runtime('machine')
    result = machine.transition_to('human')
    assert_equal :fallback_disabled, result.code
    assert_equal 'machine', machine.mode

    human = runtime('human')
    result = human.transition_to('machine')
    assert_predicate result, :restart_required?
    assert_equal 'human', human.mode
  end

  def test_failed_unregister_remains_retryable_and_blocks_fallback_until_delivered
    sent = []
    unregister_attempts = 0
    transport = lambda do |target, line|
      sent << [target, line]
      if line == '.uno machine unregister'
        unregister_attempts += 1
        raise 'temporary IRC send failure' if unregister_attempts == 1
      end
    end
    runtime = UnobotV2::Runtime.new(
      messaging: 'machine', strategy: @strategy, channels: ['#uno'], own_nick: 'Alice',
      host_nicks: ['Host'], transport: transport, fallback_enabled: true
    ).start
    first = runtime.transition_to('human')
    assert_equal :transport_unavailable, first.code
    assert_equal 'machine', runtime.mode
    adapter = runtime.adapter_for('#uno')
    assert_equal :recovering, adapter.lifecycle
    assert_predicate adapter, :can_unregister?

    second = runtime.transition_to('human')
    assert_predicate second, :success?
    assert_equal 'human', runtime.mode
    assert_equal 2, unregister_attempts
    assert_equal ['.uno machine register', '.uno machine unregister',
                  '.uno machine unregister', 'us', 'ca'], sent.map(&:last)
    runtime.stop
  end

  def test_transition_requested_from_strategy_worker_returns_restart_required_without_deadlock
    transition = Queue.new
    runtime = nil
    runtime = UnobotV2::Runtime.new(
      messaging: 'machine', strategy: @strategy, channels: ['#uno'], own_nick: 'Alice',
      host_nicks: ['Host'], transport: method(:send_line), fallback_enabled: true,
      on_submission: ->(_result, _request) { transition << runtime.transition_to('human') }
    ).start
    @sent.pop
    runtime.enqueue(machine_notice(@fixture.fetch('registered_line')))
    @fixture.fetch('state_lines').each { |line| runtime.enqueue(machine_notice(line)) }
    result = transition.pop
    assert_predicate result, :restart_required?
    assert_equal 'machine', runtime.mode
    assert_predicate runtime.ingress.consumer, :alive?
    runtime.stop
  end

  def test_stop_requested_from_strategy_worker_is_deferred_without_self_join
    stop_result = Queue.new
    runtime = nil
    runtime = UnobotV2::Runtime.new(
      messaging: 'machine', strategy: @strategy, channels: ['#uno'], own_nick: 'Alice',
      host_nicks: ['Host'], transport: method(:send_line),
      on_submission: ->(_result, _request) { stop_result << runtime.stop }
    ).start
    @sent.pop
    runtime.enqueue(machine_notice(@fixture.fetch('registered_line')))
    @fixture.fetch('state_lines').each { |line| runtime.enqueue(machine_notice(line)) }
    result = stop_result.pop
    assert_predicate result, :success?
    assert_match(/deferred/, result.message)
    wait_for { !runtime.ingress.consumer.alive? }
  end

  def test_human_stop_invalidates_blocked_strategy_before_waiting_for_worker
    started = Queue.new
    release = Queue.new
    blocking = Class.new(UnobotV2::Strategy) do
      define_method(:initialize) { |started_queue, release_queue| @started = started_queue; @release = release_queue }
      define_method(:decide) do |_request|
        @started << true
        @release.pop
        UnobotV2::Canonical::Action.new(action: 'draw')
      end
    end.new(started, release)
    runtime = UnobotV2::Runtime.new(
      messaging: 'human', strategy: blocking, channels: ['#uno'], own_nick: 'Alice',
      host_nicks: ['Host'], transport: method(:send_line)
    ).start
    enqueue_human_snapshot(runtime)
    started.pop

    stopped = Queue.new
    operator = Thread.new { stopped << runtime.stop }
    wait_for { operator.status == 'sleep' }
    release << true
    assert_predicate stopped.pop, :success?
    operator.join
    sent = []
    sent << @sent.pop until @sent.empty?
    refute sent.any? { |_target, line, _thread| line == 'pe' }, 'stale human action must not escape after stop'
  end

  private

  def runtime(mode, fallback_enabled: false)
    UnobotV2::Runtime.new(
      messaging: mode, strategy: @strategy, channels: ['#uno'], own_nick: 'Alice',
      host_nicks: ['Host'], transport: method(:send_line), fallback_enabled: fallback_enabled,
      on_submission: ->(result, request) { @submitted << [result, request] }
    )
  end

  def send_line(target, line)
    @sent << [target, line, Thread.current]
  end

  def enqueue_human_snapshot(runtime)
    runtime.enqueue(human_event(
      'UNO_STATUS_V1 phase=active current=Alice top=r7 mode=normal ' \
      'stacked_cards=0 already_picked=0 players=Alice:3,Bob:2,Carol:1', private: true
    ))
    runtime.enqueue(human_event('UNO_STATUS_PRIVATE_V1 picked_card=-', private: true))
    runtime.enqueue(human_event("\x034[2] \x0312[5] \x0313[WD4]", private: true))
  end

  def human_event(text, private: false)
    UnobotV2::Human::Event.new(
      channel: '#uno', source: 'Host', recipient: 'Alice', text: text, private: private
    )
  end

  def machine_notice(text)
    UnobotV2::Machine::Event.new(source: 'Host', recipient: 'Alice', text: text)
  end

  def wait_for(timeout: 1)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise 'timed out waiting for async runtime' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      Thread.pass
    end
  end
end
