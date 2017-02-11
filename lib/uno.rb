require_relative 'misc.rb'
module Uno
  COLORS = [:red, :green, :blue, :yellow, :wild]
  NORMAL_COLORS = [:red, :green, :blue, :yellow]
  SHORT_COLORS = %w(r g b y) + ['']




  STANDARD_FIGURES = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, :plus2, :reverse, :skip]
  STANDARD_SHORT_FIGURES = %w(0 1 2 3 4 5 6 7 8 9 +2 r s)

  SPECIAL_FIGURES = [:wild4, :wild]
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
    elsif short_color == 'w'
      :wild
    else
      throw 'not a valid color: ' + short_color.to_s
    end
  end


  def self.expand_figure short_figure
    short_figure = short_figure.downcase
    if SHORT_FIGURES.member? short_figure
      return FIGURES[SHORT_FIGURES.find_index short_figure]
    else
      if short_figure == '*' || short_figure == 'w'
        return :wild
      elsif short_figure == 'wd4' || short_figure == 'wd'
        return :wild4
      else
        throw 'not a valid figure: ' + short_figure.to_s
      end

    end
  end

  def self.random_color
    COLORS[rand 4]
  end

  def self.random_normal_color
    NORMAL_COLORS[rand 4]
  end

  CARD_CODES = {
      "b0"=>0,
      "b1"=>1,
      "b2"=>3,
      "b3"=>5,
      "b4"=>7,
      "b5"=>9,
      "b6"=>11,
      "b7"=>13,
      "b8"=>15,
      "b9"=>17,
      "br"=>19,
      "bs"=>21,
      "b+2"=>23,
      "g0"=>25,
      "g1"=>26,
      "g2"=>28,
      "g3"=>30,
      "g4"=>32,
      "g5"=>34,
      "g6"=>36,
      "g7"=>38,
      "g8"=>40,
      "g9"=>42,
      "gr"=>44,
      "gs"=>46,
      "g+2"=>48,
      "r0"=>50,
      "r1"=>51,
      "r2"=>53,
      "r3"=>55,
      "r4"=>57,
      "r5"=>59,
      "r6"=>61,
      "r7"=>63,
      "r8"=>65,
      "r9"=>67,
      "rr"=>69,
      "rs"=>71,
      "r+2"=>73,
      "y0"=>75,
      "y1"=>76,
      "y2"=>78,
      "y3"=>80,
      "y4"=>82,
      "y5"=>84,
      "y6"=>86,
      "y7"=>88,
      "y8"=>90,
      "y9"=>92,
      "yr"=>94,
      "ys"=>96,
      "y+2"=>98,
      "w"=>100,
      "wd4"=>104,
      "ww"=>108,
      "wb"=>112,
      "wg"=>113,
      "wy"=>114,
      "wr"=>115,
      "wd4b"=>116,
      "wd4g"=>117,
      "wd4r"=>118,
      "wd4y"=>119
  }

end
