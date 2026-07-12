# frozen_string_literal: true

require 'bundler/setup'
require 'cinch'
require 'json'

root, port, channel, artifact = ARGV
abort 'usage: unobot_runner.rb UNOBOT_ROOT PORT CHANNEL ARTIFACT' unless artifact

$LOAD_PATH.unshift(File.join(root, 'lib'))
require 'unobot_v2'
require 'unobot_v2/cinch_bridge'

class Stage7PassiveHuman
  def initialize(bot:, channel:, artifact:)
    @bot = bot
    @channel = channel
    @artifact = artifact
    @mutex = Mutex.new
    @condition = ConditionVariable.new
    @reducer = nil
  end

  def receive_notice(source:, recipient:, text:)
    @mutex.synchronize do
      return unless @reducer

      @reducer.receive(UnobotV2::Human::Event.new(
        channel: @channel, source: source, recipient: recipient,
        text: text, private: true
      ))
      @condition.broadcast if @reducer.current_request
    end
  end

  def compare(machine_request, timeout: 3.0)
    reducer = @mutex.synchronize do
      @reducer = UnobotV2::Human::Reducer.new(
        channel: @channel, own_nick: 'unobot', host_nicks: ['Host']
      )
    end
    @bot.Channel(@channel).send('us')
    @bot.Channel(@channel).send('ca')
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    human = @mutex.synchronize do
      until (request = reducer.current_request)
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        break if remaining <= 0

        @condition.wait(@mutex, remaining)
      end
      reducer.current_request
    end
    raise "human snapshot timeout: #{reducer.unsafe_reasons.inspect}" unless human

    equal = human.state_h == machine_request.state_h
    append(
      type: 'differential', decision_id: machine_request.decision_id,
      game_id: machine_request.metadata[:game_id], equal: equal,
      human: human.state_h, machine: machine_request.state_h
    )
    raise 'human and machine canonical states differ' unless equal
  ensure
    @mutex.synchronize { @reducer = nil }
  end

  def append(record)
    File.open(@artifact, 'a') { |file| file.puts(JSON.generate(record)) }
  end
end

class Stage7ObserverPlugin
  include Cinch::Plugin
  listen_to :notice, method: :notice

  def notice(message)
    $stage7_passive.receive_notice(
      source: message.user&.nick, recipient: Array(message.params).first,
      text: message.message.to_s
    )
  end
end

class Stage7DifferentialStrategy < UnobotV2::Strategy
  def initialize(primary:, observer:)
    @primary = primary
    @observer = observer
    @encoder = UnobotV2::Human::ActionEncoder.new
  end

  def decide(request)
    @observer.compare(request)
    action = @primary.decide(request)
    encoded = @encoder.encode(action, request: request)
    @observer.append(
      type: 'decision', decision_id: request.decision_id,
      action: action.to_h, human_command: encoded.command, encodable: encoded.success?
    )
    raise "machine action is not human-encodable: #{encoded.code}" unless encoded.success?

    action
  rescue StandardError => error
    @observer.append(
      type: 'strategy_error', decision_id: request.decision_id,
      error: error.class.name, message: error.message
    )
    raise
  end

  def method_missing(name, *args, **keywords, &block)
    return @primary.public_send(name, *args, **keywords, &block) if @primary.respond_to?(name)

    super
  end

  def respond_to_missing?(name, include_private = false)
    @primary.respond_to?(name, include_private) || super
  end
end

bot = Cinch::Bot.new do
  configure do |config|
    config.nick = 'unobot'
    config.server = '127.0.0.1'
    config.port = Integer(port)
    config.channels = [channel]
    config.host_nicks = ['Host']
    config.messages_per_second = 100_000
    config.server_queue_size = 100_000
    config.verbose = false
    config.plugins.plugins = [Stage7ObserverPlugin]
  end
end

$stage7_passive = Stage7PassiveHuman.new(bot: bot, channel: channel, artifact: artifact)
manager = UnobotV2::StrategyManager.from_env(env: ENV)
strategy = Stage7DifferentialStrategy.new(primary: manager, observer: $stage7_passive)
if (shadow_name = UnobotV2::Configuration.shadow_strategy(ENV))
  shadow = UnobotV2::StrategyManager.from_env(env: ENV.to_h.merge('UNO_STRATEGY' => shadow_name))
  strategy = UnobotV2::ShadowStrategy.new(
    primary: strategy, shadow: shadow,
    on_observation: ->(result) { $stage7_passive.append(type: 'shadow', **result.to_h) }
  )
end
bridge = UnobotV2::CinchBridge.new(bot: bot, strategy: strategy, env: ENV).attach!
%w[INT TERM].each { |signal| Signal.trap(signal) { Thread.new { bot.quit('stage7 shutdown') } } }
begin
  bot.start
ensure
  bridge&.stop
end
