# frozen_string_literal: true

require_relative 'test_helper'
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
    %w[human machine].each do |transport|
      request = machine_request(
        transport: transport, playable: ['r5'], actions: %w[play draw]
      )
      %w[simple crushing].each do |name|
        strategy = UnobotV2::StrategyFactory.build(name, env: {})
        strategy.start_game("#{transport}-#{name}")
        action = strategy.decide(request)
        assert_instance_of UnobotV2::Canonical::Action, action
        assert_equal({ action: 'play', card: 'r5' }, action.to_h)
      ensure
        strategy&.shutdown
      end
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

  def machine_notice(text)
    UnobotV2::Machine::Event.new(source: 'Host', recipient: 'Alice', text: text)
  end

  def wait_for(timeout: 2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise 'timed out waiting for async runtime' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      Thread.pass
    end
  end
end
