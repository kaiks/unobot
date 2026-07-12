# frozen_string_literal: true

require_relative 'test_helper'
require 'rbconfig'
require 'tmpdir'
require_relative '../lib/unobot_v2'

class UnobotV2NeuralAgentTest < Minitest::Test
  class FailingSpawnProcess
    attr_reader :name, :starts

    def initialize
      @name = 'neural'
      @starts = 0
    end

    def start_game(_key)
      @starts += 1
      raise UnobotV2::ProcessAgent::Error.new(:startup_failed, 'fixture spawn failure')
    end

    def running? = false
    def process_generation = 0
    def shutdown = nil
    def diagnostics = { name: name, running: false }
  end

  PROCESS_FIXTURE = File.expand_path('fixtures/process_agents/protocol_agent.rb', __dir__)
  FAKE_PYTHON = File.expand_path('fixtures/process_agents/fake_python.rb', __dir__)
  EXAMPLES_FIXTURE = File.expand_path('fixtures/neural_examples', __dir__)

  def teardown
    @agents&.each(&:shutdown)
  end

  def request(opponents: 1, actions: ['draw'])
    UnobotV2::Canonical::DecisionRequest.new(
      your_id: 'neural', hand: %w[r5 g2], top_card: 'b7', game_state: 'normal',
      stacked_cards: 0, already_picked: false, picked_card: nil,
      other_players: Array.new(opponents) { |index| { id: "human#{index}", card_count: 2 } },
      available_actions: actions, playable_cards: [],
      metadata: { decision_id: 'd1', game_id: 'g1', channel: '#uno', transport: 'machine' }
    )
  end

  def neural(mode, clock: nil, start: true, **options)
    process = UnobotV2::ProcessAgent.new(
      argv: [RbConfig.ruby, PROCESS_FIXTURE, mode], name: 'neural',
      lifecycle: :persistent, request_timeout: 1, shutdown_timeout: 0.1
    )
    values = {
      process: process, cold_timeout: 0.5, warm_timeout: 0.05,
      backoff_initial: 1, backoff_max: 4
    }.merge(options)
    values[:clock] = clock if clock
    UnobotV2::NeuralAgent.new(**values).tap do |agent|
      @agents ||= []
      @agents << agent
      agent.start_game('g1') if start
    end
  end

  def test_startup_health_check_validates_and_retains_the_warm_idle_process
    agent = neural('persistent_valid', start: false)
    agent.startup_health_check!
    process = agent.instance_variable_get(:@process)
    pid = process.instance_variable_get(:@wait_thread).pid
    assert_equal :ready, agent.diagnostics[:health]
    assert_equal false, agent.diagnostics[:game_active]

    agent.start_game('live')
    assert_equal pid, process.instance_variable_get(:@wait_thread).pid
    assert_equal 'draw', agent.decide(request).action
  end

  def test_operator_health_check_runs_again_against_the_same_warm_process
    agent = neural('persistent_valid', start: false)
    agent.startup_health_check!
    process = agent.instance_variable_get(:@process)
    pid = process.instance_variable_get(:@wait_thread).pid
    generation = process.diagnostics.fetch(:generation)

    assert_same agent, agent.health_check!
    assert_equal pid, process.instance_variable_get(:@wait_thread).pid
    assert_operator process.diagnostics.fetch(:generation), :>, generation
    assert_equal :ready, agent.diagnostics[:health]
    assert_equal false, agent.diagnostics[:game_active]
  end

  def test_idle_process_death_marks_replacement_cold_instead_of_reusing_warm_deadline
    agent = neural('persistent_exit_slow')
    assert_equal 'draw', agent.decide(request).action
    process = agent.instance_variable_get(:@process)
    first_pid = process.instance_variable_get(:@wait_thread).pid
    agent.end_game('g1', reason: 'idle death fixture')
    sleep 0.01 while agent.diagnostics[:running]

    agent.start_game('g2')
    refute_equal first_pid, process.instance_variable_get(:@wait_thread).pid
    assert_equal :loading, agent.diagnostics[:health]
    # The fixture needs 100ms. This succeeds only with the 500ms cold deadline;
    # retaining the 50ms warm deadline deterministically times out.
    assert_equal 'draw', agent.decide(request).action
  end

  def test_process_stays_warm_across_games_and_health_becomes_ready
    agent = neural('persistent_valid')
    assert_equal :loading, agent.diagnostics[:health]
    assert_equal 'draw', agent.decide(request).action
    pid = agent.instance_variable_get(:@process).instance_variable_get(:@wait_thread).pid
    assert_equal :ready, agent.diagnostics[:health]
    assert agent.end_game('g1')
    agent.start_game('g2')
    assert_equal pid, agent.instance_variable_get(:@process).instance_variable_get(:@wait_thread).pid
    assert_equal 'draw', agent.decide(request).action
  end

  def test_first_decision_uses_cold_deadline_and_later_decision_uses_warm_deadline
    agent = neural('persistent_slow')
    assert_equal 'draw', agent.decide(request).action
    error = assert_raises(UnobotV2::ProcessAgent::Error) { agent.decide(request) }
    assert_equal :request_timeout, error.code
    assert_equal :failed, agent.diagnostics[:health]
  end

  def test_failure_has_bounded_exponential_restart_backoff
    instant = 100.0
    clock = -> { instant }
    agent = neural('eof', clock: clock)
    assert_raises(UnobotV2::ProcessAgent::Error) { agent.decide(request) }
    diagnostics = agent.diagnostics
    assert_equal 1, diagnostics[:consecutive_failures]
    assert_in_delta 1.0, diagnostics[:retry_in_seconds], 0.001

    error = assert_raises(UnobotV2::ProcessAgent::Error) { agent.decide(request) }
    assert_equal :restart_backoff, error.code
    assert_equal 1, agent.diagnostics[:consecutive_failures]

    instant += 1.1
    assert_raises(UnobotV2::ProcessAgent::Error) { agent.decide(request) }
    assert_equal 2, agent.diagnostics[:consecutive_failures]
    assert_in_delta 2.0, agent.diagnostics[:retry_in_seconds], 0.001
  end

  def test_concurrent_decisions_admit_only_one_failure_before_backoff
    agent = neural('eof')
    process = agent.instance_variable_get(:@process)
    initial_process_generation = process.process_generation
    gate = Queue.new
    outcomes = Queue.new
    threads = 2.times.map do
      Thread.new do
        gate.pop
        agent.decide(request)
        outcomes << :action
      rescue UnobotV2::ProcessAgent::Error => error
        outcomes << error.code
      end
    end
    2.times { gate << true }
    threads.each { |thread| assert thread.join(2) }

    assert_equal %i[process_eof restart_backoff], 2.times.map { outcomes.pop }.sort
    assert_equal 1, agent.diagnostics[:consecutive_failures]
    assert_equal initial_process_generation, process.process_generation
    refute agent.diagnostics[:running]
  end

  def test_queued_decisions_stay_clean_when_lifecycle_cancels_the_game
    %i[cancel end_game].each do |operation|
      agent = neural('timeout', cold_timeout: 10, warm_timeout: 10)
      process = agent.instance_variable_get(:@process)
      process_generation = process.process_generation
      gate = Queue.new
      outcomes = Queue.new
      threads = 2.times.map do
        Thread.new do
          gate.pop
          agent.decide(request)
          outcomes << :action
        rescue UnobotV2::ProcessAgent::Error => error
          outcomes << error.code
        end
      end
      2.times { gate << true }
      sleep 0.005 until process.diagnostics[:generation] >= 2
      if operation == :cancel
        agent.cancel(reason: 'concurrent lifecycle test')
      else
        agent.end_game('g1', reason: 'concurrent lifecycle test')
      end
      threads.each { |thread| assert thread.join(2), operation }

      results = 2.times.map { outcomes.pop }
      refute_includes results, :action, operation
      assert_includes results, :no_game, operation
      assert_equal 0, agent.diagnostics[:consecutive_failures], operation
      assert_equal :unverified, agent.diagnostics[:health], operation
      assert_equal process_generation, process.process_generation, operation
      refute agent.diagnostics[:running], operation
    end
  end

  def test_spawn_failure_backoff_is_enforced_before_another_spawn_attempt
    instant = 100.0
    process = FailingSpawnProcess.new
    agent = UnobotV2::NeuralAgent.new(
      process: process, cold_timeout: 1, warm_timeout: 1,
      backoff_initial: 1, backoff_max: 2, clock: -> { instant }
    )
    @agents ||= []
    @agents << agent

    error = assert_raises(UnobotV2::ProcessAgent::Error) { agent.start_game('one') }
    assert_equal :startup_failed, error.code
    assert_equal 1, process.starts
    error = assert_raises(UnobotV2::ProcessAgent::Error) { agent.start_game('one') }
    assert_equal :restart_backoff, error.code
    assert_equal 1, process.starts

    instant += 1.1
    assert_raises(UnobotV2::ProcessAgent::Error) { agent.start_game('one') }
    assert_equal 2, process.starts
    assert_in_delta 2.0, agent.diagnostics[:retry_in_seconds], 0.001
  end

  def test_only_two_player_topology_is_supported_without_poisoning_health
    agent = neural('persistent_valid')
    error = assert_raises(UnobotV2::ProcessAgent::Error) { agent.decide(request(opponents: 2)) }
    assert_equal :unsupported_topology, error.code
    assert_equal 0, agent.diagnostics[:consecutive_failures]
    assert agent.diagnostics[:running]
  end

  def test_factory_uses_module_argv_deterministically_unless_opted_in
    Dir.mktmpdir('unobot-checkpoint') do |directory|
      checkpoint = File.join(directory, 'checkpoint_17500000_steps.zip')
      File.write(checkpoint, 'fixture')
      base = {
        'UNO_TOURNAMENT_EXAMPLES' => EXAMPLES_FIXTURE,
        'UNO_NEURAL_CHECKPOINT' => checkpoint,
        'UNO_NEURAL_PYTHON' => FAKE_PYTHON,
        'UNO_NEURAL_COLD_TIMEOUT' => '2', 'UNO_NEURAL_WARM_TIMEOUT' => '1'
      }

      deterministic = UnobotV2::StrategyFactory.build('neural', env: base)
      @agents ||= []
      @agents << deterministic
      deterministic.start_game('g1')
      assert_equal 'draw', deterministic.decide(request(actions: %w[draw pass])).action
      assert_equal true, deterministic.diagnostics[:deterministic]

      stochastic = UnobotV2::StrategyFactory.build(
        'neural', env: base.merge('UNO_NEURAL_STOCHASTIC' => 'true')
      )
      @agents << stochastic
      stochastic.start_game('g2')
      assert_equal 'pass', stochastic.decide(request(actions: %w[draw pass])).action
      assert_equal false, stochastic.diagnostics[:deterministic]
    end
  end

  def test_factory_rejects_missing_module_checkpoint_and_invalid_stochastic_value
    error = assert_raises(UnobotV2::Configuration::Error) do
      UnobotV2::StrategyFactory.build(
        'neural', env: { 'UNO_TOURNAMENT_EXAMPLES' => '/definitely/missing' }
      )
    end
    assert_match(/neural module was not found/, error.message)

    error = assert_raises(UnobotV2::Configuration::Error) do
      UnobotV2::StrategyFactory.build(
        'neural', env: { 'UNO_TOURNAMENT_EXAMPLES' => EXAMPLES_FIXTURE,
                         'UNO_NEURAL_CHECKPOINT' => '/definitely/missing' }
      )
    end
    assert_match(/checkpoint is not a readable file/, error.message)

    Dir.mktmpdir do |directory|
      checkpoint = File.join(directory, 'model.zip')
      File.write(checkpoint, 'fixture')
      error = assert_raises(UnobotV2::Configuration::Error) do
        UnobotV2::StrategyFactory.build(
          'neural', env: { 'UNO_TOURNAMENT_EXAMPLES' => EXAMPLES_FIXTURE,
                           'UNO_NEURAL_CHECKPOINT' => checkpoint,
                           'UNO_NEURAL_STOCHASTIC' => 'sometimes' }
        )
      end
      assert_match(/UNO_NEURAL_STOCHASTIC/, error.message)
    end
  end
end
