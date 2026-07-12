# frozen_string_literal: true

require_relative 'test_helper'
require 'rbconfig'
require 'minitest/mock'
require_relative '../lib/unobot_v2'

class UnobotV2ProcessAgentTest < Minitest::Test
  FIXTURE = File.expand_path('fixtures/process_agents/protocol_agent.rb', __dir__)

  def teardown
    @agents&.each(&:shutdown)
  end

  def request
    UnobotV2::Canonical::DecisionRequest.new(
      your_id: 'bot', hand: %w[r5 g2], top_card: 'b7', game_state: 'normal',
      stacked_cards: 0, already_picked: false, picked_card: nil,
      other_players: [{ id: 'other', card_count: 2 }],
      available_actions: ['draw'], playable_cards: [],
      metadata: { decision_id: 'd1', game_id: 'g1', transport: 'machine' }
    )
  end

  def agent(mode, **options)
    @agents ||= []
    created = UnobotV2::ProcessAgent.new(
      argv: [RbConfig.ruby, FIXTURE, mode], name: mode,
      request_timeout: 0.25, shutdown_timeout: 0.1, **options
    )
    @agents << created
    created.start_game('g1')
  end

  def test_valid_request_repeated_games_and_reaping
    strategy = agent('valid')
    assert_equal({ action: 'draw' }, strategy.decide(request).to_h)
    pid = strategy.instance_variable_get(:@wait_thread).pid
    assert strategy.end_game('g1')
    refute strategy.running?
    assert_raises(Errno::ESRCH) { Process.kill(0, pid) }

    strategy.start_game('g2')
    assert_equal 'draw', strategy.decide(request).action
    assert strategy.running?
  end

  def test_stderr_is_drained_and_diagnostics_are_bounded_and_secret_free
    strategy = agent('stderr_flood', stderr_tail_bytes: 256)
    assert_equal 'draw', strategy.decide(request).action
    diagnostics = strategy.diagnostics
    assert_operator diagnostics[:stderr_bytes], :>, 100_000
    assert_operator diagnostics[:stderr_tail_bytes], :<=, 256
    refute_includes diagnostics.keys, :argv
    refute_includes diagnostics.keys, :stderr_tail
  end

  def test_malformed_noisy_duplicate_oversized_and_invalid_outputs_fail_closed
    expected = {
      'malformed' => :malformed_output,
      'array' => :invalid_response,
      'duplicate' => :duplicate_output,
      'noise' => :malformed_output,
      'oversized' => :oversized_output
    }
    expected.each do |mode, code|
      error = assert_raises(UnobotV2::ProcessAgent::Error, mode) { agent(mode).decide(request) }
      assert_equal code, error.code, mode
    end

    assert_raises(UnobotV2::Canonical::ValidationError) { agent('invalid_action').decide(request) }
    assert_empty @agents.select(&:running?)
  end

  def test_timeout_eof_and_crash_can_restart_on_the_next_game
    timeout = agent('timeout')
    error = assert_raises(UnobotV2::ProcessAgent::Error) { timeout.decide(request) }
    assert_equal :request_timeout, error.code
    refute timeout.running?

    eof_agent = agent('eof')
    error = assert_raises(UnobotV2::ProcessAgent::Error) { eof_agent.decide(request) }
    assert_equal :process_eof, error.code
    refute eof_agent.running?
  end

  def test_cancel_invalidates_late_response_and_kills_child_group
    strategy = agent('timeout', request_timeout: 5.0)
    outcome = Queue.new
    thread = Thread.new do
      strategy.decide(request)
    rescue StandardError => error
      outcome << error
    end
    sleep 0.05 until strategy.diagnostics[:generation] >= 2
    strategy.cancel(reason: 'game ended')
    assert thread.join(1), 'request thread remained blocked after cancellation'
    assert_equal :cancelled, outcome.pop.code
    refute strategy.running?
  end

  def test_persistent_policy_keeps_surviving_process_and_shutdown_is_idempotent
    strategy = agent('valid', lifecycle: :persistent)
    first_pid = strategy.instance_variable_get(:@wait_thread).pid
    strategy.end_game('g1')
    # The maintained fixture exits on game_end, so persistent mode detects that
    # exit and starts a fresh process at the next game.
    sleep 0.01 while strategy.running?
    strategy.start_game('g2')
    refute_equal first_pid, strategy.instance_variable_get(:@wait_thread).pid
    strategy.shutdown
    strategy.shutdown
    assert_equal :shutdown, strategy.diagnostics[:status]
  end

  def test_configuration_rejects_shell_strings_and_missing_files
    assert_raises(ArgumentError) do
      UnobotV2::ProcessAgent.new(argv: 'ruby agent.rb', name: 'bad')
    end
    error = assert_raises(UnobotV2::ProcessAgent::Error) do
      UnobotV2::ProcessAgent.new(argv: [RbConfig.ruby, '/definitely/missing.rb'], name: 'bad')
    end
    assert_equal :missing_script, error.code
    error = assert_raises(UnobotV2::ProcessAgent::Error) do
      UnobotV2::ProcessAgent.new(argv: ['sh', '/definitely/missing.py'], name: 'bad')
    end
    assert_equal :missing_script, error.code
  end

  def test_concurrent_decision_and_game_end_never_leave_a_child_or_late_action
    10.times do |index|
      strategy = agent('timeout', request_timeout: 2.0)
      outcome = Queue.new
      decision = Thread.new do
        strategy.decide(request)
        outcome << :action
      rescue StandardError => error
        outcome << error.code
      end
      sleep 0.005 until strategy.diagnostics[:generation] >= 2
      pid = strategy.instance_variable_get(:@wait_thread)&.pid
      strategy.end_game('g1', reason: "race-#{index}")
      assert decision.join(1)
      refute_equal :action, outcome.pop
      refute strategy.running?
      assert_raises(Errno::ESRCH) { Process.kill(0, pid) } if pid
    end
  end

  def test_concurrent_start_and_cancel_are_serialized_without_double_spawn
    10.times do
      strategy = UnobotV2::ProcessAgent.new(
        argv: [RbConfig.ruby, FIXTURE, 'valid'], name: 'start-race',
        startup_timeout: 1, request_timeout: 1, shutdown_timeout: 0.1
      )
      @agents ||= []
      @agents << strategy
      outcomes = Queue.new
      starter = Thread.new do
        strategy.start_game('g1')
        outcomes << :started
      rescue UnobotV2::ProcessAgent::Error => error
        outcomes << error.code
      end
      canceller = Thread.new { strategy.cancel(reason: 'startup race') }
      assert starter.join(2)
      assert canceller.join(2)
      assert_includes %i[started cancelled], outcomes.pop
      refute strategy.running?
    end
  end

  def test_startup_timeout_and_immediate_exit_keep_the_structured_failure
    strategy = UnobotV2::ProcessAgent.new(
      argv: [RbConfig.ruby, FIXTURE, 'valid'], name: 'slow-start',
      startup_timeout: 0.05, shutdown_timeout: 0.05
    )
    @agents ||= []
    @agents << strategy
    slow_spawn = lambda do |*_argv, **_options|
      sleep 1
      raise 'unreachable'
    end
    error = Open3.stub(:popen3, slow_spawn) do
      assert_raises(UnobotV2::ProcessAgent::Error) { strategy.start_game('g1') }
    end
    assert_equal :startup_timeout, error.code
    refute strategy.running?

    immediate = UnobotV2::ProcessAgent.new(
      argv: [RbConfig.ruby, FIXTURE, 'immediate_exit'], name: 'immediate',
      startup_timeout: 1, shutdown_timeout: 0.05
    )
    @agents << immediate
    # Scheduling may observe the exit just after start; in either case the
    # first request reports a structured startup/EOF failure and reaps it.
    begin
      immediate.start_game('g1')
      error = assert_raises(UnobotV2::ProcessAgent::Error) { immediate.decide(request) }
      assert_includes %i[startup_failed process_eof], error.code
    rescue UnobotV2::ProcessAgent::Error => error
      assert_equal :startup_failed, error.code
    end
    refute immediate.running?
  end
end
