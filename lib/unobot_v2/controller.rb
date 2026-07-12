# frozen_string_literal: true

module UnobotV2
  # Wires messaging and strategy without teaching either side about the other.
  # With OrderedConsumer this decision runs entirely off the IRC callback.
  class Controller
    def initialize(strategy:, messaging:)
      @strategy = strategy
      @messaging = messaging
    end

    def action_required(request)
      action = @strategy.decide(request)
      @messaging.submit(action, decision_id: request.decision_id)
    end
  end
end
