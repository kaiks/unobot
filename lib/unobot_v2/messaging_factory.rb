# frozen_string_literal: true

require_relative 'configuration'
require_relative 'human/adapter'
require_relative 'machine/adapter'

module UnobotV2
  module MessagingFactory
    COMMON_KEYS = %i[channel own_nick host_nicks transport on_request].freeze
    HUMAN_KEYS = (COMMON_KEYS + %i[on_lifecycle reducer encoder resync_delay sleeper]).freeze
    MACHINE_KEYS = (COMMON_KEYS + %i[
      on_status frame_buffer clock ack_timeout registration_timeout
      rename_recovery_timeout rename_retry_interval
    ]).freeze

    module_function

    # Messaging construction deliberately has no strategy argument. The
    # Controller/Runtime injects the same Strategy through on_request after the
    # transport choice has been made.
    def build(mode:, **options)
      case Configuration.normalize_messaging(mode)
      when 'human' then Human::Adapter.new(**options.slice(*HUMAN_KEYS))
      when 'machine' then Machine::Adapter.new(**options.slice(*MACHINE_KEYS))
      end
    end
  end
end
