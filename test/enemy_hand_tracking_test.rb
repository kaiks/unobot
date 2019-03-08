require_relative '../lib/uno_ai.rb'
require_relative '../bot_config.rb'
require_relative '../lib/misc.rb'
require_relative '../lib/uno_parser.rb'
require 'test/unit'

require_relative '../lib/uno_bot.rb'
$bot.instance_eval("@name = 'unobot'")

class TestStrategy < Test::Unit::TestCase
  ADVERSARY_NICK = 'Testing'.freeze
  def setup
    @proxy = UnoProxy.new(nil)
    @bot = UnoAI.new(@proxy, 0)
    @proxy.ai_engine = @bot
    @proxy.send(:initialize_game_variables)

    @bot.hand = Hand.new
    @proxy.top_card = UnoCard.parse('g0')
    @proxy.tracker.reset
    @proxy.tracker.new_adversary ADVERSARY_NICK
    @proxy.game_state.reset
  end

  # TODO:
  # when we play a card, nothing should change

  # when enemy has 7 cards, and plays one, he has 6 cards
  def test_1
    set_debug 5
    assert_equal(@bot.default_adversary.card_count, 7)
    @proxy.instance_eval("@active_player = '#{ADVERSARY_NICK}'")
    @proxy.parse_main('ZbojeiJureq', "unobot's turn. Top card: 3[1]")
    assert_equal(@bot.default_adversary.card_count, 6)
  end

  # when enemy has 7 cards, and picks one, he has 8 cards
  def test_2
    set_debug 5
    assert_equal(@bot.default_adversary.card_count, 7)
    @proxy.instance_eval("@active_player = '#{ADVERSARY_NICK}'")
    @proxy.parse_main('ZbojeiJureq', "#{ADVERSARY_NICK} draws a card.")
    assert_equal(@bot.default_adversary.card_count, 8)
  end

  # when enemy has 7 cards, and picks 4 from stack, he has 11 cards
  def test_3
    set_debug 5
    assert_equal(@bot.default_adversary.card_count, 7)
    @proxy.parse_main('ZbojeiJureq', 'Next player must respond or draw 4 more cards (total 4)')
    @proxy.parse_main('ZbojeiJureq', "#{ADVERSARY_NICK}'s turn. Top card: 12[WD4]")
    @proxy.parse_main('ZbojeiJureq', "#{ADVERSARY_NICK} passes. unobot's turn. Top card: 12[WD4]")
    assert_equal(@bot.default_adversary.card_count, 11)
  end

  # when enemy has 7 cards, and plays skip then plays one, he has 5 cards
  def test_4
    set_debug 5
    assert_equal(@bot.default_adversary.card_count, 7)
    @proxy.instance_eval("@active_player = 'unobot'")
    @proxy.parse_main('ZbojeiJureq', "#{ADVERSARY_NICK}'s turn. Top card: 12[4]")
    @proxy.parse_main('ZbojeiJureq', 'unobot was skipped!')
    @proxy.parse_main('ZbojeiJureq', "#{ADVERSARY_NICK}'s turn. Top card: 12[S]")
    @proxy.parse_main('ZbojeiJureq', "unobot's turn. Top card: 12[6]")
    assert_equal(@bot.default_adversary.card_count, 5)
  end
end
