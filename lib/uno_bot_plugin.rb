class UnobotPlugin
  include Cinch::Plugin

  self.prefix = '.'

  match /uno$/, method: :on_game_start_request
  match /^unobot$/, method: :on_unobot, use_prefix: false
  match /^pa$/,         method: :on_turn_pass, use_prefix: false
  match /^ha$/,         method: :on_hand_request, use_prefix: false
  match /^set debug (-?[0-9]+)/, method: :set_debug, use_prefix: false
  match /^Ok - created/, method: :on_game_start_non_ladder, use_prefix: false
  match /^Ok, created/, method: :on_game_start, use_prefix: false
  match /reload/, method: :on_reload
  match /reset/, method: :on_reset
  match /fix/, method: :on_fix
  match /^(.+)/, method: :on_any_message, use_prefix: false
  match /eval (.*)/, method: :on_eval, use_prefix: false

  timer 60, method: :save_log

  listen_to :notice, method: :on_notice

  def save_log
    puts 'saving file...'
    @bot.loggers[1].output.fsync
  end

  def ensure_bot_nick(nick)
    @bot.config.host_nicks.include?(nick)
  end

  def ensure_admin_nick(nick)
    @bot.config.admin_nicks.include?(nick)
  end

  def initialize(*args)
    super

    @proxy = UnoProxy.new(nil)
    @proxy.ai_engine = UnoAI.new(@proxy, 0)
    @bot.config.engine = @proxy.ai_engine
  end

  def message(m)
    m.reply 'This is a sample plugin'
  end

  def set_debug(m, level)
    $DEBUG_LEVEL = level.to_i
    $DEBUG = true if $DEBUG_LEVEL >= 0
    m.reply 'Ok.'
  end

  def help(m)
    m.channel.send 'Template plugin help message'
  end

  def on_game_start_request(m)
    @bot.nick = BotConfig::NICK unless @bot.nick == BotConfig::NICK
    @last_creator = m.user.nick
  end

  def on_turn_pass(_m)
    @proxy.game_state.remove_war
  end

  def on_unobot(m)
    @autojoin = !@autojoin
    m.reply "Uno autojoin = #{@autojoin ? 'on' : 'off'}"
  end

  def on_hand_request(m)
    m.reply @proxy.ai_engine.hand.to_s
  end

  def on_game_start_non_ladder(m)
    ensure_bot_nick(m.user.nick) || return
    m.reply 'jo' if @autojoin
  end

  def on_game_start(m)
    ensure_bot_nick(m.user.nick) || return
    if @autojoin && can_play_with?(@last_creator)
      m.reply 'jo'
      @proxy.tracker.reset
    end
  end

  def on_reload(m)
    @proxy.game_state.reset
    begin
      load 'lib/uno_parser.rb'
      load 'lib/uno_card.rb'
      load 'lib/uno_ai.rb'
      load 'lib/uno_tracker.rb'
      load 'lib/uno_bot.rb'
    rescue Exception => e
      m.reply "Failed: #{e}"
    end
    m.reply 'ca'
  end

  def on_reset(m)
    $lock = false
    m.reply 'ca'
    sleep(2)
    m.reply 'cd'
  end

  def on_fix(m)
    m.reply "Attempting to fix completely broken unobot game state"
    @proxy.initialize_game_variables
    @proxy.tracker.new_adversary m.user.nick
    on_reset(m)
  end

  def on_eval(m, arg)
    ensure_admin_nick(m.user.nick) || return
    begin
      m.reply eval(arg).to_s
    rescue Exception => e
      m.reply "Failed: #{e}"
    end
  end

  def on_notice(m)
    if m.user && @bot.config.host_nicks.include?(m.user.nick)
      if m.message.include? 'draw'
        t = m.message.split(':')
        @proxy.drawn_card(t[1])
        @proxy.get_message_queue.each { |i| @bot.Channel(@bot.config.channels[0]).send i }
        $last_acted_on_turn_message = $last_turn_message
      else
        sleep(BotConfig::LAG_DELAY)
        attempts = 0
        while $lock == true && attempts < 10
          bot_debug 'Waiting for the message...', 2
          sleep(1)
          attempts += 1
        end

        if attempts >= 10
          @bot.Channel(@bot.config.channels[0]).send '.note kx omg error. (try to type \'.fix\' and then \'.reset\')'
          $lock = false
        end

        @proxy.parse_hand(m.message)
        @proxy.ai_engine.play_by_value
        sleep(BotConfig::LAG_DELAY)
        @proxy.get_message_queue.each { |i| @bot.Channel(@bot.config.channels[0]).send i }
        $last_acted_on_turn_message = $last_turn_message
        bot_debug 'Setting the lock.'
        $lock = true
      end
    end
  end

  def on_any_message(m)
    ensure_bot_nick(m.user.nick) || return
    @proxy.parse_main(m.user.nick, m.message)
  end
end
