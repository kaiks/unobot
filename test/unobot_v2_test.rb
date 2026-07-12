# frozen_string_literal: true

require_relative 'test_helper'
require 'json'
require_relative '../lib/unobot_v2'

class UnobotV2CanonicalTest < Minitest::Test
  FIXTURES = File.expand_path('fixtures/jedna_protocol_v1/*.json', __dir__)

  def test_vendored_jedna_protocol_fixtures_round_trip
    Dir[FIXTURES].sort.each do |path|
      source = JSON.parse(File.read(path))
      request = UnobotV2::Canonical::DecisionRequest.from_protocol(source)

      assert_predicate request, :frozen?
      assert_equal source, JSON.parse(JSON.generate(request.protocol_h)), File.basename(path)
      assert_equal request, UnobotV2::Canonical::DecisionRequest.from_protocol(source)
    end
  end

  def test_rejects_invalid_and_mutable_looking_state
    error = assert_raises(UnobotV2::Canonical::ValidationError) do
      UnobotV2::Canonical::DecisionRequest.from_protocol({
        'type' => 'request_action', 'protocol_version' => 1,
        'state' => JSON.parse(File.read(Dir[FIXTURES].first)).fetch('state').merge('hand' => ['oops'])
      })
    end
    assert_match(/invalid hand card/, error.message)
  end

  def test_rejects_non_boolean_protocol_and_action_fields
    source = JSON.parse(File.read(Dir[FIXTURES].first))
    source['state']['already_picked'] = 'false'
    error = assert_raises(UnobotV2::Canonical::ValidationError) do
      UnobotV2::Canonical::DecisionRequest.from_protocol(source)
    end
    assert_equal 'already_picked must be boolean', error.message

    [nil, [], 'draw'].each do |value|
      assert_raises(UnobotV2::Canonical::ValidationError) { UnobotV2::Canonical::Action.from(value) }
    end
    error = assert_raises(UnobotV2::Canonical::ValidationError) do
      UnobotV2::Canonical::Action.from({ action: 'play', card: 'r5', double_play: 'false' })
    end
    assert_equal 'double_play must be boolean', error.message
  end
end

class UnobotV2RulesTest < Minitest::Test
  def setup
    @rules = UnobotV2::Rules.new
  end

  def test_matches_all_jedna_fixture_legal_actions
    Dir[UnobotV2CanonicalTest::FIXTURES].each do |path|
      state = JSON.parse(File.read(path)).fetch('state')
      result = @rules.derive(
        hand: state['hand'], top_card: state['top_card'], game_state: state['game_state'],
        stacked_cards: state['stacked_cards'], already_picked: state['already_picked'],
        picked_card: state['picked_card']
      )
      assert_equal state['available_actions'], result.available_actions, File.basename(path)
      assert_equal state['playable_cards'], result.playable_cards, File.basename(path)
    end
  end

  def test_wars_reverse_selected_wilds_and_post_draw
    assert @rules.playable?('rr', 'r+2', 'war_+2')
    assert @rules.playable?('gr', 'wd4g', 'war_wd4')
    refute @rules.playable?('rr', 'wd4g', 'war_wd4')
    refute @rules.playable?('w', 'wd4g', 'war_wd4')
    result = @rules.derive(hand: %w[r5 r5 b2], top_card: 'r7', game_state: 'normal',
                           stacked_cards: 0, already_picked: true, picked_card: 'b2')
    assert_equal ['pass'], result.available_actions
    assert_empty result.playable_cards
  end
end

class UnobotV2HumanAdapterTest < Minitest::Test
  class NoDoubleEncoder < UnobotV2::Human::ActionEncoder
    def encode(action, request:)
      canonical = UnobotV2::Canonical::Action.from(action)
      if canonical.double_play
        return Result.new(code: :unsupported_double, message: 'fixture encoder cannot emit doubles')
      end

      super
    end
  end

  class RejectAllEncoder < UnobotV2::Human::ActionEncoder
    def encode(_action, request:)
      Result.new(code: :unsupported, message: "fixture cannot encode for #{request.your_id}")
    end
  end

  HOST = 'ZbojeiJureq'
  CHANNEL = '#uno-test'
  GREEN_3 = "\x033[3]"
  RED_5 = "\x034[5]"
  RED_7 = "\x034[7]"
  RED_PLUS_2 = "\x034[+2]"
  WILD = "\x0313[W]"
  WD4 = "\x0313[WD4]"

  def setup
    @sent = []
    @requests = []
    @adapter = UnobotV2::Human::Adapter.new(
      channel: CHANNEL, own_nick: 'Alice', host_nicks: [HOST],
      transport: ->(channel, command) { @sent << [channel, command] },
      on_request: ->(request) { @requests << request }
    )
  end

  def event(text, private: false, recipient: nil, channel: CHANNEL, source: HOST, **extra)
    UnobotV2::Human::Event.new(channel: channel, source: source, text: text,
                               private: private, recipient: recipient, **extra)
  end

  def status(top: 'r7', mode: 'normal', stacked: 0, picked: 0,
             current: 'Alice', players: 'Alice:3,Bob:2,Carol:1')
    "UNO_STATUS_V1 phase=active current=#{current} top=#{top} mode=#{mode} " \
      "stacked_cards=#{stacked} already_picked=#{picked} players=#{players}"
  end

  def synchronize(hand: "#{RED_5} #{GREEN_3} #{WD4}", **status_options)
    @adapter.receive(event(status(**status_options), private: true, recipient: 'Alice'))
    if status_options.fetch(:current, 'Alice') == 'Alice'
      picked = status_options.fetch(:picked, 0) == 1 ? 'r5' : '-'
      @adapter.receive(event("UNO_STATUS_PRIVATE_V1 picked_card=#{picked}", private: true, recipient: 'Alice'))
    end
    @adapter.receive(event(hand, private: true, recipient: 'Alice'))
    @requests.last
  end

  def test_status_hand_resync_action_encoding_and_deduplication
    request = synchronize
    assert_equal %w[r5 wd4], request.playable_cards
    assert_equal %w[play draw], request.available_actions
    assert_equal 'exact', request.metadata[:confidence]

    duplicate = status
    @adapter.receive(event(duplicate, private: true, recipient: 'Alice'))
    assert_equal 1, @requests.length

    result = @adapter.submit({ action: 'play', card: 'wd4', wild_color: 'red', double_play: false },
                             decision_id: request.decision_id)
    assert_predicate result, :success?
    assert_equal [CHANNEL, 'pl wd4r'], @sent.last
    duplicate_action = @adapter.submit({ action: 'draw' }, decision_id: request.decision_id)
    assert_equal :duplicate_action, duplicate_action.code
  end

  def test_double_and_double_wd4_are_expressible_without_restricting_rules
    request = synchronize(hand: "#{RED_5} #{RED_5} #{WD4} #{WD4}", players: 'Alice:4,Bob:2')
    result = @adapter.submit({ action: 'play', card: 'r5', double_play: true }, decision_id: request.decision_id)
    assert_equal 'pl r5r5', result.command

    request = synchronize(hand: "#{WD4} #{WD4}", players: 'Alice:2,Bob:2')
    result = @adapter.submit({ action: 'play', card: 'wd4', wild_color: 'yellow', double_play: true },
                             decision_id: request.decision_id)
    assert_equal 'pl wd4ywd4y', result.command
  end

  def test_human_request_masks_every_variant_an_encoder_cannot_emit
    requests = []
    adapter = UnobotV2::Human::Adapter.new(
      channel: CHANNEL, own_nick: 'Alice', host_nicks: [HOST],
      transport: ->(_channel, _command) {}, encoder: NoDoubleEncoder.new,
      on_request: ->(request) { requests << request }
    )
    adapter.receive(event(status(players: 'Alice:3,Bob:2'), private: true, recipient: 'Alice'))
    adapter.receive(event('UNO_STATUS_PRIVATE_V1 picked_card=-', private: true, recipient: 'Alice'))
    reduction = adapter.receive(event("#{RED_5} #{RED_5} #{WD4}", private: true, recipient: 'Alice'))

    assert_equal requests.last, reduction.request
    assert_equal ['wd4'], reduction.request.playable_cards
    assert_equal %w[play draw], reduction.request.available_actions
    assert_equal true, reduction.request.metadata[:human_action_masked]
    assert_equal ['r5'], reduction.request.metadata[:human_masked_cards]
  end

  def test_human_adapter_resynchronizes_without_invoking_strategy_when_mask_is_empty
    sent = []
    requests = []
    adapter = UnobotV2::Human::Adapter.new(
      channel: CHANNEL, own_nick: 'Alice', host_nicks: [HOST],
      transport: ->(channel, command) { sent << [channel, command] },
      encoder: RejectAllEncoder.new, on_request: ->(request) { requests << request }
    )
    adapter.receive(event(status(players: 'Alice:1,Bob:2'), private: true, recipient: 'Alice'))
    adapter.receive(event('UNO_STATUS_PRIVATE_V1 picked_card=-', private: true, recipient: 'Alice'))
    reduction = adapter.receive(event(RED_5, private: true, recipient: 'Alice'))

    assert_empty requests
    assert_nil reduction.request
    assert_equal 'no_encodable_action', reduction.reason
    assert_equal :no_encodable_action, adapter.last_error
    assert_includes sent, [CHANNEL, 'us']
    assert_includes sent, [CHANNEL, 'ca']
    refute adapter.reducer.safe?
  end

  def test_post_draw_only_picked_card_then_pass
    request = synchronize(hand: "#{GREEN_3} #{RED_5}", picked: 1, players: 'Alice:2,Bob:2')
    assert_equal ['r5'], request.playable_cards
    assert_equal %w[play pass], request.available_actions
    assert_equal 'pa', @adapter.submit({ action: 'pass' }, decision_id: request.decision_id).command
  end

  def test_war_actions_and_penalty_pass
    request = synchronize(hand: "#{RED_PLUS_2} \x034[R] #{WD4} #{GREEN_3}", top: 'r+2',
                          mode: 'war_+2', stacked: 4, players: 'Alice:4,Bob:2')
    assert_equal %w[r+2 rr wd4], request.playable_cards
    assert_equal %w[play pass], request.available_actions

    request = synchronize(hand: "#{WD4} \x033[R] #{RED_PLUS_2}", top: 'wd4g',
                          mode: 'war_wd4', stacked: 8, players: 'Alice:3,Bob:2')
    assert_equal %w[wd4 gr], request.playable_cards
    assert_equal 'pa', @adapter.submit({ action: 'pass' }, decision_id: request.decision_id).command
  end

  def test_continuous_real_transcript_draw_pass_and_private_draw
    @adapter.receive(event("Ok, created \x02\x0304U\x0309N\x0312O\x0308!\x0f game on #{CHANNEL}, say 'jo' to join in"))
    @adapter.receive(event('Alice joins the game'))
    @adapter.receive(event('Bob joins the game'))
    @adapter.receive(event('Card count: Alice 2, Bob 2'))
    @adapter.receive(event("#{RED_5} #{GREEN_3}", private: true, recipient: 'Alice'))
    @adapter.receive(event("Alice's turn. Top card: #{RED_7}"))
    assert_equal %w[r5], @requests.last.playable_cards

    @adapter.receive(event('Alice draws a card.'))
    refute @adapter.reducer.safe?
    @adapter.receive(event("You draw 1 card: #{WILD}", private: true, recipient: 'Alice'))
    assert @adapter.reducer.safe?
    assert_equal ['w'], @requests.last.playable_cards
    @adapter.receive(event("Alice passes. Bob's turn. Top card: #{RED_7}"))
    refute @adapter.reducer.safe?
  end

  def test_real_deal_start_without_card_count_fails_closed_and_requests_snapshot
    @adapter.receive(event("Ok, created \x02\x0304U\x0309N\x0312O\x0308!\x0f game on #{CHANNEL}, say 'jo' to join in"))
    @adapter.receive(event('Alice joins the game'))
    @adapter.receive(event('Bob joins the game'))
    @adapter.receive(event("#{RED_5} #{GREEN_3}", private: true, recipient: 'Alice'))

    reduction = @adapter.receive(event("Alice's turn. Top card: #{RED_7}"))

    assert_nil reduction.request
    refute @adapter.reducer.safe?
    assert_includes @adapter.reducer.unsafe_reasons, 'no_complete_state'
    assert_equal [[CHANNEL, 'us'], [CHANNEL, 'ca']], @sent.last(2)

    request = synchronize(hand: "#{RED_5} #{GREEN_3}", players: 'Alice:2,Bob:7')
    assert_equal 7, request.other_players.first.card_count
  end

  def test_real_transcript_fixture_replays_in_scope_order
    fixture_path = File.expand_path('fixtures/human_protocol_v1/transcripts.json', __dir__)
    events = JSON.parse(File.read(fixture_path)).fetch('normal_start_draw_pass')
    events.each do |entry|
      @adapter.receive(event(entry.fetch('text'), private: entry['scope'] == 'private',
                             recipient: entry['recipient']))
    end
    assert_equal 'active', @adapter.reducer.phase
    refute @adapter.reducer.safe?, 'fixture ends on the opponent turn'
  end

  def test_reverse_skip_double_wd4_and_war_pass_transitions
    synchronize(current: 'Bob', players: 'Bob:2,Carol:2,Alice:3', top: 'b7')
    @adapter.receive(event('Player order reversed!'))
    request = @adapter.receive(event("Alice's turn. Top card: \x0312[R]")).request
    assert_equal %w[Carol Bob], request.other_players.map(&:id)
    assert_equal 1, request.other_players.last.card_count

    setup
    synchronize(current: 'Bob', players: 'Bob:3,Alice:3,Carol:2', top: 'b7')
    @adapter.receive(event('[Playing two cards]'))
    @adapter.receive(event('Player order reversed twice!'))
    reduction = @adapter.receive(event("Bob's turn. Top card: \x0312[R]"))
    assert_nil reduction.request
    assert_empty @adapter.reducer.unsafe_reasons

    setup
    synchronize(current: 'Bob', players: 'Bob:2,Alice:3,Carol:2', top: 'b7')
    @adapter.receive(event('[Playing two cards]'))
    request = @adapter.receive(event("Alice's turn. Top card: \x0312[5]")).request
    assert_equal 0, request.other_players.find { |player| player.id == 'Bob' }.card_count

    setup
    synchronize(current: 'Bob', players: 'Bob:2,Alice:3,Carol:2', top: 'b7')
    reduction = @adapter.receive(event("Carol's turn. Top card: \x0312[S]"))
    assert_nil reduction.request
    assert_empty @adapter.reducer.unsafe_reasons

    setup
    synchronize(current: 'Bob', players: 'Bob:2,Alice:3', top: 'r+2', mode: 'war_+2', stacked: 4)
    request = @adapter.receive(event("Bob passes. Alice's turn. Top card: #{RED_PLUS_2}")).request
    assert_equal 'normal', request.game_state
    assert_equal 0, request.stacked_cards
    assert_equal 6, request.other_players.first.card_count

    setup
    synchronize(current: 'Bob', players: 'Bob:2,Alice:3')
    @adapter.receive(event('[Playing two cards]'))
    request = @adapter.receive(event("Alice's turn. Top card: \x034[WD4]")).request
    assert_equal 'war_wd4', request.game_state
    assert_equal 8, request.stacked_cards
  end

  def test_order_and_low_card_announcements_are_checked_at_the_play_boundary
    synchronize(current: 'Bob', players: 'Bob:4,Alice:3,Carol:2')
    @adapter.receive(event('Current order: Bob Alice Carol'))
    @adapter.receive(event("Bob has only \x02\x037three\x03\x02 cards left!"))
    request = @adapter.receive(event("Alice's turn. Top card: #{RED_5}")).request
    assert request
    assert_equal 3, request.other_players.find { |player| player.id == 'Bob' }.card_count

    setup
    synchronize(current: 'Bob', players: 'Bob:4,Alice:3,Carol:2')
    @adapter.receive(event("Bob has only \x02\x037three\x03\x02 cards left!"))
    @adapter.receive(event('[Playing two cards]'))
    reduction = @adapter.receive(event("Alice's turn. Top card: #{RED_5}"))
    assert_nil reduction.request
    assert_equal 'inconsistent player count', reduction.reason
    assert_equal [[CHANNEL, 'us'], [CHANNEL, 'ca']], @sent.last(2)
  end

  def test_same_current_skip_reverse_and_double_transitions_apply_each_play_once
    synchronize(current: 'Bob', players: 'Bob:2,Alice:3', top: 'b7')
    first = @adapter.receive(event("Bob's turn. Top card: \x0312[S]"))
    assert_nil first.request
    assert_empty @adapter.reducer.unsafe_reasons
    request = @adapter.receive(event("Alice's turn. Top card: \x0312[5]")).request
    assert_equal 0, request.other_players.find { |player| player.id == 'Bob' }.card_count

    setup
    synchronize(hand: "\x0312[5] #{GREEN_3} #{WD4}",
                current: 'Bob', players: 'Bob:2,Alice:3', top: 'b7')
    request = @adapter.receive(event("Alice's turn. Top card: \x0312[R]")).request
    assert_equal 1, request.other_players.find { |player| player.id == 'Bob' }.card_count
    reduction = @adapter.receive(event("Bob's turn. Top card: \x0312[5]"))
    assert_nil reduction.request
    assert_empty @adapter.reducer.unsafe_reasons

    setup
    synchronize(current: 'Bob', players: 'Bob:3,Alice:3,Carol:2', top: 'b7')
    @adapter.receive(event('[Playing two cards]'))
    @adapter.receive(event("Bob's turn. Top card: \x0312[S]"))
    request = @adapter.receive(event("Alice's turn. Top card: \x0312[5]")).request
    assert_equal 0, request.other_players.find { |player| player.id == 'Bob' }.card_count

    setup
    synchronize(current: 'Bob', players: 'Bob:3,Alice:3', top: 'b7')
    @adapter.receive(event('[Playing two cards]'))
    reduction = @adapter.receive(event("Bob's turn. Top card: \x0312[R]"))
    assert_nil reduction.request
    assert_empty @adapter.reducer.unsafe_reasons
    request = @adapter.receive(event("Alice's turn. Top card: \x0312[5]")).request
    assert_equal 0, request.other_players.find { |player| player.id == 'Bob' }.card_count
  end

  def test_skip_announcement_disambiguates_identical_status_anchored_turn
    synchronize(current: 'Bob', players: 'Bob:2,Alice:3', top: 'bs')
    @adapter.receive(event('Alice was skipped!'))
    @adapter.receive(event("Bob's turn. Top card: \x0312[S]"))
    counts = @adapter.reducer.instance_variable_get(:@counts)
    assert_equal 1, counts.fetch('Bob')

    # A repeated turn line without another effect announcement remains a duplicate.
    @adapter.receive(event("Bob's turn. Top card: \x0312[S]"))
    assert_equal 1, counts.fetch('Bob')

    # Repeating the whole pair is indistinguishable from another identical skip.
    @adapter.receive(event('Alice was skipped!'))
    reduction = @adapter.receive(event("Bob's turn. Top card: \x0312[S]"))
    assert_equal 'ambiguous repeated play effect', reduction.reason
    assert_equal 1, counts.fetch('Bob'), 'ambiguous pair must not decrement twice'
    refute @adapter.reducer.safe?
    assert_equal [[CHANNEL, 'us'], [CHANNEL, 'ca']], @sent.last(2)
    assert_empty @requests

    request = synchronize(top: 'b5', players: 'Alice:3,Bob:1')
    assert request
    assert_equal 1, request.other_players.first.card_count

    setup
    synchronize(current: 'Bob', players: 'Bob:2,Alice:3', top: 'bs')
    @adapter.receive(event("Bob's turn. Top card: \x0312[S]"))
    @adapter.receive(event("Bob's turn. Top card: \x0312[S]"))
    counts = @adapter.reducer.instance_variable_get(:@counts)
    assert_equal 2, counts.fetch('Bob'), 'unaccompanied repeated snapshot turn is deduplicated'

    setup
    synchronize(current: 'Bob', players: 'Bob:3,Alice:3', top: 'bs')
    @adapter.receive(event('Alice was skipped!'))
    @adapter.receive(event("Bob's turn. Top card: \x0312[S]"))
    request = @adapter.receive(event("Alice's turn. Top card: \x0312[5]")).request
    assert_equal 1, request.other_players.first.card_count, 'a distinct next play remains observable'
  end

  def test_submitted_same_top_skip_is_not_mistaken_for_a_status_duplicate
    request = synchronize(hand: "\x0312[S] #{RED_5}", top: 'bs', players: 'Alice:2,Bob:2')
    result = @adapter.submit({ action: 'play', card: 'bs' }, decision_id: request.decision_id)
    assert_predicate result, :success?
    next_request = @adapter.receive(event("Alice's turn. Top card: \x0312[S]")).request
    assert_equal ['r5'], next_request.hand
    assert_equal 1, next_request.state_h[:hand].length
  end

  def test_draw_correlation_rejects_duplicates_missing_public_and_out_of_turn
    synchronize(hand: "#{RED_5} #{GREEN_3}", players: 'Alice:2,Bob:2')
    @adapter.receive(event('Alice draws a card.'))
    reduction = @adapter.receive(event('Alice draws a card.'))
    assert_equal 'duplicate public draw', reduction.reason
    assert_equal [[CHANNEL, 'us'], [CHANNEL, 'ca']], @sent.last(2)

    setup
    synchronize(hand: "#{RED_5} #{GREEN_3}", players: 'Alice:2,Bob:2')
    @adapter.receive(event('Alice draws a card.'))
    @adapter.receive(event("You draw 1 card: #{WILD}", private: true, recipient: 'Alice'))
    assert_equal true, @adapter.reducer.safe?
    reduction = @adapter.receive(event("You draw 1 card: #{WILD}", private: true, recipient: 'Alice'))
    assert_equal 'duplicate private draw', reduction.reason
    refute @adapter.reducer.safe?

    setup
    synchronize(hand: "#{RED_5} #{GREEN_3}", players: 'Alice:2,Bob:2')
    reduction = @adapter.receive(event("You draw 1 card: #{WILD}", private: true, recipient: 'Alice'))
    assert_equal 'unexpected private draw', reduction.reason
    refute @adapter.reducer.safe?

    setup
    synchronize(current: 'Bob', hand: "#{RED_5} #{GREEN_3}", players: 'Bob:2,Alice:2')
    reduction = @adapter.receive(event('Alice draws a card.'))
    assert_equal 'out of turn draw', reduction.reason
    @adapter.receive(event('Bob draws a card.'))
    reduction = @adapter.receive(event('Bob draws a card.'))
    assert_equal 'duplicate public draw', reduction.reason
  end

  def test_war_draw_paths_are_correlated_without_public_single_draws
    synchronize(top: 'r+2', mode: 'war_+2', stacked: 4, players: 'Alice:2,Bob:2',
                hand: "#{RED_5} #{GREEN_3}")
    reduction = @adapter.receive(event('Alice draws a card.'))
    assert_equal 'draw during war', reduction.reason

    setup
    synchronize(top: 'r+2', mode: 'war_+2', stacked: 4, players: 'Alice:2,Bob:2',
                hand: "#{RED_5} #{GREEN_3}")
    @adapter.receive(event("You draw 4 cards: \x0312[1] \x0312[2] \x033[4] \x037[6]",
                           private: true, recipient: 'Alice'))
    reduction = @adapter.receive(event("You draw 4 cards: \x0312[1] \x0312[2] \x033[4] \x037[6]",
                                       private: true, recipient: 'Alice'))
    assert_equal 'duplicate private draw', reduction.reason
  end

  def test_unobserved_normal_pass_and_illegal_post_draw_play_force_resync
    synchronize(current: 'Bob', players: 'Bob:2,Alice:3')
    reduction = @adapter.receive(event("Bob passes. Alice's turn. Top card: #{RED_7}"))
    assert_equal 'unexpected pass', reduction.reason

    setup
    synchronize(hand: "#{RED_5} #{GREEN_3}", players: 'Alice:2,Bob:2')
    @adapter.receive(event('Alice draws a card.'))
    @adapter.receive(event("You draw 1 card: #{WILD}", private: true, recipient: 'Alice'))
    reduction = @adapter.receive(event("Bob's turn. Top card: #{RED_5}"))
    assert_equal 'illegal post draw play', reduction.reason
    assert_equal [[CHANNEL, 'us'], [CHANNEL, 'ca']], @sent.last(2)
  end

  def test_impossible_observed_plays_and_malformed_status_players_force_resync
    synchronize(current: 'Bob', players: 'Bob:2,Alice:3', top: 'wd4g', mode: 'war_wd4', stacked: 8)
    reduction = @adapter.receive(event("Alice's turn. Top card: \x033[+2]"))
    assert_equal 'illegal observed play', reduction.reason
    assert_equal [[CHANNEL, 'us'], [CHANNEL, 'ca']], @sent.last(2)

    ['Alice:3,bad,Bob:2', 'Alice:3,Alice:2'].each do |players|
      setup
      reduction = @adapter.receive(event(status(players: players), private: true, recipient: 'Alice'))
      assert_equal 'malformed status', reduction.reason
      refute @adapter.reducer.safe?
    end
  end

  def test_malformed_strategy_actions_are_structured_refusals
    request = synchronize
    [nil, [], { action: 'draw', double_play: 'false' }, { action: 'draw', extra: true }].each do |action|
      result = @adapter.submit(action, decision_id: request.decision_id)
      assert_predicate result, :error?
      assert_equal :invalid_action, result.code
    end
  end

  def test_strategy_exception_fails_closed_and_requests_fresh_human_snapshot
    sent = []
    adapter = UnobotV2::Human::Adapter.new(
      channel: CHANNEL, own_nick: 'Alice', host_nicks: [HOST],
      transport: ->(channel, command) { sent << [channel, command] },
      on_request: ->(_request) { raise 'human strategy boom' }
    )
    adapter.receive(event(status, private: true, recipient: 'Alice'))
    adapter.receive(event('UNO_STATUS_PRIVATE_V1 picked_card=-', private: true, recipient: 'Alice'))
    reduction = adapter.receive(event("#{RED_5} #{GREEN_3} #{WD4}", private: true, recipient: 'Alice'))

    assert_equal 'strategy_error: human strategy boom', reduction.reason
    assert_equal :strategy_error, adapter.last_error
    assert_equal 'human strategy boom', adapter.callback_errors.pop.message
    refute adapter.reducer.safe?
    assert_equal [[CHANNEL, 'us'], [CHANNEL, 'ca']], sent.last(2)
    result = adapter.submit({ action: 'draw' }, decision_id: 'stale')
    assert_equal :stale_decision, result.code
  end

  def test_inconsistent_out_of_order_turn_refuses_and_resynchronizes
    synchronize(current: 'Bob', players: 'Bob:2,Alice:3,Carol:2')
    reduction = @adapter.receive(event("Carol's turn. Top card: #{RED_5}"))
    assert_nil reduction.request
    assert_equal 'inconsistent turn order', reduction.reason
    assert_equal [[CHANNEL, 'us'], [CHANNEL, 'ca']], @sent.last(2)
    refute @adapter.reducer.safe?
  end

  def test_own_war_penalty_waits_for_pass_and_reconnect_requires_snapshot
    synchronize(top: 'r+2', mode: 'war_+2', stacked: 4, players: 'Alice:2,Bob:2',
                hand: "#{RED_5} #{GREEN_3}")
    @adapter.receive(event("You draw 4 cards: \x0312[1] \x0312[2] \x033[4] \x037[6]",
                           private: true, recipient: 'Alice'))
    refute @adapter.reducer.safe?
    request = @adapter.receive(event("Alice passes. Bob's turn. Top card: #{RED_PLUS_2}")).request
    assert_nil request
    assert_empty @adapter.reducer.unsafe_reasons

    before = @sent.length
    @adapter.receive(event('', kind: :disconnect))
    assert_equal before, @sent.length
    @adapter.receive(event('', kind: :reconnect))
    assert_equal [[CHANNEL, 'us'], [CHANNEL, 'ca']], @sent.slice(before, 2)
    refute @adapter.reducer.safe?
  end

  def test_missing_own_private_war_penalty_cannot_become_safe_next_round
    synchronize(top: 'r+2', mode: 'war_+2', stacked: 4, players: 'Alice:2,Bob:2',
                hand: "#{RED_5} #{GREEN_3}")
    before = @requests.length
    reduction = @adapter.receive(event("Alice passes. Bob's turn. Top card: #{RED_PLUS_2}"))
    assert_equal 'missing private war penalty', reduction.reason
    assert_equal [[CHANNEL, 'us'], [CHANNEL, 'ca']], @sent.last(2)
    assert_equal 2, @adapter.reducer.instance_variable_get(:@counts).fetch('Alice')
    refute @adapter.reducer.safe?

    # A later public turn cannot bless the stale two-card hand.
    @adapter.receive(event("Alice's turn. Top card: #{RED_5}"))
    assert_equal before, @requests.length
    refute @adapter.reducer.safe?

    fresh_hand = "#{RED_5} #{GREEN_3} \x0312[1] \x0312[2] \x033[4] \x037[6]"
    request = synchronize(top: 'r5', mode: 'normal', stacked: 0,
                          players: 'Alice:6,Bob:1', hand: fresh_hand)
    assert_equal 6, request.hand.length
    assert_equal before + 1, @requests.length
    assert @adapter.reducer.safe?
  end

  def test_observed_and_resynchronized_states_are_differentially_equal
    @adapter.receive(event('Alice joins the game'))
    @adapter.receive(event('Bob joins the game'))
    @adapter.receive(event('Card count: Alice 3, Bob 2'))
    @adapter.receive(event("#{RED_5} #{GREEN_3} #{WD4}", private: true, recipient: 'Alice'))
    observed = @adapter.receive(event("Alice's turn. Top card: #{RED_7}")).request

    other = self.class.new('test_status_hand_resync_action_encoding_and_deduplication')
    other.setup
    resynced = other.synchronize(players: 'Alice:3,Bob:2')
    assert_equal observed.state_h, resynced.state_h
  end

  def test_disconnect_malformed_duplicate_privacy_nick_and_game_end
    request = synchronize(players: 'Alice:3,Bob:2')
    @adapter.receive(event("Alice's turn. Top card: #{RED_7}"))
    assert_equal 1, @requests.length

    @adapter.receive(event("Alice's turn. Top card: broken"))
    refute @adapter.reducer.safe?
    assert_equal [[CHANNEL, 'us'], [CHANNEL, 'ca']], @sent.last(2)
    stale = @adapter.submit({ action: 'draw' }, decision_id: request.decision_id)
    assert_equal :unsafe_state, stale.code

    @adapter.receive(event("#{RED_5}", private: true, recipient: 'Bob'))
    refute @adapter.reducer.safe?, 'another player private hand must be ignored'
    @adapter.receive(event('', kind: :nick, old_nick: 'Alice', new_nick: 'Alice_'))
    assert_equal 'Alice_', @adapter.reducer.own_nick
    @adapter.receive(event('Bob gains 30 points.'))
    assert_equal 'ended', @adapter.reducer.phase
  end

  def test_multiple_channels_and_non_host_messages_are_isolated
    synchronize
    before = @requests.length
    @adapter.receive(event("Mallory's turn. Top card: #{GREEN_3}", source: 'Mallory'))
    @adapter.receive(event("Mallory's turn. Top card: #{GREEN_3}", channel: '#other'))
    assert_equal before, @requests.length
  end
end

class UnobotV2SeparationAndQueueTest < Minitest::Test
  def test_strategy_receives_canonical_state_not_transport
    fixture = JSON.parse(File.read(Dir[UnobotV2CanonicalTest::FIXTURES].first))
    request = UnobotV2::Canonical::DecisionRequest.from_protocol(fixture)
    seen = nil
    strategy = UnobotV2::LegacyStrategyAdapter.new do |canonical|
      seen = canonical
      { action: canonical.available_actions.last }
    end
    assert_instance_of UnobotV2::Canonical::Action, strategy.decide(request)
    assert_same request, seen
  end

  def test_ordered_consumer_isolates_errors_and_restarts
    seen = Queue.new
    errors = Queue.new
    consumer = UnobotV2::OrderedConsumer.new(on_error: ->(error, _event) { errors << error }) do |value|
      raise 'boom' if value == 2
      seen << value
    end
    consumer.start
    [1, 2, 3].each { |value| assert consumer.push(value) }
    consumer.stop
    assert_equal [1, 3], [seen.pop, seen.pop]
    assert_equal 'boom', errors.pop.message
    assert_same consumer, consumer.restart
    consumer.stop
  end

  def test_ordered_consumer_has_a_nonblocking_capacity_boundary
    seen = Queue.new
    consumer = UnobotV2::OrderedConsumer.new(capacity: 1) { |value| seen << value }
    assert consumer.push(:first)
    refute consumer.push(:overflow)
    consumer.start.stop
    assert_equal :first, seen.pop
  end

  def test_session_manager_keeps_channel_adapters_separate
    received = Queue.new
    fake_class = Struct.new(:channel, :received) do
      def receive(event) = received << [channel, event.text]
      def resync!(*_args) = nil
    end
    manager = UnobotV2::SessionManager.new(
      adapter_factory: ->(channel) { fake_class.new(channel, received) }
    ).start
    manager.enqueue(UnobotV2::Human::Event.new(channel: '#One', source: 'host', text: 'a'))
    manager.enqueue(UnobotV2::Human::Event.new(channel: '#Two', source: 'host', text: 'b'))
    manager.stop
    assert_equal [['#one', 'a'], ['#two', 'b']], [received.pop, received.pop]
  end

  def test_session_overflow_is_serialized_and_discards_stale_backlog
    started = Queue.new
    release = Queue.new
    callbacks = Queue.new
    producer = Thread.current
    fake_class = Class.new do
      attr_writer :lifecycle_token, :token_validator

      define_method(:initialize) do
        @started = started
        @release = release
        @callbacks = callbacks
      end
      define_method(:receive) do |event|
        @callbacks << [:receive, event.text, Thread.current]
        if event.text == 'block'
          @started << true
          @release.pop
        end
      end
      define_method(:resync!) do |reason|
        @callbacks << [:transport, reason, Thread.current]
      end
    end
    adapter = fake_class.new
    manager = UnobotV2::SessionManager.new(adapter_factory: ->(_channel) { adapter }, queue_capacity: 1).start

    assert manager.enqueue(UnobotV2::Human::Event.new(channel: '#one', text: 'block'))
    started.pop
    assert manager.enqueue(UnobotV2::Human::Event.new(channel: '#one', text: 'stale'))
    refute manager.enqueue(UnobotV2::Human::Event.new(channel: '#one', text: 'overflow'))
    release << true
    manager.stop

    records = []
    records << callbacks.pop until callbacks.empty?
    assert_equal %i[receive transport], records.map(&:first)
    refute_includes records.map { |record| record[1] }, 'stale'
    records.each { |record| refute_same producer, record[2] }
  end

  def test_human_overflow_invalidates_stale_decisions_until_fresh_snapshot_boundary
    started = Queue.new
    release = Queue.new
    processed = Queue.new
    requests = Queue.new
    transport = Queue.new
    human = UnobotV2::Human::Adapter.new(
      channel: '#one', own_nick: 'Alice', host_nicks: ['host'],
      transport: ->(_channel, command) { transport << [command, Thread.current] },
      on_request: ->(request) { requests << [request, Thread.current] }
    )
    wrapper = Class.new do
      define_method(:initialize) do |delegate, started_queue, release_queue, processed_queue|
        @delegate = delegate
        @started = started_queue
        @release = release_queue
        @processed = processed_queue
      end
      define_method(:lifecycle_token=) { |token| @delegate.lifecycle_token = token }
      define_method(:token_validator=) { |validator| @delegate.token_validator = validator }
      define_method(:receive) do |event|
        if event.kind == :block
          @started << true
          @release.pop
        end
        @delegate.receive(event)
        @processed << event.text
      end
      define_method(:resync!) { |reason| @delegate.resync!(reason) }
    end.new(human, started, release, processed)
    manager = UnobotV2::SessionManager.new(adapter_factory: ->(_channel) { wrapper }, queue_capacity: 1).start
    producer = Thread.current
    make_event = lambda do |text, private_message = false|
      UnobotV2::Human::Event.new(channel: '#one', source: 'host', text: text,
                                 private: private_message, recipient: 'Alice')
    end

    # Establish coherent opponent-turn state without an actionable request.
    manager.enqueue(make_event.call('UNO_STATUS_V1 phase=active current=Bob top=r7 mode=normal stacked_cards=0 already_picked=0 players=Bob:2,Alice:2', true))
    processed.pop
    manager.enqueue(make_event.call("\x034[5] \x033[3]", true))
    processed.pop

    blocking_turn = UnobotV2::Human::Event.new(
      channel: '#one', source: 'host', text: "Alice's turn. Top card: \x034[5]", kind: :block
    )
    manager.enqueue(blocking_turn)
    started.pop
    manager.enqueue(make_event.call("Alice's turn. Top card: \x034[6]"))
    refute manager.enqueue(make_event.call('overflow'))
    release << true
    processed.pop
    until transport.size >= 2
      Thread.pass
    end
    assert requests.empty?, 'stale queued turn must not emit a request after overflow'
    assert_equal %w[us ca], [transport.pop.first, transport.pop.first]

    # Only a fresh status/private/hand boundary in the new epoch restores it.
    fresh = [
      ['UNO_STATUS_V1 phase=active current=Alice top=r7 mode=normal stacked_cards=0 already_picked=0 players=Alice:2,Bob:2', true],
      ['UNO_STATUS_PRIVATE_V1 picked_card=-', true],
      ["\x034[5] \x033[3]", true]
    ]
    fresh.each do |text, private_message|
      manager.enqueue(make_event.call(text, private_message))
      processed.pop
    end
    request, callback_thread = requests.pop
    assert_predicate request, :safe?
    refute_same producer, callback_thread
    manager.stop
  end
end
