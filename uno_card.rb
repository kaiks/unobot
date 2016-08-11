require 'uno.rb'

class UnoCard
  include Uno

  attr_reader :color, :figure
  attr_accessor :visited

  def initialize(color, figure)
    figure = figure.downcase if figure.is_a? String
    color = color.downcase if color.is_a? String
    throw 'Wrong color' unless Uno::COLORS.include? color
    throw 'Wrong figure' unless Uno::FIGURES.include? figure

    @color = color
    @figure = figure
    @visited = 0

    throw "Not a valid card #{@color} #{@figure}" unless valid?
  end

  def <=>(card)
    @figure <=> card.figure and @color <=> card.color
  end

  def ==(card)
    @figure.to_s == card.figure.to_s and @color == card.color
  end

  def self.parse(card_text)
    card_text = card_text.downcase
    text_length = card_text.length

    return UnoCard.parse_wild(card_text) if card_text[0] == 'w'

    short_color = card_text[0]
    short_figure = card_text[1..2]

    color = Uno.expand_color(short_color)
    figure = Uno.expand_figure(short_figure)

    return UnoCard.new(color, figure)
  end

  def self.parse_wild(card_text)
    card_text = card_text.downcase
    puts "parsing #{card_text}"
    if card_text[0..1].downcase == 'ww'
      puts '--WARNING: WILD CARD ' + card_text
      color = :wild
      short_figure = card_text[1..100]
    else
      short_figure = card_text[1].downcase == 'd' ? 'wd4' : 'w'
      short_color = card_text[-1]
      if short_color == '4'
        color = :wild
      else
        color = Uno.expand_color(short_color)
      end
    end

    figure = Uno.expand_figure(short_figure)
    return UnoCard.new(color, figure)
  end

  def to_s
    if special_valid_card?
      normalize_figure + normalize_color
    else
      normalize_color + normalize_figure
    end
  end

  def bot_output
    "#{3.chr}#{color_number.to_s}[#{normalize_figure}]"
  end

  def set_wild_color(color)
    @color = color if special_valid_card?
  end
  
  def unset_wild_color
    @color = :wild if special_valid_card?
  end



  def color_number
    case @color
      when :green
        3#:green
      when :red
        4#:red
      when :yellow
        7#:yellow
      when :blue
        12#:blue
      when :wild
        13#:blue
    end
  end

  def normalize_color
    if Uno::COLORS.member? @color
      return Uno::SHORT_COLORS[Uno::COLORS.find_index @color]
    else
      throw 'not a valid color'
    end
  end

  def self.normalize_color color
    if Uno::COLORS.member? color
      return Uno::SHORT_COLORS[Uno::COLORS.find_index color]
    else
      throw 'not a valid color'
    end
  end

  def normalize_figure
    if Uno::FIGURES.member? @figure
      return Uno::SHORT_FIGURES[Uno::FIGURES.find_index @figure]
    end
  end

  def self.normalize_figure figure
    if Uno::FIGURES.member? figure
      return Uno::SHORT_FIGURES[Uno::FIGURES.find_index figure]
    end
  end

  def valid_color?
    Uno::COLORS.member? @color
  end

def self.valid_color? color
    Uno::COLORS.member? color
  end

  def valid_figure?
    Uno::FIGURES.member? @figure
  end

  def self.valid_figure? figure
    Uno::FIGURES.member? figure
  end

  def special_card?
    Uno::SPECIAL_FIGURES.member?(@figure)
  end

  def special_valid_card?
    Uno::COLORS.member?(@color) && special_card?
  end

  def valid?
    Uno::COLORS.member?(@color) && Uno::FIGURES.member?(@figure)
  end

  def is_offensive?
    ['+2', 'wild+4'].member? @figure
  end

  def offensive_value
    if @figure == '+2'
      2
    elsif @figure == 'wild+4'
      4
    else
      0
    end
  end


  def is_war_playable?
    ['+2', 'reverse', 'wild+4'].member? @figure
  end

  def plays_after?(card)
    (@color == :wild) || (card.color == :wild) || card.figure == @figure || card.color == @color || (self.special_valid_card?)
  end

  def is_regular?
    figure.is_a? Fixnum
  end

  def value
    return 50 if special_valid_card?
    return @figure if figure.is_a? Fixnum
    return 20
  end

  def playability_value
    return -10 if @figure == 'wild+4'
    return -5 if special_valid_card?
    return -3 if is_offensive?
    return -2 if is_war_playable?
    return @figure if figure.is_a? Fixnum
    return 0 #if skip
  end

end

