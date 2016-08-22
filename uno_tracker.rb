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
    puts 'New adversary -> ' + nick
    @adversaries[nick] = UnoAdversary.new(nick)
    @adversaries[nick].card_count = 7
  end

  def update(text, stack_size)
    split = text.split
    if @adversaries[split[0]].nil?
      puts "Can't update card amount for #{split[0]}"
      return
    end

    if text.include? 'draws'
      puts "#{split[0]} draws a card." if $debug
      @adversaries[split[0]].draw
    else
      puts "#{split[0]} draws #{stack_size} cards." if $debug
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
    @prob_cache[10] ||= 1.0 - (@stack.select{|c| c.special_card?}.length.to_f/stack_size)
  end

  def change_from_wd4_probability color
    @prob_cache[20+ Uno::COLORS.index(color)] ||= 1.0 -
        (@stack.select{|c| c.figure == 'wild+4' || c.figure=='reverse' && c.color==color}.length.to_f/stack_size)
  end

  def change_from_plus2_probability card
    @prob_cache[30+card.code] ||= 1.0 -
        (@stack.select{|c| c.figure == 'wild+4' || c.figure == '+2' || c.figure=='reverse' && c.color==card.color}.length.to_f/stack_size)
  end

  def color_change_probability card
    @prob_cache[40+card.code] ||= 1.0 -
        (@stack.select{|c| (c.figure == card.figure && c.color != card.color) || c.special_card?}.length.to_f/stack_size)
  end

  def figure_change_probability card
    @prob_cache[50+card.code] ||= 1.0 -
        (@stack.select{|c| (c.color == card.color && c.figure != card.figure) || c.special_card?}.length.to_f/stack_size)
  end

  def successive_probability current, previous
    @prob_cache[60+current.code+previous.code] ||= @stack.
        select{|c| (c.plays_after? previous) && (current.plays_after? c)}.length.to_f/stack_size
  end
end