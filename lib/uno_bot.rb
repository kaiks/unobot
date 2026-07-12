# required gems:
# cinch

require 'cinch'
require 'json'
require 'thread'
require_relative '../bot_config.rb'
require_relative 'unobot_v2/configuration'

UNOBOT_RUNTIME = UnobotV2::Configuration.runtime(ENV)
UNOBOT_MESSAGING = UnobotV2::Configuration.messaging(ENV)
UNOBOT_STRATEGY = UnobotV2::Configuration.strategy(ENV)

if UNOBOT_RUNTIME == 'legacy' && (UNOBOT_MESSAGING != 'human' || UNOBOT_STRATEGY != 'legacy')
  raise UnobotV2::Configuration::Error,
        'UNO_RUNTIME=legacy supports only UNO_MESSAGING=human with UNO_STRATEGY=legacy'
end

if UNOBOT_RUNTIME == 'legacy'
  require_relative 'uno_parser.rb'
  require_relative 'pts_ratio_checker.rb'
  require_relative './uno_bot_plugin.rb'
else
  require_relative 'unobot_v2'
  require_relative 'unobot_v2/cinch_bridge'
end

$lock = true

$last_turn_message = Time.now + 2
$last_acted_on_turn_message = Time.now

$bot = Cinch::Bot.new do
  configure do |c|
    c.server              = BotConfig::SERVER
    c.port                = BotConfig::PORT
    c.channels            = BotConfig::CHANNELS
    c.nick                = BotConfig::NICK
    c.host_nicks          = BotConfig::HOST_NICKS
    c.admin_nicks         = BotConfig::ADMIN_NICKS
    c.messages_per_second = BotConfig::MESSAGES_PER_SECOND
    c.engine              = nil
    c.verbose             = false
    c.plugins.plugins = UNOBOT_RUNTIME == 'legacy' ? [UnobotPlugin] : []

    if c.server == 'localhost'
      c.messages_per_second = 100_000
      c.server_queue_size   = 100_000
    end
  end
end
$bot.loggers << Cinch::Logger::FormattedLogger.new(File.open('logs/exceptions.log', 'a'))
$bot.loggers[1].level = :error

if UNOBOT_RUNTIME == 'v2'
  shadow_name = UnobotV2::Configuration.shadow_strategy(ENV)
  if UNOBOT_STRATEGY == 'neural' && shadow_name == 'neural'
    raise UnobotV2::Configuration::Error,
          'live and shadow neural strategies cannot run together: deployment permits one model process'
  end
  $unobot_strategy_manager = UnobotV2::StrategyManager.from_env(env: ENV)
  if shadow_name
    shadow_env = ENV.to_h.merge('UNO_STRATEGY' => shadow_name)
    $unobot_shadow_manager = UnobotV2::StrategyManager.from_env(env: shadow_env)
    $unobot_strategy = UnobotV2::ShadowStrategy.new(
      primary: $unobot_strategy_manager, shadow: $unobot_shadow_manager,
      on_observation: lambda do |observation|
        warn "[unobot shadow] #{JSON.generate(observation.to_h)}"
      end
    )
  else
    $unobot_strategy = $unobot_strategy_manager
  end
  $unobot_v2_bridge = UnobotV2::CinchBridge.new(
    bot: $bot, strategy: $unobot_strategy, env: ENV
  ).attach!
  operations_socket = ENV.fetch('UNO_OPERATIONS_SOCKET', '').strip
  unless operations_socket.empty?
    $unobot_operations = UnobotV2::Operations.new(
      socket_path: operations_socket, bridge: $unobot_v2_bridge,
      primary: $unobot_strategy_manager, shadow: $unobot_shadow_manager,
      timeout: Float(ENV.fetch('UNO_OPERATIONS_TIMEOUT', '5')),
      input_timeout: Float(ENV.fetch('UNO_OPERATIONS_INPUT_TIMEOUT', '1')),
      output_timeout: Float(ENV.fetch('UNO_OPERATIONS_OUTPUT_TIMEOUT', '1')),
      shutdown_timeout: Float(ENV.fetch('UNO_OPERATIONS_SHUTDOWN_TIMEOUT', '30')),
      worker_count: Integer(ENV.fetch('UNO_OPERATIONS_WORKERS', '4')),
      client_capacity: Integer(ENV.fetch('UNO_OPERATIONS_CLIENT_CAPACITY', '32')),
      on_restart: -> { $bot.quit('operator requested restart') }
    ).start
  end
  at_exit { $unobot_operations&.stop }
  at_exit { $unobot_v2_bridge&.stop }
end
