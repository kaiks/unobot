# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../lib/unobot_v2'

JEDNA_ROOT = File.expand_path('../../jedna', __dir__)
HOST_ROOT = File.expand_path('../../ZbojeiJureq', __dir__)

if File.file?(File.join(JEDNA_ROOT, 'lib/jedna.rb')) &&
   File.file?(File.join(HOST_ROOT, 'plugins/uno/machine_protocol.rb'))
  $LOAD_PATH.unshift(File.join(JEDNA_ROOT, 'lib'))
  require 'jedna'
  require File.join(HOST_ROOT, 'plugins/uno/machine_protocol')
end

class Stage7EngineDifferentialTest < Minitest::Test
  HOST = 'Host'
  CHANNEL = '#stage7'

  class RecordingNotifier
    attr_reader :events

    def initialize
      @events = []
    end

    def notify_game(message) = events << [:public, nil, message]
    def notify_player(player_id, message) = events << [:private, player_id.to_s, message]
    def notify_error(player_id, message) = events << [:private, player_id.to_s, "Error: #{message}"]
    def debug(*) = nil
  end

  def setup
    skip 'sibling jedna and host checkouts are required for Stage 7 integration' unless defined?(Jedna) && defined?(UnoMachine)
  end

  def test_engine_generated_single_reverse_matches_human_and_machine_state
    game, notifier = reverse_game
    reducer = synchronized_reducer(game, own_nick: 'Carol')

    result = Jedna::ActionExecutor.new(game).execute(
      { action: 'play', card: 'br', double_play: false }, player: game.players.first
    )

    assert_predicate result, :success?
    assert_equal 'Carol', game.players.first.to_s
    assert_includes notifier.events, [:public, nil, 'Player order reversed!']
    assert_differential_parity(game, reducer, notifier.events)
  end

  def test_engine_generated_double_reverse_keeps_current_player_and_matches_both_protocols
    game, notifier = reverse_game
    reducer = synchronized_reducer(game, own_nick: 'Bob')

    result = Jedna::ActionExecutor.new(game).execute(
      { action: 'play', card: 'br', double_play: true }, player: game.players.first
    )

    assert_predicate result, :success?
    assert_equal 'Bob', game.players.first.to_s
    assert_includes notifier.events, [:public, nil, '[Playing two cards]']
    assert_includes notifier.events, [:public, nil, 'Player order reversed twice!']
    assert_differential_parity(game, reducer, notifier.events)
  end

  private

  def reverse_game
    notifier = RecordingNotifier.new
    game = Jedna::Game.new('Bob', 1, notifier, Jedna::IrcRenderer.new, Jedna::NullRepository.new)
    players = {
      'Bob' => %w[br br r5],
      'Alice' => %w[g2 y3],
      'Carol' => %w[b4 gs]
    }.map do |nick, cards|
      player = Jedna::Player.new(nick)
      player.hand << cards.map { |card| Jedna::Card.parse(card) }
      player
    end
    game.instance_variable_set(:@players, players)
    game.instance_variable_set(:@top_card, Jedna::Card.parse('b7'))
    game.instance_variable_set(:@game_state, 1)
    game.instance_variable_set(:@stacked_cards, 0)
    game.instance_variable_set(:@already_picked, false)
    game.instance_variable_set(:@picked_card, nil)
    game.instance_variable_set(:@played_cards, Jedna::CardStack.new([Jedna::Card.parse('b7')]))
    game.instance_variable_set(:@card_stack, Jedna::CardStack.new(%w[r1 g1 y1].map { |card| Jedna::Card.parse(card) }))
    [game, notifier]
  end

  def synchronized_reducer(game, own_nick:)
    reducer = UnobotV2::Human::Reducer.new(channel: CHANNEL, own_nick: own_nick, host_nicks: [HOST])
    reducer.receive(human_event(status_line(game), private: true, recipient: own_nick))
    if game.players.first.matches?(own_nick)
      reducer.receive(human_event('UNO_STATUS_PRIVATE_V1 picked_card=-', private: true, recipient: own_nick))
    end
    player = game.players.find { |candidate| candidate.matches?(own_nick) }
    reducer.receive(human_event(game.renderer.render_hand(player.hand), private: true, recipient: own_nick))
    reducer
  end

  def assert_differential_parity(game, reducer, events)
    own_nick = game.players.first.to_s
    events.each do |scope, recipient, text|
      next if scope == :private && recipient != own_nick

      reducer.receive(human_event(text, private: scope == :private, recipient: recipient))
    end
    human = reducer.current_request
    refute_nil human, "human reducer did not produce a safe state: #{reducer.unsafe_reasons.inspect}"

    authoritative = Jedna::GameStateSerializer.new.serialize_for_current_player(game)
    machine = decode_machine(authoritative)
    assert_equal stringify(authoritative.fetch(:state)), stringify(machine.state_h)
    assert_equal stringify(authoritative.fetch(:state)), stringify(human.state_h)
  end

  def decode_machine(authoritative)
    lines = UnoMachine::Protocol.state_lines(
      game_id: 'stage7game', decision_id: 'stage7decision',
      reason: :turn_started, request: authoritative
    )
    buffer = UnobotV2::Machine::FrameBuffer.new
    completed = nil
    lines.reverse_each do |line|
      parsed = UnobotV2::Machine::Protocol.parse(line)
      assert_predicate parsed, :success?
      completed = buffer.accept(parsed.value)
    end
    assert_predicate completed, :complete?
    UnobotV2::Canonical::DecisionRequest.from_protocol(
      completed.payload.fetch('request'),
      metadata: { channel: CHANNEL, transport: 'machine', game_id: 'stage7game',
                  decision_id: 'stage7decision' }
    )
  end

  def status_line(game)
    "UNO_STATUS_V1 phase=active current=#{game.players.first} top=#{game.top_card} " \
      "mode=#{game_mode(game.game_state)} stacked_cards=#{game.stacked_cards} " \
      "already_picked=#{game.already_picked ? 1 : 0} " \
      "players=#{game.players.map { |player| "#{player}:#{player.hand.size}" }.join(',')}"
  end

  def game_mode(value)
    { 1 => 'normal', 2 => 'war_+2', 3 => 'war_wd4' }.fetch(value)
  end

  def human_event(text, private: false, recipient: nil)
    UnobotV2::Human::Event.new(
      channel: CHANNEL, source: HOST, text: text,
      private: private, recipient: recipient
    )
  end

  def stringify(value)
    JSON.parse(JSON.generate(value))
  end
end
