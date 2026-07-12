# frozen_string_literal: true

require_relative 'test_helper'
require 'json'
require_relative '../lib/unobot_v2'
require_relative '../lib/unobot_v2/cinch_bridge'

class UnobotV2CinchBridgeTest < Minitest::Test
  Fixture = Struct.new(:command, :user, :channel, :message, :params, keyword_init: true)
  User = Struct.new(:nick, :last_nick, keyword_init: true)
  Channel = Struct.new(:name, keyword_init: true)

  class Target
    attr_reader :messages

    def initialize
      @messages = Queue.new
    end

    def send(line)
      messages << [line, Thread.current]
    end
  end

  class Handlers
    attr_reader :registered

    def initialize
      @registered = []
    end

    def register(handler)
      registered << handler
    end

    def unregister(handler)
      registered.delete(handler)
    end
  end

  class BlockingHandlers < Handlers
    def initialize(started:, release:)
      super()
      @started = started
      @release = release
      @blocked = false
    end

    def register(handler)
      super
      return if @blocked

      @blocked = true
      @started << true
      @release.pop
    end
  end

  class Loggers
    def exception(error)
      raise error
    end
  end

  class Bot
    Config = Struct.new(:channels, :host_nicks, keyword_init: true)

    attr_reader :nick, :config, :handlers, :channel_targets, :user_targets, :loggers

    def initialize(nick: 'Alice', channels: ['#uno'], host_nicks: ['Host'])
      @nick = nick
      @config = Config.new(channels: channels, host_nicks: host_nicks)
      @handlers = Handlers.new
      @channel_targets = Hash.new { |hash, key| hash[key.downcase] = Target.new }
      @user_targets = Hash.new { |hash, key| hash[key.downcase] = Target.new }
      @loggers = Loggers.new
    end

    def Channel(name) = channel_targets[name.to_s.downcase]
    def User(name) = user_targets[name.to_s.downcase]
  end

  RecordingStrategy = Struct.new(:seen) do
    def decide(request)
      seen << [request, Thread.current]
      UnobotV2::Canonical::Action.new(action: 'draw')
    end
  end

  FIXTURE_PATH = File.expand_path('fixtures/host_machine_protocol_v1/frames.json', __dir__)

  def setup
    @fixture = JSON.parse(File.read(FIXTURE_PATH))
    @bot = Bot.new
    @seen = Queue.new
    @strategy = RecordingStrategy.new(@seen)
    @callback_thread = Thread.current
  end

  def teardown
    @bridge&.stop
  end

  def test_legacy_is_default_and_human_private_correlation_requires_one_channel
    assert_equal 'legacy', UnobotV2::Configuration.runtime({})
    assert_equal 'v2', UnobotV2::Configuration.runtime('UNO_RUNTIME' => 'v2')
    assert_raises(UnobotV2::Configuration::Error) do
      UnobotV2::Configuration.runtime('UNO_RUNTIME' => 'other')
    end

    bot = Bot.new(channels: %w[#one #two])
    assert_raises(UnobotV2::Configuration::Error) do
      UnobotV2::CinchBridge.new(
        bot: bot, strategy: @strategy, env: { 'UNO_MESSAGING' => 'human' }
      )
    end
    assert_raises(UnobotV2::Configuration::Error) do
      UnobotV2::CinchBridge.new(
        bot: bot, strategy: @strategy,
        env: { 'UNO_MESSAGING' => 'machine', 'UNO_MACHINE_HUMAN_FALLBACK' => 'true' }
      )
    end
  end

  def test_machine_callbacks_attach_to_real_runtime_and_action_uses_private_privmsg_target
    @bridge = build_bridge('machine').attach!
    assert_equal 8, @bot.handlers.registered.length
    assert_same @bridge, @bridge.attach!
    assert_equal 8, @bot.handlers.registered.length
    assert @bot.handlers.registered.all? { |handler| handler.is_a?(UnobotV2::CinchBridge::OrderedHandler) }
    assert @bot.channel_targets['#uno'].messages.empty?, 'must not register before own JOIN'

    @bridge.on_join(fake_message(command: 'JOIN', source: 'Alice', channel: '#uno'))
    registration = pop(@bot.channel_targets['#uno'].messages)
    assert_equal '.uno machine register', registration[0]
    refute_same @callback_thread, registration[1]

    @bridge.on_notice(fake_message(command: 'NOTICE', source: 'Host', recipient: 'Alice',
                              text: @fixture.fetch('registered_line')))
    @fixture.fetch('state_lines').each do |line|
      @bridge.on_notice(fake_message(command: 'NOTICE', source: 'Host', recipient: 'Alice', text: line))
    end
    request, strategy_thread = pop(@seen)
    assert_equal 'machine', request.metadata[:transport]
    refute_same @callback_thread, strategy_thread
    action = pop(@bot.user_targets['host'].messages)
    assert_includes action[0], 'UNO_MACHINE_V1 ACTION '
    refute_same @callback_thread, action[1]
    assert @bot.channel_targets['host'].messages.empty?
  end

  def test_human_private_notice_uses_params_recipient_and_never_callback_thread
    @bridge = build_bridge('human').attach!
    @bridge.on_join(fake_message(command: 'JOIN', source: 'Alice', channel: '#uno'))
    assert_equal %w[us ca], 2.times.map { pop(@bot.channel_targets['#uno'].messages)[0] }

    private_notice('UNO_STATUS_V1 phase=active current=Alice top=r7 mode=normal ' \
                   'stacked_cards=0 already_picked=0 players=Alice:3,Bob:2,Carol:1')
    private_notice('UNO_STATUS_PRIVATE_V1 picked_card=-')
    private_notice("\x034[2] \x0312[5] \x0313[WD4]")
    request, strategy_thread = pop(@seen)
    assert_equal 'human', request.metadata[:transport]
    refute_same @callback_thread, strategy_thread
    command = pop(@bot.channel_targets['#uno'].messages)
    assert_equal 'pe', command[0]
    refute_same @callback_thread, command[1]

    @bridge.on_notice(fake_message(command: 'NOTICE', source: 'Host', recipient: 'Bob', text: 'secret'))
    wait_until { @bridge.errors.size.positive? }
    assert_equal :wrong_recipient, @bridge.errors.pop.code
  end

  def test_affected_user_lifecycle_and_uno_player_join_registration_trigger
    @bridge = build_bridge('machine').attach!
    @bridge.on_join(fake_message(command: 'JOIN', source: 'Alice', channel: '#uno'))
    pop(@bot.channel_targets['#uno'].messages)

    kicker = fake_message(command: 'KICK', source: 'Op', channel: '#uno')
    @bridge.on_leaving(kicker, User.new(nick: 'Bob'))
    sleep 0.01
    assert @bot.channel_targets['#uno'].messages.empty?

    @bridge.on_channel(fake_message(command: 'PRIVMSG', source: 'Host', channel: '#uno',
                               recipient: '#uno', text: 'Alice joins the game'))
    assert_equal '.uno machine register', pop(@bot.channel_targets['#uno'].messages)[0]

    @bridge.on_leaving(kicker, User.new(nick: 'Alice'))
    sleep 0.01
    assert @bot.channel_targets['#uno'].messages.empty?, 'kick must not register while absent'
    @bridge.on_join(fake_message(command: 'JOIN', source: 'Alice', channel: '#uno'))
    assert_equal '.uno machine register', pop(@bot.channel_targets['#uno'].messages)[0]
  end

  def test_explicit_autojoin_joins_trusted_games_and_reregisters_after_player_join
    @bridge = UnobotV2::CinchBridge.new(
      bot: @bot, strategy: @strategy,
      env: { 'UNO_MESSAGING' => 'machine', 'UNO_AUTOJOIN' => 'true' },
      tick_interval: 0.01
    ).attach!
    @bridge.on_join(fake_message(command: 'JOIN', source: 'Alice', channel: '#uno'))
    assert_equal '.uno machine register', pop(@bot.channel_targets['#uno'].messages)[0]

    @bridge.on_channel(fake_message(
      command: 'PRIVMSG', source: 'Host', channel: '#uno', recipient: '#uno',
      text: "Ok, created casual \x02\x0304U\x0309N\x0312O\x0308!\x0f game on #uno, say 'jo' to join in"
    ))
    assert_equal 'jo', pop(@bot.channel_targets['#uno'].messages)[0]

    @bridge.on_channel(fake_message(command: 'PRIVMSG', source: 'Host', channel: '#uno',
                                    recipient: '#uno', text: 'Alice joins the game'))
    assert_equal '.uno machine register', pop(@bot.channel_targets['#uno'].messages)[0]

    @bridge.on_channel(fake_message(
      command: 'PRIVMSG', source: 'Mallory', channel: '#uno', recipient: '#uno',
      text: "Ok, created casual UNO game on #uno, say 'jo' to join in"
    ))
    sleep 0.01
    assert @bot.channel_targets['#uno'].messages.empty?
  end

  def test_autojoin_is_disabled_by_default_and_rejects_invalid_configuration
    @bridge = build_bridge('machine').attach!
    @bridge.on_join(fake_message(command: 'JOIN', source: 'Alice', channel: '#uno'))
    pop(@bot.channel_targets['#uno'].messages)
    @bridge.on_channel(fake_message(
      command: 'PRIVMSG', source: 'Host', channel: '#uno', recipient: '#uno',
      text: "Ok, created casual UNO game on #uno, say 'jo' to join in"
    ))
    sleep 0.01
    assert @bot.channel_targets['#uno'].messages.empty?

    assert_raises(UnobotV2::Configuration::Error) do
      UnobotV2::CinchBridge.new(
        bot: @bot, strategy: @strategy,
        env: { 'UNO_MESSAGING' => 'machine', 'UNO_AUTOJOIN' => 'sometimes' }
      )
    end
  end

  def test_transport_rejects_untrusted_target_and_bridge_queue_callbacks_are_nonblocking
    @bridge = build_bridge('machine').attach!
    assert_raises(ArgumentError) { @bridge.send(:transport, 'Mallory', 'unsafe') }

    tiny = UnobotV2::CinchBridge.new(
      bot: @bot, strategy: @strategy, env: { 'UNO_MESSAGING' => 'machine' },
      queue_capacity: 1, tick_interval: 0.05
    )
    tiny.instance_variable_get(:@queue).push(:occupied)
    refute tiny.on_disconnect
    assert_equal :bridge_queue_overflow, tiny.errors.pop.code
  end

  def test_dropped_human_bridge_event_invalidates_blocked_strategy_before_action_output
    started = Queue.new
    release = Queue.new
    blocking = Class.new(UnobotV2::Strategy) do
      define_method(:initialize) { |started_queue, release_queue| @started = started_queue; @release = release_queue }
      define_method(:decide) do |_request|
        @started << true
        @release.pop
        UnobotV2::Canonical::Action.new(action: 'draw')
      end
    end.new(started, release)
    @bridge = UnobotV2::CinchBridge.new(
      bot: @bot, strategy: blocking, env: { 'UNO_MESSAGING' => 'human' },
      tick_interval: 0.01
    ).attach!
    @bridge.on_join(fake_message(command: 'JOIN', source: 'Alice', channel: '#uno'))
    2.times { pop(@bot.channel_targets['#uno'].messages) }
    private_notice('UNO_STATUS_V1 phase=active current=Alice top=r7 mode=normal ' \
                   'stacked_cards=0 already_picked=0 players=Alice:3,Bob:2,Carol:1')
    private_notice('UNO_STATUS_PRIVATE_V1 picked_card=-')
    private_notice("\x034[2] \x0312[5] \x0313[WD4]")
    started.pop

    original = @bridge.instance_variable_get(:@queue)
    full = SizedQueue.new(1)
    full.push(:occupied)
    @bridge.instance_variable_set(:@queue, full)
    refute @bridge.on_channel(fake_message(command: 'PRIVMSG', source: 'Host', channel: '#uno',
                                           recipient: '#uno', text: "Bob's turn. Top card: r7"))
    @bridge.instance_variable_set(:@queue, original)
    assert @bridge.tick
    release << true

    recovery = 2.times.map { pop(@bot.channel_targets['#uno'].messages)[0] }
    assert_equal %w[us ca], recovery
    sleep 0.01
    assert @bot.channel_targets['#uno'].messages.empty?, 'pre-overflow draw action must not escape'
    codes = []
    codes << @bridge.errors.pop.code until @bridge.errors.empty?
    assert_includes codes, :bridge_queue_overflow
  end

  def test_foreign_channels_and_channel_notices_cannot_create_or_mutate_sessions
    @bridge = build_bridge('human').attach!
    @bridge.on_join(fake_message(command: 'JOIN', source: 'Alice', channel: '#uno'))
    2.times { pop(@bot.channel_targets['#uno'].messages) }

    @bridge.on_channel(fake_message(command: 'PRIVMSG', source: 'Host', channel: '#other',
                                    recipient: '#other', text: "Alice's turn. Top card: r7"))
    @bridge.on_join(fake_message(command: 'JOIN', source: 'Alice', channel: '#other'))
    @bridge.on_leaving(fake_message(command: 'KICK', source: 'Op', channel: '#other'), User.new(nick: 'Alice'))
    @bridge.on_notice(fake_message(command: 'NOTICE', source: 'Host', channel: '#uno',
                                   recipient: '#uno', text: 'ordinary channel notice'))
    wait_until { @bridge.errors.size >= 3 }
    assert_equal %i[unconfigured_channel unconfigured_channel unconfigured_channel],
                 3.times.map { @bridge.errors.pop.code }
    sleep 0.01
    assert @bridge.errors.empty?, 'channel NOTICE must be ignored, not treated as private state'
    assert @bot.channel_targets['#other'].messages.empty?
    sessions = @bridge.runtime.ingress.instance_variable_get(:@sessions)
    refute sessions.key?('#other')
  end

  def test_live_machine_to_human_fallback_routes_subsequent_callbacks_to_fresh_human_ingress
    @bridge = UnobotV2::CinchBridge.new(
      bot: @bot, strategy: @strategy,
      env: { 'UNO_MESSAGING' => 'machine', 'UNO_MACHINE_HUMAN_FALLBACK' => 'true' },
      tick_interval: 0.01
    ).attach!
    @bridge.on_join(fake_message(command: 'JOIN', source: 'Alice', channel: '#uno'))
    assert_equal '.uno machine register', pop(@bot.channel_targets['#uno'].messages)[0]

    transition = @bridge.runtime.transition_to('human')
    assert_predicate transition, :success?
    assert_equal 'human', @bridge.mode
    assert_equal ['.uno machine unregister', 'us', 'ca'],
                 3.times.map { pop(@bot.channel_targets['#uno'].messages)[0] }

    private_notice('UNO_STATUS_V1 phase=active current=Alice top=r7 mode=normal ' \
                   'stacked_cards=0 already_picked=0 players=Alice:3,Bob:2,Carol:1')
    private_notice('UNO_STATUS_PRIVATE_V1 picked_card=-')
    private_notice("\x034[2] \x0312[5] \x0313[WD4]")
    request, strategy_thread = pop(@seen)
    assert_equal 'human', request.metadata[:transport]
    refute_same @callback_thread, strategy_thread
    assert_equal 'pe', pop(@bot.channel_targets['#uno'].messages)[0]
  end

  def test_concurrent_stop_cannot_leave_handlers_or_worker_after_partial_attach
    started = Queue.new
    release = Queue.new
    handlers = BlockingHandlers.new(started: started, release: release)
    @bot.instance_variable_set(:@handlers, handlers)
    @bridge = build_bridge('machine')
    attaching = Thread.new { @bridge.attach! }
    started.pop
    stopping = Thread.new { @bridge.stop }
    sleep 0.01
    assert_predicate stopping, :alive?, 'stop must wait for atomic attachment to finish'
    release << true
    attaching.join
    stopping.join

    assert_empty handlers.registered
    worker = @bridge.instance_variable_get(:@worker)
    refute_predicate worker, :alive?
    assert_raises(RuntimeError) { @bridge.attach! }
  end

  private

  def build_bridge(mode)
    UnobotV2::CinchBridge.new(
      bot: @bot, strategy: @strategy, env: { 'UNO_MESSAGING' => mode },
      tick_interval: 0.01
    )
  end

  def private_notice(text)
    @bridge.on_notice(fake_message(command: 'NOTICE', source: 'Host', recipient: 'Alice', text: text))
  end

  def fake_message(command:, source:, channel: nil, recipient: nil, text: '')
    Fixture.new(
      command: command, user: User.new(nick: source),
      channel: channel && Channel.new(name: channel), message: text,
      params: recipient ? [recipient, text] : []
    )
  end

  def pop(queue, timeout: 1)
    queue.pop(timeout: timeout) || raise('timed out waiting for bridge output')
  end

  def wait_until(timeout: 1)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise 'timed out waiting for bridge' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      Thread.pass
    end
  end
end
