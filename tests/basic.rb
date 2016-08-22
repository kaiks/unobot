require_relative '../uno_ai.rb'
require_relative '../uno_parser.rb'
require 'test/unit'

class TestStrategy < Test::Unit::TestCase

  def setup
    @proxy = UnoProxy.new(nil)
    @bot = Bot.new(@proxy, 0)
    @proxy.bot = @bot

    @bot.hand = Hand.new
    @bot.last_card = UnoCard.parse('g0')
    @proxy.tracker.reset
    @proxy.tracker.new_adversary 'Testing'
    @proxy.reset_game_state
  end



  def test_skip
    @bot.hand.from_text ['y6', 'ys']
    @bot.last_card = UnoCard.parse('y4')


    path = @bot.calculate_best_path_by_probability_chain
    path_s = path[2].map{|c| c.to_s}.to_s

    assert_equal(path[2].map{|c| c.to_s}.to_s,["ys", "y6"].to_s, "Wrong path: #{path_s}")
  end

  def test_wd4_skip
    @bot.last_card = UnoCard.parse('b5')
    @bot.hand.from_text ['g6', 'gs', 'gs', 'wd4']
    path = @bot.calculate_best_path_by_probability_chain
    path_s = path[2].map{|c| c.to_s}.to_s
    assert_equal(path_s,["wd4g", "gs", "gs", "g6"].to_s, "Wrong path: #{path_s}")
  end

  def test_skip_2
    @bot.hand.from_text ['b7', 'g1', 'g3', 'gs', 'r+2', 'r5', 'ww']

    path = @bot.calculate_best_path_by_probability_chain

    path_s = path[2].map{|c| c.to_s}.to_s

    assert(
        path_s == ["g1", "gs", "g3", "w", "r5", "r+2", "b7"].to_s ||
        path_s == ["g3", "gs", "g1", "w", "r5", "r+2", "b7"].to_s,
        "Wrong path: #{path_s}"
    )

  end

  def test_skip_3
    @bot.hand.from_text ['g6', 'g7', 'gs', 'r9', 'wd4', 'y1', 'y7']
    path = @bot.calculate_best_path_by_probability_chain
    path_s = path[2].map{|c| c.to_s}.to_s

    assert_equal(path_s, ["g6", "gs", "g7", "y7", "y1", "wd4", "r9"].to_s,
        "Wrong path: #{path_s}")
  end


  def test_wild
    @bot.hand.from_text ['b6', 'r7', 'ww']
    path = @bot.calculate_best_path_by_probability_chain

    assert_nil(path, "Path was supposed to be nil, was #{path.to_s} instead")
  end

  def test_wild_2
    @bot.hand.from_text ['b6', 'bs', 'ww']
    path = @bot.calculate_best_path_by_probability_chain

    path_s = path[2].map{|c| c.to_s}.to_s

    assert_equal(path_s, ['wb', 'bs', 'b6'].to_s,
        "Wrong path: #{path_s}")
  end

  def test_wild_3
    @bot.hand.from_text ['b6', 'b6', 'bs', 'ww']
    path = @bot.calculate_best_path_by_probability_chain

    path_s = path[2].map{|c| c.to_s}.to_s

    assert_equal(path_s, ['wb', 'bs', 'b6', 'b6'].to_s,
                 "Wrong path: #{path_s}")
  end

  def test_wild_4
    @bot.hand.from_text ['bs', 'gs', 'bs', 'ww', 'rs', 'r6', 'ys']
    path = @bot.calculate_best_path_by_probability_chain

    path_s = path[2].map{|c| c.to_s}.to_s

    puts "Test wild 4: #{path_s}"

    assert_not_nil(path_s,
                 "Wrong path (shouldn't be nil): #{path_s}")
  end

  def test_wild_5
    @bot.hand.from_text ['bs', 'rs', 'bs', 'wd4', 'rs', 'r6', 'ys']
    assert_not_nil(
        @proxy.tracker.stack.delete_at(@proxy.tracker.stack.index{|e| e.to_s=='br'} || @proxy.tracker.stack.length),
        "Deleting failed")

    puts @proxy.tracker.change_from_wd4_probability :yellow
    puts @proxy.tracker.change_from_wd4_probability :blue

    path = @bot.calculate_best_path_by_probability_chain
    path_s = path[2].map{|c| c.to_s}.to_s

    puts "Test wild 5: #{path_s}"

    assert_not_nil(path_s,
                   "Wrong path (shouldn't be nil): #{path_s}")

    assert_equal(path[0].to_s, 'wd4b')
  end


  def test_wild_6
    @bot.hand.from_text ['bs', 'rs', 'bs', 'wd4', 'rs', 'r6', 'ys']
    assert_not_nil(
        @proxy.tracker.stack.delete_at(@proxy.tracker.stack.index{|e| e.to_s=='br'} || @proxy.tracker.stack.length),
        "Deleting failed")

    assert_equal(@bot.play_by_value.to_s,'wd4b')
  end


end