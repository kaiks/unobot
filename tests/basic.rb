require_relative '../lib/uno_ai.rb'
require_relative '../lib/uno_parser.rb'
require 'test/unit'

require '../bot_config'

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

  def prepare_tracker
    @proxy.tracker.stack.remove! @bot.hand
    @proxy.tracker.stack.remove! @proxy.top_card
    @proxy.tracker.calculate_color_probabilities
  end

  def test_skip
    @bot.hand.from_text ['y6', 'ys']
    @proxy.top_card = UnoCard.parse('y4')

    prepare_tracker
    path = @bot.calculate_best_path_by_probability_chain
    path_s = path[2].map{|c| c.to_s}.to_s

    assert_equal(path[2].map{|c| c.to_s}.to_s,["ys", "y6"].to_s, "Wrong path: #{path_s}")
  end

  def test_wd4_skip
    @proxy.top_card = UnoCard.parse('b5')
    @bot.hand.from_text ['g6', 'gs', 'gs', 'wd4']
    prepare_tracker

    path = @bot.calculate_best_path_by_probability_chain
    path_s = path[2].map{|c| c.to_s}.to_s
    assert_equal(path_s,["wd4g", "gs", "gs", "g6"].to_s, "Wrong path: #{path_s}")
  end

  def test_skip_2
    @bot.hand.from_text ['b7', 'g1', 'g3', 'gs', 'r5', 'r+2', 'ww']
    prepare_tracker
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
    prepare_tracker
    path = @bot.calculate_best_path_by_probability_chain
    path_s = path[2].map{|c| c.to_s}.to_s

    assert_equal(path_s, ["g6", "gs", "g7", "y7", "y1", "wd4", "r9"].to_s,
        "Wrong path: #{path_s}")
  end


  def test_wild
    @bot.hand.from_text ['b6', 'r7', 'ww']
    prepare_tracker
    path = @bot.calculate_best_path_by_probability_chain

    assert_nil(path, "Path was supposed to be nil, was #{path.to_s} instead")
  end

  def test_wild_2
    @bot.hand.from_text ['b6', 'bs', 'ww']
    @proxy.tracker.default_adversary.card_count = 3
    prepare_tracker
    path = @bot.calculate_best_path_by_probability_chain

    path_s = path[2].map{|c| c.to_s}.to_s

    assert_equal(path_s, ['wb', 'bs', 'b6'].to_s,
        "Wrong path: #{path_s}")
  end

  def test_wild_3
    @bot.hand.from_text ['b6', 'b6', 'bs', 'ww']
    prepare_tracker
    path = @bot.calculate_best_path_by_probability_chain

    path_s = path[2].map{|c| c.to_s}.to_s

    assert_equal(path_s, ['wb', 'bs', 'b6', 'b6'].to_s,
                 "Wrong path: #{path_s}")
  end

  def test_wild_4
    @bot.hand.from_text ['bs', 'gs', 'bs', 'ww', 'rs', 'r6', 'ys']
    prepare_tracker
    path = @bot.calculate_best_path_by_probability_chain

    path_s = path[2].map{|c| c.to_s}.to_s

    puts "Test wild 4: #{path_s}"

    assert_not_nil(path_s,
                 "Wrong path (shouldn't be nil): #{path_s}")
  end

  def test_wild_5
    @bot.hand.from_text ['bs', 'rs', 'bs', 'wd4', 'rs', 'r6', 'ys']
    prepare_tracker
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
    prepare_tracker
    assert_not_nil(
        @proxy.tracker.stack.delete_at(@proxy.tracker.stack.index{|e| e.to_s=='br'} || @proxy.tracker.stack.length),
        "Deleting failed")

    assert_equal(@bot.play_by_value.to_s,'wd4b')
  end

  def test_wild_7
    puts "Test wild 7"
    @bot.hand.from_text ['wd4', 'gr', 'gr']
    @proxy.top_card = UnoCard.new(:wild, :wild)
    prepare_tracker
    path = @bot.calculate_best_path_by_probability_chain
    path_s = path[2].map{|c| c.to_s}
    assert(path_s.equal_partial?(['gr', 'gr', :_]),
                 "Wrong path: #{path_s.to_s}")
  end

  def test_wild_8
    puts "Test wild 8"
    @bot.hand.from_text ['y0', 'y5', 'y8', 'ww', 'gs', 'rs', 'ys']
    @proxy.top_card = UnoCard.parse('g4')
    prepare_tracker
    path = @bot.calculate_best_path_by_probability_chain
    path_s = path[2].map{|c| c.to_s}
    assert_not_equal(path_s[0],'wg',
           "Wrong path: #{path_s.to_s}")
  end

  def test_wild_9
    puts "Test wild 9"
    @bot.hand.from_text ['wwd4', 'gs', 'g6']
    @proxy.top_card = UnoCard.parse('wd4g')
    prepare_tracker
    set_debug 3
    path = @bot.calculate_best_path_by_probability_chain
    unset_debug
    path_s = path[2].map{|c| c.to_s}
    puts path_s
    assert_not_equal(path_s[0],'wd4g',
                     "Wrong path: #{path_s.to_s}")
  end

  def test_zero_1
    @bot.hand.from_text ['b6', 'b0']

    @proxy.top_card = UnoCard.parse('wb')
    prepare_tracker
    path = @bot.calculate_best_path_by_probability_chain
    path_s = path[2].map{|c| c.to_s}.to_s
    assert_equal(path_s,['b0', 'b6'].to_s,
                 "Wrong path: #{path_s}")
  end

  def test_turn_order
    @bot.hand.from_text ['b9', 'bs', 'y8', 'y9', 'ys']
    @proxy.top_card = UnoCard.parse('b8')
    prepare_tracker
    path = @bot.calculate_best_path_by_probability_chain
    path_s = path[2].map{|c| c.to_s}.to_s
    assert_equal(path_s,['y8', 'y9', 'ys', 'bs', 'b9'].to_s,
                 "Wrong path: #{path_s}")
  end

  def test_one_card_1
    puts "Now testing test_one_card_1"
    @proxy.top_card = UnoCard.parse('r4')
    @bot.hand.from_text ['gs', 'rs', 'rs', 'r+2']
    prepare_tracker
    @proxy.game_state.one_card!
    card_text = @bot.play_by_value.to_s
    assert_equal(card_text, 'rs')
  end

  def test_plustwo_1
    @bot.hand.from_text ['g+2', 'g5', 'y5', 'y5', 'y7']
    @proxy.top_card = UnoCard.parse('g5')
    prepare_tracker
    @proxy.tracker.default_adversary.card_count = 3
    @proxy.tracker.stack=@proxy.tracker.stack.shuffle.drop(50)
    path = @bot.calculate_best_path_by_probability_chain
    path_s = path[2].map{|c| c.to_s}.to_s
    assert_equal(path_s,['g+2', 'g5', 'y5', 'y5', 'y7'].to_s,
                 "Wrong path: #{path_s}")
  end


end