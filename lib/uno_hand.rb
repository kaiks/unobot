require_relative 'uno_card.rb'

class Hand < Array
  def self.from_text(array)
    throw 'Wrong argument' unless array.is_a?(Array) && array.map { |e| e.is_a? String }.all?
    new(array.map { |c| UnoCard.parse(c) })
  end

  def from_text(array)
    throw 'Wrong argument' unless array.is_a?(Array) && array.map { |e| e.is_a? String }.all?
    drop! length
    array.each do |e|
      self << UnoCard.parse(e)
    end
  end

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
    map(&:to_s).reduce { |old, new| old += " #{new}" }
  end

  def bot_output
    map(&:bot_output).reduce { |old, new| old += "#{new}#{3.chr}" }
  end

  def reset_wilds
    each(&:unset_wild_color)
  end

  def drop!(n)
    n.times { delete_at(0) }
    self
  end

  def add_random(n)
    n.times do
      add_card(UnoCard.random)
    end
  end

  def destroy(card)
    throw 'Deleting wild card? Something went wrong' if card.color == :wild
    delete_at(index(card) || length)
  end

  def select(&block)
    Hand.new(super.select(&block))
  end

  def playable_after(card)
    select { |x| x.plays_after? card }
  end

  def offensive
    select(&:is_offensive?)
  end

  def offensive!
    select!(&:is_offensive?)
  end

  def wild
    select(&:special_card?)
  end

  def wild!
    select!(&:special_card?)
  end

  def colors
    map(&:color).uniq
  end

  # Uno::COLORS[color]
  def of_color(color)
    select { |card| card.color == color }
  end

  def of_figure(fig)
    select { |c| c.figure == fig }
  end

  def of_figure!(fig)
    select! { |c| c.figure == fig }
  end

  def remove_cards!(cards)
    cards.each do |card|
      i = index { |c| c.code == card.code }
      slice! i unless i.nil?
    end
  end

  def remove_card!(card, twice = false)
    (twice ? 2 : 1).times do
      i = index { |c| c.code == card.code }
      slice! i unless i.nil?
    end
  end

  def remove!(item, twice = false)
    if item.is_a? Array
      remove_cards! item
    elsif item.class == UnoCard
      remove_card!(item, twice)
    end
  end

  def all_cards_same_color?
    hand_colors = colors
    hand_colors.delete(:wild)
    hand_colors.size < 2
  end
end
