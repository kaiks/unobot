# frozen_string_literal: true

module UnobotV2
  class MessagingAdapter
    def receive(_event)
      raise NotImplementedError
    end

    def submit(_action, decision_id:)
      raise NotImplementedError
    end
  end

  class Strategy
    def decide(_request)
      raise NotImplementedError
    end
  end

  # Compatibility boundary for legacy or callable strategies. It receives only
  # canonical state; transport text never crosses this boundary.
  class LegacyStrategyAdapter < Strategy
    def initialize(callable = nil, &block)
      @callable = callable || block
      raise ArgumentError, 'a canonical-state callable is required' unless @callable
    end

    def decide(request)
      Canonical::Action.from(@callable.call(request))
    end
  end
end
