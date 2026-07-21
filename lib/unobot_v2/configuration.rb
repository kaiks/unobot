# frozen_string_literal: true

module UnobotV2
  module Configuration
    class Error < ArgumentError; end

    MESSAGING = %w[human machine].freeze
    RUNTIMES = %w[legacy v2].freeze
    STRATEGIES = %w[legacy simple crushing neural].freeze
    TRUE_VALUES = %w[1 true yes on].freeze

    module_function

    def messaging(env = ENV)
      normalize_messaging(env.fetch('UNO_MESSAGING', 'human'))
    end

    def runtime(env = ENV)
      value = env.fetch('UNO_RUNTIME', 'legacy').to_s.downcase
      return value if RUNTIMES.include?(value)

      raise Error, "invalid UNO_RUNTIME #{value.inspect}; expected legacy or v2"
    end

    def strategy(env = ENV)
      value = env.fetch('UNO_STRATEGY', 'legacy').to_s.downcase
      return value if STRATEGIES.include?(value)

      raise Error, "invalid UNO_STRATEGY #{value.inspect}; expected legacy, simple, crushing, or neural"
    end

    def shadow_strategy(env = ENV)
      value = env.fetch('UNO_SHADOW_STRATEGY', '').to_s.downcase
      return nil if value.empty? || value == 'none'
      return value if STRATEGIES.include?(value) && value != 'legacy'

      raise Error, "invalid UNO_SHADOW_STRATEGY #{value.inspect}; expected none, simple, crushing, or neural"
    end

    def fallback_enabled?(env = ENV)
      boolean(env.fetch('UNO_MACHINE_HUMAN_FALLBACK', 'false'), 'UNO_MACHINE_HUMAN_FALLBACK')
    end

    def autojoin_enabled?(env = ENV)
      boolean(env.fetch('UNO_AUTOJOIN', 'false'), 'UNO_AUTOJOIN')
    end

    def human_resync_delay(env = ENV)
      value = Float(env.fetch('UNO_HUMAN_RESYNC_DELAY', '0'))
      return value if value.finite? && value >= 0 && value <= 10

      raise Error, 'UNO_HUMAN_RESYNC_DELAY must be between 0 and 10 seconds'
    rescue ArgumentError, TypeError
      raise Error, 'UNO_HUMAN_RESYNC_DELAY must be between 0 and 10 seconds'
    end

    def boolean(value, label)
      value = value.to_s.downcase
      return true if TRUE_VALUES.include?(value)
      return false if %w[0 false no off].include?(value)

      raise Error, "invalid #{label} #{value.inspect}"
    end

    def normalize_messaging(value)
      mode = value.to_s.downcase
      return mode if MESSAGING.include?(mode)

      raise Error, "invalid UNO_MESSAGING #{value.inspect}; expected human or machine"
    end
  end
end
