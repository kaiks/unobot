# frozen_string_literal: true

require_relative 'test_helper'
require 'base64'
require_relative '../lib/unobot_v2'

class UnobotV2StrategyManagerTest < Minitest::Test
  class RecordingStrategy
    attr_reader :games, :ended, :cancelled, :requests

    def initialize(action = { action: 'draw' })
      @action = action
      @games = []
      @ended = []
      @cancelled = []
      @requests = []
    end

    def start_game(key) = games << key
    def decide(request) = requests << request && @action
    def end_game(key, reason:) = ended << [key, reason]
    def cancel(reason:) = cancelled << reason
    def shutdown = @shutdown = true
    def shutdown? = @shutdown
    def retry_capable? = false
  end

  class FailingStartStrategy
    attr_reader :shutdown_count

    def initialize
      @shutdown_count = 0
    end

    def start_game(_key) = raise('cannot start strategy')
    def shutdown = @shutdown_count += 1
  end

  class ValidatingPersistentStrategy < RecordingStrategy
    attr_reader :starts

    def initialize
      super
      @starts = 0
      @fail_start = false
    end

    def lifecycle = :persistent

    def validate_request!(request)
      raise UnobotV2::ProcessAgent::Error.new(:unsupported_topology, 'two players only') unless request.other_players.one?
    end

    def start_game(key)
      @starts += 1
      raise UnobotV2::ProcessAgent::Error.new(:restart_backoff, 'backed off') if @fail_start

      super
    end

    def fail_start! = @fail_start = true
  end

  def machine_request(game: 'g1', transport: 'machine', generation: 1,
                      playable: [], actions: ['draw'])
    metadata = { decision_id: "d-#{game}-#{generation}", channel: '#uno', transport: transport }
    if transport == 'machine'
      metadata[:game_id] = game
    else
      metadata[:game_generation] = generation
    end
    UnobotV2::Canonical::DecisionRequest.new(
      your_id: 'unobot', hand: playable.empty? ? %w[r5 g2] : playable,
      top_card: 'b7', game_state: 'normal', stacked_cards: 0,
      already_picked: false, picked_card: nil,
      other_players: [{ id: 'human', card_count: 2 }],
      available_actions: actions, playable_cards: playable, metadata: metadata
    )
  end

  def test_strategy_is_frozen_during_game_and_changes_between_games
    simple = RecordingStrategy.new
    crushing = RecordingStrategy.new
    manager = UnobotV2::StrategyManager.new(
      selected: 'simple', factories: {
        simple: -> { simple }, crushing: -> { crushing }
      }
    )

    assert_equal 'draw', manager.decide(machine_request).action
    rejected = manager.select('crushing')
    assert_equal :game_active, rejected.code
    assert_equal 'simple', rejected.strategy
    assert_equal 'draw', manager.decide(machine_request(generation: 2)).action
    assert_equal 2, simple.requests.length
    assert_empty crushing.requests

    assert_predicate manager.game_end(reason: 'host_game_ended'), :success?
    assert_predicate manager.select('crushing'), :success?
    assert_equal 'draw', manager.decide(machine_request(game: 'g2')).action
    assert_equal 1, crushing.requests.length
    assert_equal [['machine:#uno:g1', 'host_game_ended']], simple.ended
  ensure
    manager&.shutdown
  end

  def test_neural_capacity_prevents_multiple_channels_from_spawning_models
    created = []
    manager = UnobotV2::StrategyManager.new(
      selected: 'neural', limits: { neural: 1 },
      factories: { neural: -> { RecordingStrategy.new.tap { |strategy| created << strategy } } }
    )
    manager.decide(machine_request(game: 'one'))
    second = machine_request(game: 'two')
    metadata = second.metadata.merge(channel: '#other')
    second = UnobotV2::Canonical::DecisionRequest.new(**second.state_h, metadata: metadata)

    error = assert_raises(UnobotV2::Configuration::Error) { manager.decide(second) }
    assert_match(/at most 1 active game/, error.message)
    assert_equal 1, created.length
    assert_equal ['machine:#uno:one'], manager.active_game_keys
  ensure
    manager&.shutdown
  end

  def test_preflight_rejects_unsupported_topology_without_occupying_neural_slot
    strategy = ValidatingPersistentStrategy.new
    manager = UnobotV2::StrategyManager.new(
      selected: 'neural', limits: { neural: 1 }, factories: { neural: -> { strategy } }
    )
    unsupported = machine_request(game: 'unsupported')
    unsupported = UnobotV2::Canonical::DecisionRequest.new(
      **unsupported.state_h,
      other_players: [{ id: 'one', card_count: 2 }, { id: 'two', card_count: 2 }],
      metadata: unsupported.metadata
    )

    error = assert_raises(UnobotV2::ProcessAgent::Error) { manager.decide(unsupported) }
    assert_equal :unsupported_topology, error.code
    assert_empty manager.active_game_keys
    assert_equal 0, strategy.starts
    assert_equal 'draw', manager.decide(machine_request(game: 'valid')).action
    assert_equal 1, strategy.starts
  ensure
    manager&.shutdown
  end

  def test_failed_persistent_start_is_retained_with_its_backoff_state
    strategy = ValidatingPersistentStrategy.new
    strategy.fail_start!
    created = 0
    manager = UnobotV2::StrategyManager.new(
      selected: 'neural', factories: { neural: -> { created += 1; strategy } }
    )

    2.times do
      error = assert_raises(UnobotV2::ProcessAgent::Error) do
        manager.decide(machine_request(game: 'start-failure'))
      end
      assert_equal :restart_backoff, error.code
      assert_empty manager.active_game_keys
    end
    assert_equal 1, created
    assert_equal 2, strategy.starts
  ensure
    manager&.shutdown
  end

  def test_new_machine_game_cancels_stale_active_game_conservatively
    first = RecordingStrategy.new
    manager = UnobotV2::StrategyManager.new(selected: 'simple', factories: { simple: -> { first } })
    manager.decide(machine_request(game: 'one'))
    manager.decide(machine_request(game: 'two'))
    assert_equal ['new_game_observed'], first.cancelled
    assert_equal %w[machine:#uno:one machine:#uno:two], first.games
  ensure
    manager&.shutdown
  end

  def test_two_machine_channels_have_independent_strategy_instances_and_lifecycles
    created = []
    manager = UnobotV2::StrategyManager.new(
      selected: 'simple', factories: {
        simple: -> { RecordingStrategy.new.tap { |strategy| created << strategy } },
        crushing: -> { RecordingStrategy.new }
      }
    )
    first = machine_request(game: 'one')
    second = UnobotV2::Canonical::DecisionRequest.new(
      **machine_request(game: 'two').state_h,
      metadata: machine_request(game: 'two').metadata.merge(channel: '#other')
    )
    manager.decide(first)
    manager.decide(second)

    assert_equal %w[machine:#other:two machine:#uno:one], manager.active_game_keys
    active = created.select { |strategy| strategy.requests.any? }
    assert_equal 2, active.length
    refute_same active[0], active[1]
    assert_predicate manager.game_end('machine:#uno:one'), :success?
    assert_equal ['machine:#other:two'], manager.active_game_keys
    assert_empty active.find { |strategy| strategy.requests.include?(second) }.ended
    assert_equal :game_active, manager.select('crushing').code
  ensure
    manager&.shutdown
  end

  def test_human_game_generation_is_the_conservative_session_key
    strategy = RecordingStrategy.new
    manager = UnobotV2::StrategyManager.new(selected: 'simple', factories: { simple: -> { strategy } })
    manager.decide(machine_request(transport: 'human', generation: 4))
    manager.decide(machine_request(transport: 'human', generation: 4))
    assert_equal ['human:#uno:4'], strategy.games
    manager.decide(machine_request(transport: 'human', generation: 5))
    assert_equal ['new_game_observed'], strategy.cancelled
  ensure
    manager&.shutdown
  end

  def test_retry_policy_requests_authoritative_registration_without_replay
    strategy = RecordingStrategy.new
    manager = UnobotV2::StrategyManager.new(selected: 'simple', factories: { simple: -> { strategy } })
    request = machine_request
    manager.decide(request)
    assert_equal :reregister, manager.retryable_error(request, code: 'executor_busy')
    assert_equal 1, strategy.requests.length
  ensure
    manager&.shutdown
  end

  def test_simple_and_crushing_use_maintained_programs_with_same_contract_in_both_modes
    fixtures = Dir[File.expand_path('fixtures/jedna_protocol_v1/*.json', __dir__)].sort
    %w[simple crushing].each do |name|
      actions_by_transport = {}
      %w[human machine].each do |transport|
        strategy = UnobotV2::StrategyFactory.build(name, env: {})
        strategy.start_game("#{transport}-#{name}")
        begin
          actions_by_transport[transport] = fixtures.map.with_index do |path, index|
            request = UnobotV2::Canonical::DecisionRequest.from_protocol(
              JSON.parse(File.read(path)),
              metadata: {
                channel: '#uno', transport: transport, game_id: 'contract',
                game_generation: 1, decision_id: "contract-#{index}"
              }
            )
            action = strategy.decide(request)
            assert_instance_of UnobotV2::Canonical::Action, action
            assert_equal action, UnobotV2::ActionValidator.validate(action, request: request)
            action.to_h
          end
        ensure
          strategy.shutdown
        end
      end
      assert_equal actions_by_transport.fetch('human'), actions_by_transport.fetch('machine'), name
    end
  end

  def test_configuration_validation_and_legacy_v2_rejection_are_explicit
    assert_equal 'legacy', UnobotV2::Configuration.strategy({})
    assert_equal 'simple', UnobotV2::Configuration.strategy('UNO_STRATEGY' => 'SIMPLE')
    assert_raises(UnobotV2::Configuration::Error) do
      UnobotV2::Configuration.strategy('UNO_STRATEGY' => 'random')
    end
    error = assert_raises(UnobotV2::Configuration::Error) do
      UnobotV2::StrategyManager.from_env(env: { 'UNO_STRATEGY' => 'legacy' })
    end
    assert_match(/historical IRC tracker state/, error.message)
    assert_raises(UnobotV2::Configuration::Error) do
      UnobotV2::StrategyFactory.build(
        'simple', env: { 'UNO_SIMPLE_ARGV' => '"ruby x.rb"' }
      )
    end
  end

  def test_strategy_change_validates_new_factory_before_publishing_selection
    manager = UnobotV2::StrategyManager.new(
      selected: 'simple', factories: {
        simple: -> { RecordingStrategy.new },
        crushing: -> { raise UnobotV2::Configuration::Error, 'missing crushing executable' }
      }
    )
    result = manager.select('crushing')
    assert_equal :configuration_error, result.code
    assert_match(/missing crushing executable/, result.message)
    assert_equal 'simple', manager.selected_name
  ensure
    manager&.shutdown
  end

  def test_failed_game_start_discards_checked_out_instance_without_accumulating_sessions
    created = []
    manager = UnobotV2::StrategyManager.new(
      selected: 'simple', factories: {
        simple: -> { FailingStartStrategy.new.tap { |strategy| created << strategy } }
      }
    )
    2.times do
      error = assert_raises(RuntimeError) { manager.decide(machine_request) }
      assert_equal 'cannot start strategy', error.message
      assert_empty manager.active_game_keys
    end
    assert_equal 2, created.length
    assert created.all? { |strategy| strategy.shutdown_count == 1 }
    assert_empty manager.instance_variable_get(:@all_instances)
  ensure
    manager&.shutdown
  end

  def test_shutdown_cancels_selection_and_closes_all_created_strategies
    strategy = RecordingStrategy.new
    manager = UnobotV2::StrategyManager.new(selected: 'simple', factories: { simple: -> { strategy } })
    manager.decide(machine_request)
    manager.shutdown
    manager.shutdown
    assert strategy.shutdown?
    assert_equal :shutdown, manager.select('simple').code
    assert_raises(UnobotV2::Configuration::Error) { manager.decide(machine_request) }
  end

  def test_human_runtime_releases_strategy_immediately_on_game_end
    created = []
    manager = UnobotV2::StrategyManager.new(
      selected: 'simple', factories: {
        simple: -> { RecordingStrategy.new.tap { |strategy| created << strategy } },
        crushing: -> { RecordingStrategy.new }
      }
    )
    sent = Queue.new
    runtime = UnobotV2::Runtime.new(
      messaging: 'human', strategy: manager, channels: ['#uno'], own_nick: 'unobot',
      host_nicks: ['Host'], transport: ->(target, line) { sent << [target, line] }
    ).start
    human_snapshot(runtime)
    wait_for { manager.active? }
    runtime.enqueue(human_event('unobot gains 1 points.'))
    wait_for { !manager.active? }
    assert_predicate manager.select('crushing'), :success?
    assert_equal 1, created.sum { |strategy| strategy.ended.length }
  ensure
    runtime&.stop
  end

  def test_machine_runtime_retry_reregisters_without_replay
    fixture = JSON.parse(File.read(File.expand_path('fixtures/host_machine_protocol_v1/frames.json', __dir__)))
    created = []
    manager = UnobotV2::StrategyManager.new(
      selected: 'simple', factories: {
        simple: -> { RecordingStrategy.new.tap { |strategy| created << strategy } },
        crushing: -> { RecordingStrategy.new }
      }
    )
    sent = Queue.new
    runtime = UnobotV2::Runtime.new(
      messaging: 'machine', strategy: manager, channels: ['#uno'], own_nick: 'Alice',
      host_nicks: ['Host'], transport: ->(target, line) { sent << [target, line] }
    ).start
    sent.pop
    runtime.enqueue(machine_notice(fixture.fetch('registered_line')))
    fixture.fetch('state_lines').each { |line| runtime.enqueue(machine_notice(line)) }
    wait_for { manager.active? && !sent.empty? }
    outputs = []
    outputs << sent.pop until sent.empty?
    assert_equal 1, outputs.count { |_target, line| line.include?(' ACTION ') }

    runtime.enqueue(machine_notice(fixture.fetch('error_line')))
    wait_for { !manager.active? && !sent.empty? }
    retry_outputs = []
    retry_outputs << sent.pop until sent.empty?
    assert_equal ['.uno machine register'], retry_outputs.map(&:last)
    assert_equal 1, created.sum { |strategy| strategy.requests.length }
    assert_predicate manager.select('crushing'), :success?
  ensure
    runtime&.stop
  end

  def test_machine_terminal_event_releases_the_target_game_immediately
    fixture = JSON.parse(File.read(File.expand_path('fixtures/host_machine_protocol_v1/frames.json', __dir__)))
    manager = UnobotV2::StrategyManager.new(
      selected: 'simple', factories: {
        simple: -> { RecordingStrategy.new }, crushing: -> { RecordingStrategy.new }
      }
    )
    sent = Queue.new
    runtime = UnobotV2::Runtime.new(
      messaging: 'machine', strategy: manager, channels: ['#uno'], own_nick: 'Alice',
      host_nicks: ['Host'], transport: ->(target, line) { sent << [target, line] }
    ).start
    sent.pop
    runtime.enqueue(machine_notice(fixture.fetch('registered_line')))
    fixture.fetch('state_lines').each { |line| runtime.enqueue(machine_notice(line)) }
    wait_for { manager.active? }
    runtime.enqueue(machine_notice(fixture.fetch('ack_line')))
    fixture.fetch('event_lines').each { |line| runtime.enqueue(machine_notice(line)) }
    wait_for { !manager.active? }
    assert_predicate manager.select('crushing'), :success?
  ensure
    runtime&.stop
  end

  def test_runtime_stop_cancels_blocked_process_without_recovery_output_in_both_modes
    fixture = JSON.parse(File.read(File.expand_path('fixtures/host_machine_protocol_v1/frames.json', __dir__)))
    process_fixture = File.expand_path('fixtures/process_agents/protocol_agent.rb', __dir__)
    %w[human machine].each do |mode|
      manager = UnobotV2::StrategyManager.new(
        selected: 'simple', factories: {
          simple: lambda do
            UnobotV2::ProcessAgent.new(
              argv: [RbConfig.ruby, process_fixture, 'timeout'], name: "blocked-#{mode}",
              request_timeout: 10, shutdown_timeout: 0.1
            )
          end
        }
      )
      sent = Queue.new
      runtime = UnobotV2::Runtime.new(
        messaging: mode, strategy: manager, channels: ['#uno'],
        own_nick: mode == 'human' ? 'unobot' : 'Alice', host_nicks: ['Host'],
        transport: ->(target, line) { sent << [target, line] }
      ).start
      sent.pop if mode == 'machine'
      if mode == 'human'
        human_snapshot(runtime)
      else
        runtime.enqueue(machine_notice(fixture.fetch('registered_line')))
        fixture.fetch('state_lines').each { |line| runtime.enqueue(machine_notice(line)) }
      end
      wait_for do
        manager.diagnostics[:sessions].values.any? do |entry|
          entry[:diagnostics][:running]
        end
      end
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_predicate runtime.stop, :success?
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
      outputs = []
      outputs << sent.pop until sent.empty?
      refute outputs.any? { |_target, line| line.include?(' ACTION ') }, mode
      refute outputs.any? { |_target, line| %w[us ca .uno\ machine\ register].include?(line) }, mode
      assert outputs.all? { |_target, line| line == '.uno machine unregister' }, mode if mode == 'machine'
      assert manager.diagnostics[:shutdown]
    ensure
      runtime&.stop
    end
  end

  def test_machine_to_human_fallback_cancels_machine_strategy_session
    fixture = JSON.parse(File.read(File.expand_path('fixtures/host_machine_protocol_v1/frames.json', __dir__)))
    manager = UnobotV2::StrategyManager.new(
      selected: 'simple', factories: { simple: -> { RecordingStrategy.new } }
    )
    sent = Queue.new
    runtime = UnobotV2::Runtime.new(
      messaging: 'machine', strategy: manager, channels: ['#uno'], own_nick: 'Alice',
      host_nicks: ['Host'], transport: ->(target, line) { sent << [target, line] },
      fallback_enabled: true
    ).start
    sent.pop
    runtime.enqueue(machine_notice(fixture.fetch('registered_line')))
    fixture.fetch('state_lines').each { |line| runtime.enqueue(machine_notice(line)) }
    wait_for { manager.active? }
    assert_predicate runtime.transition_to('human'), :success?
    refute manager.active?
    assert_predicate manager.select('simple'), :success?
  ensure
    runtime&.stop
  end

  def test_own_rename_cancels_every_old_channel_session_and_timeout_leaves_no_orphan
    fixture = JSON.parse(File.read(File.expand_path('fixtures/host_machine_protocol_v1/frames.json', __dir__)))
    created = []
    manager = UnobotV2::StrategyManager.new(
      selected: 'simple', factories: {
        simple: -> { RecordingStrategy.new.tap { |strategy| created << strategy } },
        crushing: -> { RecordingStrategy.new }
      }
    )
    sent = Queue.new
    runtime = UnobotV2::Runtime.new(
      messaging: 'machine', strategy: manager, channels: %w[#uno #other], own_nick: 'Alice',
      host_nicks: ['Host'], transport: ->(target, line) { sent << [target, line] }
    ).start
    2.times { sent.pop }

    runtime.enqueue(machine_notice(fixture.fetch('registered_line')))
    other_registration = fixture.fetch('registered_line')
                                .sub('game=gameFixture1', 'game=gameOther1')
                                .sub('channel=I3Vubw', "channel=#{Base64.urlsafe_encode64('#other', padding: false)}")
    runtime.enqueue(machine_notice(other_registration))
    fixture.fetch('state_lines').each { |line| runtime.enqueue(machine_notice(line)) }
    reframe(fixture.fetch('state_lines'), game_id: 'gameOther1').each do |line|
      runtime.enqueue(machine_notice(line))
    end
    runtime.ingress.synchronize
    ingress_errors = []
    ingress_errors << runtime.ingress.errors.pop until runtime.ingress.errors.empty?
    assert_equal %w[machine:#other:gameOther1 machine:#uno:gameFixture1], manager.active_game_keys,
                 ingress_errors.map { |error| [error.code, error.message] }.inspect
    sent.pop until sent.empty?

    runtime.enqueue(UnobotV2::Machine::Event.new(
      kind: :nick, old_nick: 'Alice', new_nick: 'Alice2'
    ))
    wait_for { manager.active_game_keys.empty? }
    wait_for { sent.size >= 2 }
    rename_lines = []
    rename_lines << sent.pop until sent.empty?
    assert_equal 2, rename_lines.count { |_target, line| line == '.uno machine register' }

    new_registration = fixture.fetch('registered_line').sub('game=gameFixture1', 'game=gameFixture2')
    runtime.enqueue(machine_notice(new_registration, recipient: 'Alice2'))
    reframe(fixture.fetch('state_lines'), game_id: 'gameFixture2').each do |line|
      runtime.enqueue(machine_notice(line, recipient: 'Alice2'))
    end
    wait_for { manager.active_game_keys == ['machine:#uno:gameFixture2'] }
    assert_operator created.sum { |strategy| strategy.requests.length }, :>=, 3

    other_adapter = runtime.adapter_for('#other')
    other_adapter.instance_variable_set(:@rename_recovery_deadline, -1.0)
    runtime.tick
    wait_for { other_adapter.lifecycle == :unregistered }
    assert_equal ['machine:#uno:gameFixture2'], manager.active_game_keys

    reframe(fixture.fetch('event_lines'), game_id: 'gameFixture2').each do |line|
      runtime.enqueue(machine_notice(line, recipient: 'Alice2'))
    end
    wait_for { manager.active_game_keys.empty? }
    assert_predicate manager.select('crushing'), :success?
  ensure
    runtime&.stop
  end

  private

  def human_snapshot(runtime)
    runtime.enqueue(human_event(
      'UNO_STATUS_V1 phase=active current=unobot top=r7 mode=normal ' \
      'stacked_cards=0 already_picked=0 players=unobot:2,Bob:2', private: true
    ))
    runtime.enqueue(human_event('UNO_STATUS_PRIVATE_V1 picked_card=-', private: true))
    runtime.enqueue(human_event("\x034[2] \x0312[5]", private: true))
  end

  def human_event(text, private: false)
    UnobotV2::Human::Event.new(
      channel: '#uno', source: 'Host', recipient: 'unobot', text: text, private: private
    )
  end

  def machine_notice(text, recipient: 'Alice')
    UnobotV2::Machine::Event.new(source: 'Host', recipient: recipient, text: text)
  end

  def reframe(lines, game_id:)
    messages = lines.map { |line| UnobotV2::Machine::Protocol.parse(line).value }.sort_by(&:part)
    original = UnobotV2::Machine::Protocol.decode_payload(messages.map(&:data).join)
    raise original.message if original.is_a?(UnobotV2::Machine::Protocol::Error)

    payload = original.merge('game_id' => game_id)
    encoded = Base64.urlsafe_encode64(Zlib::Deflate.deflate(JSON.generate(payload)), padding: false)
    chunks = encoded.scan(/.{1,#{UnobotV2::Machine::Protocol::CHUNK_BYTES}}/)
    kind = messages.first.kind.to_s.upcase
    event = messages.first.event ? " event=#{messages.first.event}" : ''
    chunks.each_with_index.map do |chunk, index|
      "UNO_MACHINE_V1 #{kind} game=#{game_id} decision=#{messages.first.decision_id}" \
        "#{event} part=#{index + 1}/#{chunks.length} data=#{chunk}"
    end
  end

  def wait_for(timeout: 2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise 'timed out waiting for async runtime' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      Thread.pass
    end
  end
end
