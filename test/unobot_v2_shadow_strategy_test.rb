# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../lib/unobot_v2'

class UnobotV2ShadowStrategyTest < Minitest::Test
  class FakeStrategy
    attr_reader :calls

    def initialize(action:, gate: nil, failure: nil)
      @action = action
      @gate = gate
      @failure = failure
      @calls = Queue.new
    end

    def decide(request)
      calls << [:decide, request]
      @gate&.pop
      raise @failure if @failure

      @action
    end

    def game_end_for(request, reason:)
      calls << [:game_end_for, request, reason]
      :ended
    end

    def cancel_scope(scope, reason:)
      calls << [:cancel_scope, scope, reason]
      :cancelled
    end

    def shutdown
      calls << [:shutdown]
    end
  end

  def setup
    @request = UnobotV2::Canonical::DecisionRequest.new(
      your_id: 'Bot', hand: ['r5'], top_card: 'b7', game_state: 'normal',
      stacked_cards: 0, already_picked: false, picked_card: nil,
      other_players: [{ id: 'Human', card_count: 7 }],
      available_actions: %w[play draw], playable_cards: ['r5'],
      metadata: { channel: '#uno', game_id: 'g1', decision_id: 'd1', transport: 'machine' }
    )
    @draw = UnobotV2::Canonical::Action.new(action: 'draw')
    @play = UnobotV2::Canonical::Action.new(action: 'play', card: 'r5')
    @wrappers = []
  end

  def teardown
    @wrappers.each(&:shutdown)
  end

  def test_shadow_output_is_observed_but_primary_action_is_the_only_return_value
    observations = Queue.new
    primary = FakeStrategy.new(action: @draw)
    shadow = FakeStrategy.new(action: @play)
    wrapper = build(primary, shadow, observations)

    assert_equal @draw, wrapper.decide(@request)
    result = observations.pop(timeout: 1)
    assert_equal :ok, result.status
    assert_equal({ action: 'draw' }, result.primary_action)
    assert_equal({ action: 'play', card: 'r5' }, result.shadow_action)
    refute result.agreement
    assert_operator result.latency_ms, :>=, 0
    assert_equal '#uno', result.channel
    assert_equal 'g1', result.game_id
    assert_equal 'd1', result.decision_id
  end

  def test_slow_or_failed_shadow_never_delays_or_replaces_primary_action
    gate = Queue.new
    observations = Queue.new
    primary = FakeStrategy.new(action: @draw)
    shadow = FakeStrategy.new(action: @play, gate: gate, failure: RuntimeError.new('model crashed'))
    wrapper = build(primary, shadow, observations)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_equal @draw, wrapper.decide(@request)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.1
    gate << true
    result = observations.pop(timeout: 1)
    assert_equal :error, result.status
    assert_equal :shadow_error, result.error_code
    assert_match(/model crashed/, result.error_message)
  end

  def test_lifecycle_is_ordered_after_observation_and_forwarded_to_both_strategies
    observations = Queue.new
    primary = FakeStrategy.new(action: @draw)
    shadow = FakeStrategy.new(action: @play)
    wrapper = build(primary, shadow, observations)

    wrapper.decide(@request)
    assert_equal :ended, wrapper.game_end_for(@request, reason: 'winner')
    observations.pop(timeout: 1)
    assert_equal [:decide, @request], shadow.calls.pop(timeout: 1)
    assert_equal [:game_end_for, @request, 'winner'], shadow.calls.pop(timeout: 1)
    assert_equal [:decide, @request], primary.calls.pop(timeout: 1)
    assert_equal [:game_end_for, @request, 'winner'], primary.calls.pop(timeout: 1)
  end

  def test_queue_overflow_reports_drop_and_does_not_block_primary
    gate = Queue.new
    observations = Queue.new
    primary = FakeStrategy.new(action: @draw)
    shadow = FakeStrategy.new(action: @play, gate: gate)
    wrapper = build(primary, shadow, observations, queue_capacity: 1)

    wrapper.decide(@request)
    wait_until { !shadow.calls.empty? }
    second = request('d2')
    assert_equal @draw, wrapper.decide(second)
    dropped = observations.pop(timeout: 1)
    assert_equal :dropped, dropped.status
    assert_equal :shadow_queue_full, dropped.error_code
    assert_equal 'd2', dropped.decision_id
    gate << true
  end

  def test_lifecycle_is_guaranteed_while_decision_capacity_is_saturated
    gate = Queue.new
    observations = Queue.new
    primary = FakeStrategy.new(action: @draw)
    shadow = FakeStrategy.new(action: @play, gate: gate)
    wrapper = build(primary, shadow, observations, queue_capacity: 1)

    wrapper.decide(@request)
    wait_until { !shadow.calls.empty? }
    assert_equal [:decide, @request], shadow.calls.pop(timeout: 1)
    wrapper.game_end_for(@request, reason: 'saturated_end')
    assert_equal @draw, wrapper.decide(request('d2'))
    assert_equal :dropped, observations.pop(timeout: 1).status
    gate << true
    assert_equal :ok, observations.pop(timeout: 1).status
    assert_equal [:game_end_for, @request, 'saturated_end'], shadow.calls.pop(timeout: 1)
  end

  def test_configuration_accepts_only_canonical_shadow_strategies
    assert_nil UnobotV2::Configuration.shadow_strategy({})
    assert_nil UnobotV2::Configuration.shadow_strategy('UNO_SHADOW_STRATEGY' => 'none')
    assert_equal 'neural', UnobotV2::Configuration.shadow_strategy('UNO_SHADOW_STRATEGY' => 'NEURAL')
    assert_raises(UnobotV2::Configuration::Error) do
      UnobotV2::Configuration.shadow_strategy('UNO_SHADOW_STRATEGY' => 'legacy')
    end
  end

  private

  def build(primary, shadow, observations, queue_capacity: 8)
    wrapper = UnobotV2::ShadowStrategy.new(
      primary: primary, shadow: shadow, queue_capacity: queue_capacity,
      on_observation: ->(result) { observations << result }
    )
    @wrappers << wrapper
    wrapper
  end

  def request(decision_id)
    UnobotV2::Canonical::DecisionRequest.from_protocol(
      @request.protocol_h,
      metadata: @request.metadata.merge(decision_id: decision_id)
    )
  end

  def wait_until(timeout: 1)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    Thread.pass until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    assert yield
  end
end
