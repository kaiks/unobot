# frozen_string_literal: true

require_relative 'test_helper'
require 'rbconfig'
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
  end
end
