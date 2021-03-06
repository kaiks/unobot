# required gems:
# cinch

require 'cinch'
require 'thread'
require_relative '../bot_config.rb'
require_relative 'uno_parser.rb'
require_relative 'pts_ratio_checker.rb'
require_relative './uno_bot_plugin.rb'

$lock = true

$last_turn_message = Time.now + 2
$last_acted_on_turn_message = Time.now

$bot = Cinch::Bot.new do
  configure do |c|
    c.server              = BotConfig::SERVER
    c.channels            = BotConfig::CHANNELS
    c.nick                = BotConfig::NICK
    c.host_nicks          = BotConfig::HOST_NICKS
    c.admin_nicks         = BotConfig::ADMIN_NICKS
    c.messages_per_second = BotConfig::MESSAGES_PER_SECOND
    c.engine              = nil
    c.verbose             = false
    c.plugins.plugins = [UnobotPlugin]

    if c.server == 'localhost'
      c.messages_per_second = 100_000
      c.server_queue_size   = 100_000
    end
  end
end
$bot.loggers << Cinch::Logger::FormattedLogger.new(File.open('logs/exceptions.log', 'a'))
$bot.loggers[1].level = :error
