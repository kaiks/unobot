$DEBUG = false
$DEBUG_LEVEL = 0

Dir.chdir(File.dirname(__FILE__))

module BotConfig
  def self.list(name, default)
    value = ENV[name]
    return default.freeze if value.nil? || value.strip.empty?

    parsed = value.split(',').map(&:strip).reject(&:empty?).uniq
    raise ArgumentError, "#{name} must contain at least one value" if parsed.empty?

    parsed.freeze
  end

  LAG_DELAY = 0.3 # sec
  NICK = ENV.fetch('IRC_NICK', 'unobot').freeze

  HOST_NICKS = list('UNO_HOST_NICKS', %w[ZbojeiJureq ZbojeiJureq_ ZbojeiJureq__])
  ADMIN_NICKS = list('UNO_ADMIN_NICKS', %w[kx kaiks])
  MESSAGES_PER_SECOND = Integer(ENV.fetch('IRC_MESSAGES_PER_SECOND', '2'))
  # Use host.docker.internal for Mac/Windows, or host network mode on Linux
  SERVER = ENV['IRC_SERVER'] || 'host.docker.internal'.freeze
  CHANNELS = list('UNO_CHANNELS', ['#kx'])
end
