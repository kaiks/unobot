# frozen_string_literal: true

module UnobotV2
  module Human
    module CardParser
      COLOR_CODES = { '03' => 'g', '3' => 'g', '04' => 'r', '4' => 'r',
                      '07' => 'y', '7' => 'y', '12' => 'b', '13' => 'w' }.freeze
      CARD_RE = /\x03(\d{1,2})\[([^\]]+)\]/

      module_function

      def parse_all(text)
        text.to_s.scan(CARD_RE).filter_map do |color_code, raw_figure|
          color = COLOR_CODES[color_code]
          figure = normalize_figure(raw_figure)
          next unless color && figure

          if %w[w wd4].include?(figure)
            color == 'w' ? figure : "#{figure}#{color}"
          else
            "#{color}#{figure}"
          end
        end
      end

      def hand(text)
        parse_all(text).map { |card| Canonical::Cards.base(card) }
      end

      def normalize_figure(figure)
        case figure.to_s.downcase
        when 'wild', 'w', '*' then 'w'
        when 'wild+4', 'wild4', 'wd4', 'wd' then 'wd4'
        when 'reverse', 'r' then 'r'
        when 'skip', 's' then 's'
        when 'plus2', '+2' then '+2'
        when /\A[0-9]\z/ then figure
        end
      end
    end
  end
end
