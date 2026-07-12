# frozen_string_literal: true

require 'bundler/setup'
require 'cinch'
require 'json'
require 'minitest/autorun'
require 'monitor'
require 'sequel'

UNOBOT_ROOT = File.expand_path('../..', __dir__)
HOST_ROOT = ENV.fetch('UNO_STAGE7_HOST_ROOT', File.expand_path('../ZbojeiJureq', UNOBOT_ROOT))

$LOAD_PATH.unshift(File.join(UNOBOT_ROOT, 'lib'))
require 'unobot_v2'

STAGE7_UNO_DB = Sequel.sqlite
STAGE7_UNO_DB.create_table(:games) { primary_key :ID; String :start; String :created_by }
STAGE7_UNO_DB.create_table(:turn) { primary_key :ID }
STAGE7_UNO_DB.create_table(:player_action) { primary_key :ID }
STAGE7_UNO_DB.create_table(:uno) { String :nick, primary_key: true }

def sqlite_load(_filename) = STAGE7_UNO_DB

Dir.chdir(HOST_ROOT)
require './plugins/uno_plugin'

class Stage7ActionEquivalenceTest < Minitest::Test
  Scenario = Data.define(
    :name, :hand, :top, :game_state, :stacked, :already_picked,
    :picked_card, :action, :expected_command
  )

  SCENARIOS = [
    Scenario.new(name: 'normal play', hand: %w[r5 g3 b8], top: 'r7', game_state: 1,
                 stacked: 0, already_picked: false, picked_card: nil,
                 action: { action: 'play', card: 'r5' }, expected_command: 'pl r5'),
    Scenario.new(name: 'draw', hand: %w[g3 b8 r9], top: 'r7', game_state: 1,
                 stacked: 0, already_picked: false, picked_card: nil,
                 action: { action: 'draw' }, expected_command: 'pe'),
    Scenario.new(name: 'post-draw play', hand: %w[r5 g3 b8], top: 'r7', game_state: 1,
                 stacked: 0, already_picked: true, picked_card: 'r5',
                 action: { action: 'play', card: 'r5' }, expected_command: 'pl r5'),
    Scenario.new(name: 'post-draw pass', hand: %w[b5 g3 r9], top: 'r7', game_state: 1,
                 stacked: 0, already_picked: true, picked_card: 'b5',
                 action: { action: 'pass' }, expected_command: 'pa'),
    Scenario.new(name: 'wild color', hand: %w[w g3 b8], top: 'r7', game_state: 1,
                 stacked: 0, already_picked: false, picked_card: nil,
                 action: { action: 'play', card: 'w', wild_color: 'green' }, expected_command: 'pl wg'),
    Scenario.new(name: 'ordinary double', hand: %w[r5 r5 g3 b8], top: 'r7', game_state: 1,
                 stacked: 0, already_picked: false, picked_card: nil,
                 action: { action: 'play', card: 'r5', double_play: true }, expected_command: 'pl r5r5'),
    Scenario.new(name: 'double WD4', hand: %w[wd4 wd4 g3 b8], top: 'r7', game_state: 1,
                 stacked: 0, already_picked: false, picked_card: nil,
                 action: { action: 'play', card: 'wd4', wild_color: 'red', double_play: true },
                 expected_command: 'pl wd4rwd4r'),
    Scenario.new(name: '+2 war response', hand: %w[r+2 g3 b8], top: 'r+2', game_state: 2,
                 stacked: 4, already_picked: false, picked_card: nil,
                 action: { action: 'play', card: 'r+2' }, expected_command: 'pl r+2'),
    Scenario.new(name: '+2 war penalty', hand: %w[g3 b8 r9], top: 'r+2', game_state: 2,
                 stacked: 4, already_picked: false, picked_card: nil,
                 action: { action: 'pass' }, expected_command: 'pa'),
    Scenario.new(name: 'WD4 war reverse response', hand: %w[gr g3 b8], top: 'wd4g', game_state: 3,
                 stacked: 8, already_picked: false, picked_card: nil,
                 action: { action: 'play', card: 'gr' }, expected_command: 'pl gr'),
    Scenario.new(name: 'WD4 war penalty', hand: %w[g3 b8 r9], top: 'wd4g', game_state: 3,
                 stacked: 8, already_picked: false, picked_card: nil,
                 action: { action: 'pass' }, expected_command: 'pa'),
    Scenario.new(name: 'single reverse', hand: %w[br g3 b8], top: 'b7', game_state: 1,
                 stacked: 0, already_picked: false, picked_card: nil,
                 action: { action: 'play', card: 'br' }, expected_command: 'pl br'),
    Scenario.new(name: 'double reverse', hand: %w[br br g3 b8], top: 'b7', game_state: 1,
                 stacked: 0, already_picked: false, picked_card: nil,
                 action: { action: 'play', card: 'br', double_play: true }, expected_command: 'pl brbr'),
    Scenario.new(name: 'single skip', hand: %w[bs g3 b8], top: 'b7', game_state: 1,
                 stacked: 0, already_picked: false, picked_card: nil,
                 action: { action: 'play', card: 'bs' }, expected_command: 'pl bs'),
    Scenario.new(name: 'double skip', hand: %w[bs bs g3 b8], top: 'b7', game_state: 1,
                 stacked: 0, already_picked: false, picked_card: nil,
                 action: { action: 'play', card: 'bs', double_play: true }, expected_command: 'pl bsbs')
  ].freeze

  Channel = Struct.new(:name) do
    def to_s = name
  end
  User = Struct.new(:nick)
  Message = Struct.new(:user, :channel, :message, :replies) do
    def reply(text) = replies << text
  end

  class RecordingNotifier
    attr_reader :game_messages, :player_messages, :errors

    def initialize
      @game_messages = []
      @player_messages = []
      @errors = []
    end

    def notify_game(message) = game_messages << message
    def notify_player(player, message) = player_messages << [player.to_s, message]
    def notify_error(player, message) = errors << [player.to_s, message]
    def debug(*) = nil
  end

  SCENARIOS.each do |scenario|
    define_method("test_#{scenario.name.gsub(/[^a-z0-9]+/i, '_')}") do
      assert_equivalent(scenario)
    end
  end

  def test_structured_executor_failure_and_human_rejection_leave_identical_state
    reference, = build_game(hand: %w[b9 g3 r5], top: 'r7')
    human, notifier = build_game(hand: %w[b9 g3 r5], top: 'r7')
    before = serialize(reference)

    result = Jedna::ActionExecutor.new(reference).execute(
      { action: 'play', card: 'b9' }, player: reference.players.first
    )
    refute_predicate result, :success?
    assert_equal 'card_not_playable', result.code
    assert_equal 'play', result.action

    dispatch_human(human, 'pl b9')
    assert_empty notifier.errors
    assert_includes notifier.game_messages, "Sorry Bot, that card doesn't play."
    assert_equal before, serialize(reference)
    assert_equal before, serialize(human)
  end

  private

  def assert_equivalent(scenario)
    reference, = build_game(**scenario.to_h.slice(
      :hand, :top, :game_state, :stacked, :already_picked, :picked_card
    ))
    human, notifier = build_game(**scenario.to_h.slice(
      :hand, :top, :game_state, :stacked, :already_picked, :picked_card
    ))
    request = UnobotV2::Canonical::DecisionRequest.from_protocol(
      Jedna::GameStateSerializer.new.serialize_for_current_player(reference),
      metadata: { channel: '#stage7-equivalence', transport: 'machine', game_id: 'g1', decision_id: 'd1' }
    )
    canonical = UnobotV2::Canonical::Action.from(scenario.action)
    encoded = UnobotV2::Human::ActionEncoder.new.encode(canonical, request: request)
    assert_predicate encoded, :success?
    assert_equal scenario.expected_command, encoded.command

    result = Jedna::ActionExecutor.new(reference).execute(
      canonical.to_h, player: reference.players.first
    )
    assert_predicate result, :success?
    assert_equal 'ok', result.code
    assert_equal canonical.action, result.action

    dispatch_human(human, encoded.command)
    assert_empty notifier.errors
    refute notifier.game_messages.any? { |message| message.match?(/\A(?:Sorry |It's not|You have to)/) }
    assert_equal serialize(reference), serialize(human)
  end

  def build_game(hand:, top:, game_state: 1, stacked: 0,
                 already_picked: false, picked_card: nil, **)
    game = IrcUnoGame.new('Bot', 1)
    notifier = RecordingNotifier.new
    game.notifier = notifier
    game.renderer = Jedna::IrcRenderer.new
    players = {
      'Bot' => hand,
      'Human' => %w[y1 y2 y3 y4],
      'Third' => %w[g5 g6 g7 g8]
    }.map do |nick, cards|
      player = Jedna::Player.new(nick)
      player.hand << cards.map { |card| Jedna::Card.parse(card) }
      player
    end
    top_card = Jedna::Card.parse(top)
    game.players.replace(players)
    game.instance_variable_set(:@top_card, top_card)
    game.instance_variable_set(:@game_state, game_state)
    game.instance_variable_set(:@stacked_cards, stacked)
    game.instance_variable_set(:@already_picked, already_picked)
    game.instance_variable_set(:@picked_card, players.first.hand.find_card(picked_card))
    game.instance_variable_set(:@played_cards, Jedna::CardStack.new([top_card]))
    deck = %w[r5 b1 g1 y1 r2 b2 g2 y2 r3 b3 g3 y3 r4 b4 g4 y4 r6 b6 g6 y6]
    game.instance_variable_set(:@card_stack, Jedna::CardStack.new(deck.map { |card| Jedna::Card.parse(card) }))
    [game, notifier]
  end

  def dispatch_human(game, command)
    plugin = UnoPlugin.allocate
    plugin.instance_variable_set(:@games, { '#stage7-equivalence' => game })
    plugin.instance_variable_set(:@game_histories, {})
    plugin.instance_variable_set(:@testing_channels, Hash.new(false))
    plugin.instance_variable_set(:@games_monitor, Monitor.new)
    plugin.instance_variable_set(:@channel_monitors, {})
    message = Message.new(User.new('Bot'), Channel.new('#stage7-equivalence'), command, [])
    case command
    when 'pe' then plugin.pick(message)
    when 'pa' then plugin.pass(message)
    when /\Apl / then plugin.play(message)
    else raise "unroutable human command #{command.inspect}"
    end
  end

  def serialize(game)
    JSON.parse(JSON.generate(Jedna::GameStateSerializer.new.serialize_for_current_player(game)))
  end
end
