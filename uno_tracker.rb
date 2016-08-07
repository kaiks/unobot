require 'uno_card_stack.rb'
require 'uno_player.rb'

class Tracker
  attr_accessor :stack
  attr_reader :adversaries

  def initialize
    @adversaries = {}
    @played_cards = []
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

  def change_from_wild_probability
    1.0 - (@stack.select{|c| c.special_card?}.length.to_f/stack_size)
  end

  def color_change_probability card
    1.0 - (@stack.select{|c| (c.figure == card.figure && c.color != card.color) || c.special_card?}.length.to_f/stack_size)
  end

  def figure_change_probability card
    1.0 - (@stack.select{|c| (c.color == card.color && c.figure != card.figure) || c.special_card?}.length.to_f/stack_size)
  end

  def successive_probability current, previous
    @stack.select{|c| (c.plays_after? previous) && (current.plays_after? c)}.length.to_f/stack_size
  end
end