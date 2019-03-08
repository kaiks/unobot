require_relative 'uno_card_stack.rb'
require_relative 'uno_player.rb'

class Tracker
  attr_accessor :stack
  attr_reader :adversaries
  attr_reader :prob_cache, :play_history

  def initialize
    @adversaries = {}
    @played_cards = []
    @stack = []
    @prob_cache = {}
  end

  def set_card_history(history_object)
    @play_history = history_object
  end

  def reset
    @adversaries = {}
    @stack = CardStack.new
    @stack.fill
  end

  def new_adversary(nick)
    bot_debug 'New adversary -> ' + nick
    @adversaries[nick] = UnoAdversary.new(nick)
    @adversaries[nick].card_count = 7
  end

  def update(text, war_stack_size)
    split = text.split
    nick = Misc::NICK_REGEX_PURE.match(split[0])[1]
    if @adversaries[nick].nil?
      bot_debug "Can't update card amount for #{split[0]}"
      return
    end

    if text.include? 'draws'
      bot_debug "#{nick} draws a card."
      @adversaries[nick].draw
    elsif text.include?('passes') && war_stack_size > 0
      bot_debug "#{nick} draws #{war_stack_size} cards."
      @adversaries[nick].draw war_stack_size
    end
  end

  def stack_size
    @stack.length.to_f
  end

  def reset_cache
    @prob_cache = {}
    restore_stack if @copied_stack
  end

  # This is not exact. For example, it does not take into account changing color from wild by skips
  # Every function has a two digit code. If it is necessary, the code is followed by card code

  def change_from_wild_probability
    # TODO: 2+ skips
    has_wild_probability
  end

  def change_from_wd4_probability(color)
    @prob_cache[2000 + Uno::COLORS.index(color)] ||=
      has_card_with_property @stack.select { |c| c.figure == :reverse && c.color == color }.length.to_f +
                             has_wd4_probability -
                             has_card_with_property(@stack.select { |c| c.figure == :reverse && c.color == color }.length.to_f) * has_wd4_probability
  end

  # at this point we might as well give up optimizing
  # card variable means previous card, i.e. the +2
  def change_from_plus2_probability(card)
    p = @stack.select { |c| c.figure == :wild4 || c.figure == :plus2 || c.figure == :reverse && c.color == card.color }.length.to_f
    @prob_cache[3000 + card.code] ||= has_card_with_property p
  end

  # calculated when we need to know whether the color will be changed between two cards, e.g. r6 -> (?) -> r8
  # probability that the adversary _will_ change color
  def color_change_probability(card)
    has_no_color = 1.0 - @prob_cache[card.color]

    has_no_color * forced_color_change_probability(card)
  end

  def forced_color_change_probability(card)
    p = color_changing_cards card
    bot_debug "Card: #{card} P: #{p} prob: #{has_card_with_property p.to_f}", 2
    has_card_with_property p.to_f
  end

  # number of cards from the stack that can change color from a given normal card
  # e.g. argument: r6, changing cards: b6 g6 y6 w wd4
  def color_changing_cards(card)
    @prob_cache[4000 + card.code] ||= @stack.select { |c| (c.figure == card.figure && c.color != card.color) || c.special_card? }.length
  end

  # the probability that a random card from the stack is a card that will change color from a given normal card
  # e.g. argument: r6, changing cards: b6 g6 y6 w wd4
  def color_change_stack_probability(_card)
    color_changing_cards.to_f / stack_size
  end

  # Adversary has cards of color or wilds. This is not 100% accurate:
  # e.g. does not correctly consider enemy having second copy of "card" (= no figure change)
  # does not consider when enemy willingly changes color even though he still has cards of card.color
  def figure_change_probability(card)
    @prob_cache[card.color] + has_wild_probability - @prob_cache[card.color] * has_wild_probability
  end

  def has_wild_probability
    has_w_probability + has_wd4_probability - has_wd4_probability * has_w_probability
  end

  def has_w_probability
    @prob_cache[0] ||= has_card_with_property @stack.select { |c| c.figure == :wild }.length.to_f
  end

  def has_wd4_probability
    @prob_cache[1] ||= has_card_with_property @stack.select { |c| c.figure == :wild4 }.length.to_f
  end

  def figure_change_stack_probability(card)
    @prob_cache[5000 + card.code] ||= 1.0 -
                                      (@stack.select { |c| (c.color == card.color && c.figure != card.figure) || c.special_card? }.length.to_f / stack_size)
  end

  # Called when current and previous dont have color nor figure in common, e.g. r5 -> g7
  # i.e. what's the chance we will be able to play g7 after r5.
  # Which is, more or less, color_change/3: he will change the color, and new color will be our preferred
  def successive_probability(current, previous)
    raise "Successive probability should not be called for #{current} and #{previous}" if
        current.color == previous.color || current.figure == previous.figure

    (color_change_probability previous) / 3.0
  end

  # calculates and puts in cache probability that adversary has cards of any given color
  def calculate_color_probabilities(adversary = nil)
    adversary ||= default_adversary

    Uno::COLORS.each do |col|
      p = @stack.select { |c| c.color == col }.length.to_f
      @prob_cache[col] = has_card_with_property p, adversary
    end
  end

  def look_through_play_history
    # TODO: infer no reverses, +2s and wd4s
    picked_cards = []
    total_picked = {}
    @play_history[-[5, @play_history.length].min..-1].reverse
                                                     .select { |a| a.action == PICK_ACTION && a.player != $bot.nick }.each do |action|
      total_picked[action.player] ||= 0
      total_picked[action.player] += action.attribute
      if total_picked[action.player] > 3
        break
      elsif action.attribute == 1
        picked_cards |= [action.previous_card]
      end
    end

    picked_cards.each do |card|
      @prob_cache[card.color] = 0.0
      @stack.reject! { |x| x.color == card.color || x.figure == card.figure }
    end
  end

  def default_adversary
    @adversaries.values[0]
  end

  private

  def backup_stack
    @copied_stack = @stack.dup
  end

  def restore_stack(destroy_old = true)
    @stack = @copied_stack
    @copied_stack = nil if destroy_old
  end

  def history_colors_picked
    @play_history[-[5, @play_history.length].min..-1]
      .select { |a| a.action == PICK_ACTION && action.player != $bot.nick }
      .map { |a| a.previous_card.color }
      .uniq
  end

  # given a stack of size N, adversary hand of size K, and P cards in stack having a certain property
  # calculates the probability that the adversary will have any card with such property in hand
  def has_card_with_property(p_no_of_cards, adversary = nil)
    adversary ||= default_adversary
    k = adversary.card_count
    n = @stack.length
    p = p_no_of_cards

    # calculate by inverse probability, i.e. probability that he has no cards with property p
    # 1 - (n-p)/n * (n-1-p)*(n-1) ...
    1.0 - (0..(k - 1)).reduce(1) { |prod, i| prod * (1.0 * n - p - i) / (1.0 * n - i) }
  end
end
