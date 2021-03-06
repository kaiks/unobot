require_relative '../lib/uno_ai.rb'
require_relative '../bot_config.rb'
require_relative '../lib/misc.rb'
require_relative '../lib/uno_parser.rb'
require 'test/unit'

class TestStrategy < Test::Unit::TestCase
  def setup
    @proxy = UnoProxy.new(nil)
    @bot = UnoAI.new(@proxy, 0)
    @proxy.ai_engine = @bot

    @bot.hand = Hand.new
    @proxy.top_card = UnoCard.parse('g0')
    @proxy.tracker.reset
    @proxy.tracker.new_adversary 'Testing'
    @proxy.game_state.reset
  end

  def test_more_cards_than_adversary?
    assert_equal(@bot.more_cards_than_adversary?, false)
    @bot.hand = Hand.from_text(%w[g1 g2 g3 g4 g5 g6 g7 g8])
    assert_equal(@bot.more_cards_than_adversary?, true)
  end

  def test_play_card
    @bot.hand = Hand.from_text(%w[g1 g1 g3 g8])
    card_played = @bot.hand[0]
    result = @bot.play card_played
    assert_equal(result, card_played)
    assert_equal(@bot.hand, Hand.from_text(%w[g1 g3 g8]))
  end

  def test_double_play
    @bot.hand = Hand.from_text(%w[g1 g1 g3 g8])
    card_played = @bot.hand[0]
    result = @bot.double_play card_played
    assert_equal(result, card_played)
    assert_equal(@bot.hand, Hand.from_text(%w[g3 g8]))
  end
end
