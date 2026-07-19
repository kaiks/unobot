# frozen_string_literal: true

require_relative 'test_helper'
require 'json'
require_relative '../lib/unobot_v2'

# Opt-in because the external checkpoint and Python Torch/SB3 stack are not
# repository dependencies. Run with UNO_RUN_REAL_NEURAL_TESTS=1.
class UnobotV2NeuralRealTest < Minitest::Test
  DEFAULT_EXAMPLES = '/home/karol/projects/jedna/extension-gems/jedna-tournaments/examples'
  DEFAULT_CHECKPOINT = '/home/karol/projects/jedna/extension-gems/jedna-tournaments/models/' \
                       'jedna_multiplayer_v3.zip'

  def setup
    skip 'set UNO_RUN_REAL_NEURAL_TESTS=1 for the external model smoke test' unless ENV['UNO_RUN_REAL_NEURAL_TESTS'] == '1'
    skip 'external Jedna examples are unavailable' unless File.file?(File.join(examples, 'rl_agent/sb3_opponent.py'))
    skip 'external multiplayer v3 checkpoint is unavailable' unless File.file?(checkpoint)
  end

  def test_real_checkpoint_cold_warm_and_game_reset_reuse
    health_started = monotonic
    manager = UnobotV2::StrategyManager.from_env(
      env: {
        'UNO_STRATEGY' => 'neural',
        'UNO_TOURNAMENT_EXAMPLES' => examples,
        'UNO_NEURAL_CHECKPOINT' => checkpoint,
        'UNO_NEURAL_PYTHON' => ENV.fetch('UNO_NEURAL_PYTHON', 'python3'),
        'UNO_NEURAL_COLD_TIMEOUT' => '20', 'UNO_NEURAL_WARM_TIMEOUT' => '2'
      }
    )
    cold_health = monotonic - health_started
    agent = manager.instance_variable_get(:@idle).fetch('neural').last
    request = multiplayer_request(players: 2)
    process = agent.instance_variable_get(:@process)
    pid = process.instance_variable_get(:@wait_thread).pid
    assert_equal :ready, agent.diagnostics[:health]
    assert_equal false, agent.diagnostics[:game_active]
    assert_operator cold_health, :<, 20

    warm_started = monotonic
    first = manager.decide(request)
    first_warm = monotonic - warm_started
    warm_started = monotonic
    second = manager.decide(request)
    second_warm = monotonic - warm_started
    UnobotV2::ActionValidator.validate(first, request: request)
    UnobotV2::ActionValidator.validate(second, request: request)
    assert_equal first, second
    assert_operator first_warm, :<, 2
    assert_operator second_warm, :<, 2
    assert_equal :ready, agent.diagnostics[:health]

    (2..10).each do |players|
      table_request = multiplayer_request(
        players: players, game: 'real', decision: "real-#{players}-decision"
      )
      action = manager.decide(table_request)
      UnobotV2::ActionValidator.validate(action, request: table_request)
    end

    assert_predicate manager.game_end('machine:#uno:real', reason: 'smoke_reset'), :success?
    next_request = multiplayer_request(players: 10, game: 'real-ten')
    assert manager.decide(next_request)
    assert_equal pid, process.instance_variable_get(:@wait_thread).pid
  ensure
    manager&.shutdown
  end

  private

  def examples = ENV.fetch('UNO_TOURNAMENT_EXAMPLES', DEFAULT_EXAMPLES)
  def checkpoint = ENV.fetch('UNO_NEURAL_CHECKPOINT', DEFAULT_CHECKPOINT)

  def multiplayer_request(players:, game: 'real', decision: nil)
    envelope = JSON.parse(File.read(File.expand_path(
      'fixtures/jedna_protocol_v1/request_action_normal.json', __dir__
    )))
    envelope.fetch('state')['other_players'] = (2..players).map do |index|
      { 'id' => "player#{index}", 'card_count' => index }
    end
    UnobotV2::Canonical::DecisionRequest.from_protocol(
      envelope, metadata: {
        channel: '#uno', transport: 'machine', game_id: game,
        decision_id: decision || "#{game}-decision"
      }
    )
  end

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
