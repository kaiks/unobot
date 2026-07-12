# frozen_string_literal: true

require_relative 'test_helper'
require 'json'
require 'open3'
require_relative '../lib/unobot_v2'

class UnobotV2NeuralContractTest < Minitest::Test
  PROBE = File.expand_path('fixtures/neural_action_probe.py', __dir__)
  FIXTURES = Dir[File.expand_path('fixtures/jedna_protocol_v1/request_action_*.json', __dir__)].sort.freeze

  def setup
    @examples = UnobotV2::StrategyFactory.discover_examples(File.expand_path('..', __dir__))
    skip 'sibling Jedna tournament examples are unavailable' unless @examples
    @python = ENV.fetch('UNO_NEURAL_PYTHON', 'python3')
    skip "configured Python #{@python.inspect} is unavailable" unless system(
      @python, '--version', out: File::NULL, err: File::NULL
    )
  end

  def test_python_action_masks_match_canonical_validation_and_human_encoding
    envelopes = FIXTURES.map { |path| JSON.parse(File.read(path)) }
    states = envelopes.map { |envelope| envelope.fetch('state') }
    python_actions = probe(states)
    encoder = UnobotV2::Human::ActionEncoder.new

    envelopes.zip(python_actions, FIXTURES).each do |(envelope, actions, path)|
      request = UnobotV2::Canonical::DecisionRequest.from_protocol(
        envelope, metadata: { channel: '#uno', transport: 'machine', game_id: 'fixture' }
      )
      assert_equal expected_action_keys(request), actions.map { |action| action_key(action) }.sort,
                   File.basename(path)
      actions.each do |action|
        canonical = UnobotV2::ActionValidator.validate(action, request: request)
        assert encoder.expressible?(canonical, request: request), "human cannot encode #{action.inspect}"
      end
      assert_same request, encoder.mask_request(request), File.basename(path)
    end
  end

  def test_double_wd4_is_enabled_validated_and_encoded_exactly
    base = JSON.parse(File.read(FIXTURES.find { |path| path.end_with?('request_action_wd4_war.json') }))
    state = base.fetch('state')
    state['hand'] = %w[wd4 wd4 r5]
    state['playable_cards'] = %w[wd4 wd4]
    state['available_actions'] = ['play']
    state['already_picked'] = false
    state['picked_card'] = nil
    actions = probe([state]).first
    double = actions.find { |action| action['card'] == 'wd4' && action['double_play'] }
    refute_nil double

    request = UnobotV2::Canonical::DecisionRequest.from_protocol(
      base, metadata: { channel: '#uno', transport: 'human', game_generation: 1 }
    )
    canonical = UnobotV2::ActionValidator.validate(double, request: request)
    encoded = UnobotV2::Human::ActionEncoder.new.encode(canonical, request: request)
    assert_predicate encoded, :success?
    assert_match(/\Apl wd4([rgby])wd4\1\z/, encoded.command)
  end

  private

  def probe(states)
    stdout, stderr, status = Open3.capture3(
      @python, PROBE, @examples, stdin_data: JSON.generate(states), chdir: @examples
    )
    assert status.success?, stderr
    JSON.parse(stdout)
  end

  def expected_action_keys(request)
    actions = []
    actions << ['draw', nil, false] if request.available_actions.include?('draw')
    actions << ['pass', nil, false] if request.available_actions.include?('pass')
    if request.available_actions.include?('play')
      request.playable_cards.uniq.each do |card|
        actions << ['play', card, false]
        actions << ['play', card, true] if !request.already_picked && request.hand.count(card) >= 2
      end
    end
    actions.sort
  end

  def action_key(action)
    [action.fetch('action'), action['card'], action['double_play'] == true]
  end
end
