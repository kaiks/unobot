$DEBUG = false
$DEBUG_LEVEL = 0

Dir.chdir(File.dirname(__FILE__))

module BotConfig
  LAG_DELAY = 0.3      #sec
  NICK = 'unobot'

  HOST_NICKS = ['ZbojeiJureq', 'ZbojeiJureq_', 'ZbojeiJureq__']
  ADMIN_NICKS = ['kx', 'kaiks']
  MESSAGES_PER_SECOND = 2
  SERVER = 'localhost'
  CHANNELS = ['#kx']
end