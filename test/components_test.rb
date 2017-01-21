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



  def test_attempt_color_change_1
    @bot.hand.from_text ['y6', 'ys', 'gs', 'ww']
    @bot.attempt_color_change
    path_s = @bot.predefined_path.map{|c| c.to_s}.to_s
    assert_equal(path_s,'["wy"]',
                 "Wrong path: #{path_s}")
  end

  def test_attempt_color_change_2
    @bot.hand.from_text ['y6', 'ys', 'gs']
    @bot.attempt_color_change
    path_s = @bot.predefined_path.map{|c| c.to_s}.to_s
    assert_equal(path_s,'["gs", "ys"]',
                 "Wrong path: #{path_s}")
  end

  def test_attempt_color_change_3
    @bot.hand.from_text ['y6', 'yr', 'gr', 'gr']
    @bot.attempt_color_change
    path_s = @bot.predefined_path.map{|c| c.to_s}.to_s
    assert_equal(path_s,'["gr", "gr", "yr"]',
                 "Wrong path: #{path_s}")
  end

  def test_get_offensive_path_1
    @bot.hand.from_text ['y6', 'ys', 'gs', 'ww', 'y+2']
    path_s = @bot.get_offensive_path.map{|c|c.to_s}.to_s
    assert_equal(path_s,'["gs", "ys", "y+2"]',
                 "Wrong path: #{path_s}")
  end

  def test_get_offensive_path_2
    @bot.hand.from_text ['y6', 'yr','yr', 'gr', 'gr', 'ww', 'y+2']
    path_s = @bot.get_offensive_path.map{|c|c.to_s}.to_s
    assert_equal(path_s,'["gr", "gr", "yr", "yr", "y+2"]',
                 "Wrong path: #{path_s}")
  end

  def test_tracker_1

  end
end