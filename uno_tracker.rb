require_relative 'uno_card_stack.rb'
require_relative 'uno_player.rb'

class Tracker
  attr_accessor :stack
  attr_reader :adversaries

  def initialize
    @adversaries = {}
    @played_cards = []
    @stack = []
    @prob_cache = {}
  end

  def reset
    @adversaries = {}
    @stack = CardStack.new
    @stack.fill
  end

  def new_adversary(nick)
    debug 'New adversary -> ' + nick
    @adversaries[nick] = UnoAdversary.new(nick)
    @adversaries[nick].card_count = 7
  end

  def update(text, stack_size)
    split = text.split
    if @adversaries[split[0]].nil?
      debug "Can't update card amount for #{split[0]}"
      return
    end

    if text.include? 'draws'
      debug "#{split[0]} draws a card." if $debug
      @adversaries[split[0]].draw
    else
      debug "#{split[0]} draws #{stack_size} cards." if $debug
      @adversaries[split[0]].draw stack_size
    end
  end

  def stack_size
    @stack.length.to_f
  end

  def reset_cache
    @prob_cache = {}
  end

  #This is not exact. For example, it does not take into account changing color from wild by skips
  #Every function has a two digit code. If it is necessary, the code is followed by card code

  def change_from_wild_probability
    #todo: 2+ skips
    has_wild_probability
  end

  def change_from_wd4_probability color
    @prob_cache[2000+ Uno::COLORS.index(color)] ||=
        has_card_with_property (@stack.select{|c| c.figure==:reverse && c.color==color}.length.to_f) +
        has_wd4_probability -
        has_card_with_property(@stack.select{|c| c.figure==:reverse && c.color==color}.length.to_f)*has_wd4_probability
  end

  # at this point we might as well give up optimizing
  def change_from_plus2_probability card
    p = (@stack.select{|c| c.figure == :wild4 || c.figure == :plus2 || c.figure==:reverse && c.color==card.color}.length.to_f)
    @prob_cache[3000+card.code] ||= has_card_with_property p
  end

  # calculated when we need to know whether the color will be changed between two cards, e.g. r6 -> (?) -> r8
  # probability that the adversary _will_ change color
  def color_change_probability card
    calculate_color_probabilities

    has_no_color = 1.0 - @prob_cache[card.color]

    has_no_color * forced_color_change_probability(card)
  end

  def forced_color_change_probability card
    p = color_changing_cards card
    has_card_with_property p.to_f
  end


  #todo: consider card history
  # number of cards from the stack that can change color from a given normal card
  # e.g. argument: r6, changing cards: b6 g6 y6 w wd4
  def color_changing_cards(card)
    @prob_cache[4000+card.code] = @stack.select{|c| (c.figure == card.figure && c.color != card.color) || c.special_card?}.length
  end

  # the probability that a random card from the stack is a card that will change color from a given normal card
  # e.g. argument: r6, changing cards: b6 g6 y6 w wd4
  def color_change_stack_probability card
    color_changing_cards.to_f/stack_size
  end

  # Adversary has cards of color or wilds. This is not 100% accurate:
  # e.g. does not correctly consider enemy having second copy of "card" (= no figure change)
  # does not consider when enemy willingly changes color even though he still has cards of card.color
  def figure_change_probability card
    @prob_cache[card.color] + has_wild_probability - @prob_cache[card.color]*has_wild_probability
  end

  def has_wild_probability
    has_w_probability + has_wd4_probability - has_wd4_probability*has_w_probability
  end

  def has_w_probability
    @prob_cache[0] ||= has_card_with_property @stack.select{|c| c.figure == :wild }.length.to_f
  end

  def has_wd4_probability
    @prob_cache[1] ||= has_card_with_property @stack.select{|c| c.figure == :wild4 }.length.to_f
  end

  def figure_change_stack_probability card
    @prob_cache[5000+card.code] ||= 1.0 -
        (@stack.select{|c| (c.color == card.color && c.figure != card.figure) || c.special_card?}.length.to_f/stack_size)
  end

  # Called when current and previous dont have color nor figure in common, e.g. r5 -> g7
  # i.e. what's the chance we will be able to play g7 after r5.
  # Which is, more or less, color_change/3: he will change the color, and new color will be our preferred
  def successive_probability current, previous
    raise "Successive probability should not be called for #{current.to_s} and #{previous.to_s}" if
        current.color == previous.color || current.figure == previous.figure

    (color_change_probability previous)/3.0
  end

  # calculates and puts in cache probability that adversary has cards of any given color
  def calculate_color_probabilities adversary = nil
    adversary ||= default_adversary

    Uno::COLORS.each {|col|
      p = @stack.select{|c| c.color == col}.length.to_f
      @prob_cache[col] = has_card_with_property p, adversary
    }
  end

  def default_adversary
    @adversaries[@adversaries.keys[0]]
  end

  private

  # given a stack of size N, adversary hand of size K, and P cards in stack having a certain property
  # calculates the probability that the adversary will have any card with such property in hand
  def has_card_with_property p_no_of_cards, adversary = nil
    adversary ||= default_adversary
    k = adversary.card_count
    n = @stack.length
    p = p_no_of_cards

    # calculate by inverse probability, i.e. probability that he has no cards with property p
    # 1 - (n-p)/n * (n-1-p)*(n-1) ...
    1.0 - (0..(k-1)).reduce(1) { |prod, i| prod*(1.0*n-p-i)/(1.0*n-i) }
  end

end