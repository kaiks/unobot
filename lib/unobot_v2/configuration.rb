# frozen_string_literal: true

module UnobotV2
  module Configuration
    class Error < ArgumentError; end

    MESSAGING = %w[human machine].freeze
    TRUE_VALUES = %w[1 true yes on].freeze

    module_function

    def messaging(env = ENV)
      normalize_messaging(env.fetch('UNO_MESSAGING', 'human'))
    end

    def fallback_enabled?(env = ENV)
      value = env.fetch('UNO_MACHINE_HUMAN_FALLBACK', 'false').to_s.downcase
      return true if TRUE_VALUES.include?(value)
      return false if %w[0 false no off].include?(value)

      raise Error, "invalid UNO_MACHINE_HUMAN_FALLBACK #{value.inspect}"
    end

    def normalize_messaging(value)
      mode = value.to_s.downcase
      return mode if MESSAGING.include?(mode)

      raise Error, "invalid UNO_MESSAGING #{value.inspect}; expected human or machine"
    end
  end
end
