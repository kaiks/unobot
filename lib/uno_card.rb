require_relative 'uno.rb'

class UnoCard
  include Uno

  attr_reader :color, :figure, :code
  attr_accessor :visited

  def self.debug text
    puts text if $DEBUG
  end

  #randomly generates a card
  # note: does not reflect real card distribution, i.e. every card has the same likelihood
  def self.random
    UnoCard.new(Uno::COLORS.sample, Uno::FIGURES.sample)
  end

  def initialize(color, figure)
    figure = figure.downcase if figure.is_a? String
    color = color.downcase if color.is_a? String
    throw "Wrong color #{color}" unless Uno::COLORS.include? color
    throw "Wrong figure: #{figure}" unless Uno::FIGURES.include? figure

    @color = color
    @figure = figure
    @code = Uno::CARD_CODES[to_s]
    @visited = 0
    throw "Not a valid card #{@color} #{@figure}" unless valid?
  end

  def <=>(card)
    @figure <=> card.figure and @color <=> card.color
  end

  def ==(card)
    figure == card.figure and color == card.color
  end

  def self.parse(card_text)
    card_text = card_text.downcase
    debug "[parse] Parsing #{card_text}"
    return UnoCard.parse_wild(card_text) if (card_text[1] == 'w' || card_text[0] == 'w')

    short_color = card_text[0]
    short_figure = card_text[1..2]

    color = Uno.expand_color(short_color)
    figure = Uno.expand_figure(short_figure)
    UnoCard.new(color, figure)
  end

  def self.parse_wild(card_text)
    debug "[parse_wild] Parsing #{card_text}"
    color = Uno.expand_color(card_text[0])
    short_figure = 'w'
    if card_text.length > 2
      short_figure = 'wd4' if (card_text[1..2] == 'd4' || card_text[2..3] == 'd4')
    end
    figure = Uno.expand_figure(short_figure)
    UnoCard.new(color, figure)
  end

  def to_s
    if special_valid_card?
      normalize_figure + normalize_color
    else
      normalize_color + normalize_figure
    end
  end

  def to_irc_s
    #IRC_COLOR_CODES.fetch(normalize_color.to_s,'13')
    "#{3.chr}#{color_number}[#{normalize_figure.to_s.upcase}]"
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
      else
        throw 'Wrong color number'
    end
  end

  def normalize_color
    if Uno::COLORS.member? @color
      return Uno::SHORT_COLORS[Uno::COLORS.find_index @color]
    else
      throw "not a valid color: #{@color}"
    end
  end

  def self.normalize_color color
    if Uno::COLORS.member? color
      return Uno::SHORT_COLORS[Uno::COLORS.find_index color]
    else
      throw "not a valid color: #{color}"
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

  def self.random top_id = 53
    card_text = Uno::CARD_CODES.keys[top_id+1] #because rand doesn't include top number
    UnoCard.parse(card_text)
  end


  def valid_color?
    Uno::COLORS.member? color
  end

def self.valid_color? color
    Uno::COLORS.member? color
  end

  def valid_figure?
    Uno::FIGURES.member? figure
  end

  def self.valid_figure? figure
    Uno::FIGURES.member? figure
  end

  def special_card?
    figure == :wild4 || figure == :wild
  end

  def special_valid_card?
    Uno::COLORS.member?(color) && special_card?
  end

  def valid?
    color_valid? && Uno::FIGURES.member?(figure)
  end

  def color_valid?
    color == :green || color == :red || color == :blue || color == :yellow || color == :wild
  end

  def is_offensive?
    [:plus2, :wild4].member? figure
  end

  def offensive_value
    if figure == :plus2
      2
    elsif figure == :wild4
      4
    else
      0
    end
  end


  def is_war_playable?
    [:plus2, :reverse, :wild4].member? figure
  end

  def plays_after?(card)
    (color == :wild) || (card.color == :wild) || card.figure == figure || card.color == color || special_card?
  end

  def is_regular?
    figure.is_a? Fixnum
  end

  def value
    return 50 if special_valid_card?
    return figure if figure.is_a? Fixnum
    return 20
  end

  def playability_value
    return -10 if figure == :wild4
    return -5 if special_valid_card?
    return -3 if is_offensive?
    return -2 if is_war_playable?
    return figure if figure.is_a? Fixnum
    return 0 #if skip
  end

end

