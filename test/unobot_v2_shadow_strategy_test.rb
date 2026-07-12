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

  class NoopPrimary
    attr_reader :shutdown_count

    def initialize(action)
      @action = action
      @shutdown_count = 0
    end

    def decide(_request) = @action
    def game_end_for(*) = :ended
    def cancel_for(*) = :cancelled
    def cancel_scope(*) = :cancelled

    def shutdown
      @shutdown_count += 1
      self
    end
  end

  class WedgedShadow
    attr_reader :decision_started, :control_started, :shutdown_count

    def initialize(action)
      @action = action
      @decision_gate = Queue.new
      @control_gate = Queue.new
      @decision_started = Queue.new
      @control_started = Queue.new
      @shutdown_count = 0
    end

    def decide(_request)
      decision_started << true
      @decision_gate.pop
      @action
    end

    def game_end_for(*)
      control_started << true
      @control_gate.pop
      :ended
    end

    def shutdown
      @shutdown_count += 1
      @decision_gate << true
      @control_gate << true
      self
    end
  end

  class PreemptibleShadow
    attr_reader :decision_started, :ended

    def initialize(action)
      @action = action
      @gate = Queue.new
      @decision_started = Queue.new
      @ended = Queue.new
    end

    def decide(_request)
      decision_started << true
      @gate.pop
      @action
    end

    def game_end_for(*)
      ended << true
      @gate << true
      :ended
    end

    def shutdown
      @gate << true
      self
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
    observations.pop(timeout: 1)
    assert_equal :ended, wrapper.game_end_for(@request, reason: 'winner')
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
    invalidated = observations.pop(timeout: 1)
    assert_equal :dropped, invalidated.status
    assert_equal :shadow_decision_invalidated, invalidated.error_code
    assert_equal [:game_end_for, @request, 'saturated_end'], shadow.calls.pop(timeout: 1)
  end

  def test_twenty_thousand_repeated_controls_stay_bounded_and_shutdown_joins_wedged_workers
    observations = Queue.new
    primary = NoopPrimary.new(@draw)
    shadow = WedgedShadow.new(@play)
    wrapper = UnobotV2::ShadowStrategy.new(
      primary: primary, shadow: shadow, queue_capacity: 1, shutdown_timeout: 0.1,
      on_observation: ->(result) { observations << result }
    )
    @wrappers << wrapper

    assert_equal @draw, wrapper.decide(@request)
    shadow.decision_started.pop(timeout: 1) || flunk('shadow decision did not start')
    wrapper.game_end_for(@request, reason: 'stress')
    shadow.control_started.pop(timeout: 1) || flunk('shadow lifecycle did not start')
    19_999.times { wrapper.game_end_for(@request, reason: 'stress') }

    diagnostics = wrapper.diagnostics
    assert_operator diagnostics.fetch(:queued_decisions), :<=, 1
    assert_operator diagnostics.fetch(:queued_controls), :<=, 1
    assert_operator wrapper.instance_variable_get(:@decision_queue).length, :<=, 1
    assert_operator wrapper.instance_variable_get(:@control_queue).length, :<=, 1

    wrapper.shutdown
    refute wrapper.diagnostics.fetch(:decision_worker_alive)
    refute wrapper.diagnostics.fetch(:control_worker_alive)
    assert_equal 1, primary.shutdown_count
    assert_operator shadow.shutdown_count, :>=, 1
    assert_same wrapper, wrapper.shutdown
    assert_equal 1, primary.shutdown_count
  end

  def test_lifecycle_preempts_a_wedged_shadow_decision_without_blocking_primary
    observations = Queue.new
    primary = NoopPrimary.new(@draw)
    shadow = PreemptibleShadow.new(@play)
    wrapper = build(primary, shadow, observations, queue_capacity: 1)

    assert_equal @draw, wrapper.decide(@request)
    shadow.decision_started.pop(timeout: 1) || flunk('shadow decision did not start')
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_equal :ended, wrapper.game_end_for(@request, reason: 'preempt')
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.1
    shadow.ended.pop(timeout: 1) || flunk('shadow lifecycle did not run')
    result = observations.pop(timeout: 1)
    assert_equal :dropped, result.status
    assert_equal :shadow_decision_invalidated, result.error_code
    wait_until { wrapper.diagnostics.fetch(:queued_decisions).zero? }
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
