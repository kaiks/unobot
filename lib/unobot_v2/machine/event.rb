# frozen_string_literal: true

module UnobotV2
  module Machine
    Event = Struct.new(:source, :recipient, :text, :kind, :channel, :old_nick,
                       :new_nick, :affected_nick, keyword_init: true) do
      def initialize(**values)
        super
        self.text = text.to_s.freeze
        self.kind ||= :notice
        self.channel = channel&.to_s&.downcase&.freeze
        freeze
      end
    end
  end
end
