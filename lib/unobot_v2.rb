# frozen_string_literal: true

require_relative 'unobot_v2/canonical'
require_relative 'unobot_v2/action_validator'
require_relative 'unobot_v2/process_agent'
require_relative 'unobot_v2/neural_agent'
require_relative 'unobot_v2/strategy_factory'
require_relative 'unobot_v2/strategy_manager'
require_relative 'unobot_v2/rules'
require_relative 'unobot_v2/interfaces'
require_relative 'unobot_v2/ordered_consumer'
require_relative 'unobot_v2/human/card_parser'
require_relative 'unobot_v2/human/reducer'
require_relative 'unobot_v2/human/action_encoder'
require_relative 'unobot_v2/human/adapter'
require_relative 'unobot_v2/machine/protocol'
require_relative 'unobot_v2/machine/frame_buffer'
require_relative 'unobot_v2/machine/event'
require_relative 'unobot_v2/machine/adapter'
require_relative 'unobot_v2/machine/ingress'
require_relative 'unobot_v2/session_manager'
require_relative 'unobot_v2/controller'
require_relative 'unobot_v2/configuration'
require_relative 'unobot_v2/messaging_factory'
require_relative 'unobot_v2/runtime'

module UnobotV2
  PROTOCOL_VERSION = 1
end
