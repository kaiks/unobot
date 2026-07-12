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
end
