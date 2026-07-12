# frozen_string_literal: true

require_relative 'test_helper'
require 'json'
require_relative '../lib/unobot_v2'

# Opt-in because the external checkpoint and Python Torch/SB3 stack are not
# repository dependencies. Run with UNO_RUN_REAL_NEURAL_TESTS=1.
class UnobotV2NeuralRealTest < Minitest::Test
  EXAMPLES = '/home/karol/projects/jedna/extension-gems/jedna-tournaments/examples'
  CHECKPOINT = '/home/karol/projects/jedna/extension-gems/jedna-tournaments/checkpoints/' \
               'overnight-dagger/checkpoint_17500000_steps.zip'

  def setup
    skip 'set UNO_RUN_REAL_NEURAL_TESTS=1 for the external model smoke test' unless ENV['UNO_RUN_REAL_NEURAL_TESTS'] == '1'
    skip 'external Jedna examples are unavailable' unless File.file?(File.join(EXAMPLES, 'rl_agent/sb3_opponent.py'))
    skip 'external 17.5M checkpoint is unavailable' unless File.file?(CHECKPOINT)
  end

  def test_real_checkpoint_cold_warm_and_game_reset_reuse
    agent = UnobotV2::StrategyFactory.build(
      'neural', env: {
        'UNO_TOURNAMENT_EXAMPLES' => EXAMPLES,
        'UNO_NEURAL_CHECKPOINT' => CHECKPOINT,
        'UNO_NEURAL_COLD_TIMEOUT' => '20', 'UNO_NEURAL_WARM_TIMEOUT' => '2'
      }
    )
    request = two_player_request
    agent.start_game('real-one')
    process = agent.instance_variable_get(:@process)
    pid = process.instance_variable_get(:@wait_thread).pid

    cold_started = monotonic
    first = agent.decide(request)
    cold = monotonic - cold_started
    warm_started = monotonic
    second = agent.decide(request)
    warm = monotonic - warm_started
    UnobotV2::ActionValidator.validate(first, request: request)
    UnobotV2::ActionValidator.validate(second, request: request)
    assert_operator cold, :<, 20
    assert_operator warm, :<, 2
    assert_equal :ready, agent.diagnostics[:health]

    agent.end_game('real-one', reason: 'smoke_reset')
    agent.start_game('real-two')
    assert_equal pid, process.instance_variable_get(:@wait_thread).pid
    assert agent.decide(request)
  ensure
    agent&.shutdown
  end

  private

  def two_player_request
    envelope = JSON.parse(File.read(File.expand_path(
      'fixtures/jedna_protocol_v1/request_action_normal.json', __dir__
    )))
    envelope.fetch('state')['other_players'] = [envelope.fetch('state').fetch('other_players').first]
    UnobotV2::Canonical::DecisionRequest.from_protocol(
      envelope, metadata: {
        channel: '#uno', transport: 'machine', game_id: 'real', decision_id: 'real-decision'
      }
    )
  end

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
