require_relative 'misc.rb'
module Uno
  COLORS = [:red, :green, :blue, :yellow, :wild]
  NORMAL_COLORS = [:red, :green, :blue, :yellow]
  SHORT_COLORS = %w(r g b y) + ['']




  STANDARD_FIGURES = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, '+2', 'reverse', 'skip']
  STANDARD_SHORT_FIGURES = %w(0 1 2 3 4 5 6 7 8 9 +2 r s)

  SPECIAL_FIGURES = ['wild+4', 'wild']
  SPECIAL_SHORT_FIGURES = ['wd4', 'w']

  FIGURES = STANDARD_FIGURES + SPECIAL_FIGURES
  SHORT_FIGURES = STANDARD_SHORT_FIGURES + SPECIAL_SHORT_FIGURES

  r = :red
  g = :green
  b = :blue
  y = :yellow
  w = :wild

  def self.expand_color short_color
    short_color = short_color.downcase
    if SHORT_COLORS.member? short_color
      COLORS[SHORT_COLORS.find_index short_color]
    else
      throw 'not a valid color: ' + short_color.to_s
    end
  end


  def self.expand_figure short_figure
    short_figure = short_figure.downcase
    if SHORT_FIGURES.member? short_figure
      return FIGURES[SHORT_FIGURES.find_index short_figure]
    else
      if short_figure == '*' || short_figure == 'wd4' || short_figure == 'w' || short_figure == 'wd'
        return 'wild'
      else
        throw 'not a valid figure: ' + short_figure.to_s
      end

    end
  end

  def self.random_color
    COLORS[rand 4]
  end

  CARD_CODES = {
    "b+2"=>0,
    "b0"=>1,
    "b1"=>2,
    "b2"=>3,
    "b3"=>4,
    "b4"=>5,
    "b5"=>6,
    "b6"=>7,
    "b7"=>8,
    "b8"=>9,
    "b9"=>10,
    "br"=>11,
    "bs"=>12,
    "g+2"=>13,
    "g0"=>14,
    "g1"=>15,
    "g2"=>16,
    "g3"=>17,
    "g4"=>18,
    "g5"=>19,
    "g6"=>20,
    "g7"=>21,
    "g8"=>22,
    "g9"=>23,
    "gr"=>24,
    "gs"=>25,
    "r+2"=>26,
    "r0"=>27,
    "r1"=>28,
    "r2"=>29,
    "r3"=>30,
    "r4"=>31,
    "r5"=>32,
    "r6"=>33,
    "r7"=>34,
    "r8"=>35,
    "r9"=>36,
    "rr"=>37,
    "rs"=>38,
    "y+2"=>39,
    "y0"=>40,
    "y1"=>41,
    "y2"=>42,
    "y3"=>43,
    "y4"=>44,
    "y5"=>45,
    "y6"=>46,
    "y7"=>47,
    "y8"=>48,
    "y9"=>49,
    "yr"=>50,
    "ys"=>51,

    "w"=>52,
    "wd4"=>53,

    "ww"=>54,
    "wb"=>55,
    "wg"=>56,
    "wy"=>57,
    "wr"=>58,
    "wd4b"=>59,
    "wd4g"=>60,
    "wd4r"=>61,
    "wd4y"=>62
  }

end
