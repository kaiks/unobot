$DEBUG = false
$DEBUG_LEVEL = 0

Dir.chdir(File.dirname(__FILE__))

module BotConfig
  LAG_DELAY = 0.3 # sec
  NICK = 'unobot'.freeze

  HOST_NICKS = %w[ZbojeiJureq ZbojeiJureq_ ZbojeiJureq__].freeze
  ADMIN_NICKS = %w[kx kaiks].freeze
  MESSAGES_PER_SECOND = 2
  # Use host.docker.internal for Mac/Windows, or host network mode on Linux
  SERVER = ENV['IRC_SERVER'] || 'host.docker.internal'.freeze
  CHANNELS = ['#kx'].freeze
end
