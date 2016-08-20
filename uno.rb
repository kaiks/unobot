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

end
