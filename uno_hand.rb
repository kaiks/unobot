require 'uno_card.rb'

class Hand < Array

  def <<(cards)
    push(cards)
    flatten!
  end

  def add_card(card)
    throw 'Not a card. Cant add' unless card.is_a? UnoCard
    push(card)
  end

  def value
    map(&:value).reduce(:+)
  end

  def to_s
    map(&:to_s).reduce{|old, new| old += " #{new}"}
  end

  def bot_output
    map(&:bot_output).reduce{|old, new| old += "#{new}#{3.chr}"}
  end

  def reset_wilds
    self.each { |c|
      c.unset_wild_color
    }
  end

  def drop(n)
    n.times { delete_at(0) }
    self
  end
  
  
  def add_random(n)
    n.times {
      color_index = rand(4)
      figure_index = rand(15)

      color_index = 4 if figure_index > 12 #in case of wild figure

      color = Uno::COLORS[color_index]
      figure = Uno::FIGURES[figure_index]

      card = UnoCard.new(color, figure)
      add_card(card)
    }
  end

  def destroy(card)
    throw 'Deleting wild card? Something went wrong' if card.color == :wild
    delete_at(index(card) || length)
  end

  def playable_after card
    select{ |x| x.plays_after? card }
  end

  def colors
    map { |c| c.color}.uniq
  end

  def select &block
    return Hand.new(super.select { block } )
  end

  #Uno::COLORS[color]
  def of_color(color)
	  return select { |card| card.color == color }
  end

  def remove!(hand)
    if hand.class == Hand
      hand.each {|card|
        i = index{ |c| c.to_s == card.to_s }
        slice! i unless i.nil?
      }
    elsif hand.class == UnoCard
      i = index{ |c| c.to_s == hand.to_s }
      slice! i unless i.nil?
    end
  end

  def all_cards_same_color?
    hand_colors = colors
    hand_colors.delete(:wild)
    hand_colors.size < 2
  end
  
end
