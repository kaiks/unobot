$DEBUG = false
$DEBUG_LEVEL = 0

Dir.chdir(File.dirname(__FILE__))

module BotConfig
  IRC_NICK = /\A[A-Za-z_\[\]\\`^{}|][A-Za-z0-9_\-\[\]\\`^{}|]{0,29}\z/
  IRC_CHANNEL = /\A[#+&!][^\x00\x07\r\n ,:]{1,49}\z/
  IRC_SERVER = /\A[^\x00\r\n\s]{1,255}\z/

  def self.list(name, default, pattern:)
    value = ENV[name]
    parsed = value.nil? ? default.dup : value.split(',', -1).map(&:strip)
    unless parsed.any? && parsed.all? { |item| pattern.match?(item) }
      raise ArgumentError, "#{name} must contain only IRC-safe values"
    end

    parsed.uniq.freeze
  end

  def self.positive_integer(name, default)
    value = Integer(ENV.fetch(name, default.to_s))
    raise ArgumentError, "#{name} must be positive" unless value.positive?

    value
  end

  def self.port
    value = Integer(ENV.fetch('IRC_PORT', '6667'))
    raise ArgumentError, 'IRC_PORT must be between 1 and 65535' unless (1..65_535).cover?(value)

    value
  end

  def self.token(name, default, pattern:)
    value = ENV.fetch(name, default).to_s
    raise ArgumentError, "#{name} is not an IRC-safe value" unless pattern.match?(value)

    value.freeze
  end

  LAG_DELAY = 0.3 # sec
  NICK = token('IRC_NICK', 'unobot', pattern: IRC_NICK)

  HOST_NICKS = list('UNO_HOST_NICKS', %w[ZbojeiJureq ZbojeiJureq_ ZbojeiJureq__], pattern: IRC_NICK)
  ADMIN_NICKS = list('UNO_ADMIN_NICKS', %w[kx kaiks], pattern: IRC_NICK)
  MESSAGES_PER_SECOND = positive_integer('IRC_MESSAGES_PER_SECOND', 2)
  # Use host.docker.internal for Mac/Windows, or host network mode on Linux
  SERVER = token('IRC_SERVER', 'host.docker.internal', pattern: IRC_SERVER)
  PORT = port
  CHANNELS = list('UNO_CHANNELS', ['#kx'], pattern: IRC_CHANNEL)
end
