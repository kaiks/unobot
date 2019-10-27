require_relative 'uno_card.rb'
require_relative 'uno_hand.rb'

class CardStack < Hand
  def initialize(prefill = true)
    fill if prefill
  end

  def create_discard_pile
    @discard_pile = Hand.new
  end

  def fill
    Uno::STANDARD_SHORT_FIGURES.each do |f|
      %w[r g b y].each do |c|
        self << UnoCard.parse(c + f)
        self << UnoCard.parse(c + f) if f != '0'
      end
    end

    4.times do
      self << UnoCard.parse('ww')
      self << UnoCard.parse('wd4')
    end
  end

  # shuffle!

  def pick(n)
    to_return = CardStack.new(first(n))
    shift(n)
    to_return
  end

  def empty?
    size == 0
  end
end
