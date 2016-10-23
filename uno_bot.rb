#required gems:
#cinch
#sequel
require 'cinch'
require 'thread'
require './misc.rb'
require './bot_config.rb'
require_relative 'uno_parser.rb'
require_relative 'pts_ratio_checker.rb'


$lock = true

$last_turn_message = Time.now+2
$last_acted_on_turn_message = Time.now

autojoin = false
last_creator = ''

proxy = UnoProxy.new(nil)
bot = Bot.new(proxy, 0)
proxy.bot = bot

$bot = Cinch::Bot.new do
  configure do |c|
    c.server              = BotConfig::SERVER
    c.channels            = BotConfig::CHANNELS
    c.nick                = BotConfig::NICK
    c.host_nicks          = BotConfig::HOST_NICKS
    c.admin_nicks         = BotConfig::ADMIN_NICKS
    c.messages_per_second = BotConfig::MESSAGES_PER_SECOND

    if c.server == 'localhost'
      c.messages_per_second = 100000
      c.server_queue_size   = 100000
    end
  end

  on :message do |m|
    if m.message =~ /^eval/ && $bot.config.admin_nicks.include?(m.user.nick)
      m.reply "#{eval m.message.split.drop(1).join(' ')}"
    end
    proxy.parse_main(m.user.nick, m.message)
    if m.message =~ /\.uno/
      $bot.nick = BOT_NICK unless $bot.nick == BOT_NICK
      last_creator = m.user.nick
    end

    if m.message == 'pa'
      proxy.game_state.remove_war
    end

    if m.message == 'unobot'
      autojoin = !autojoin
      m.reply "Uno autojoin = #{autojoin ? 'on' : 'off'}"
      #m.reply 'jo'
    end

    if m.message == 'ha'
      m.reply bot.hand.to_s
    end

    if m.message =~ /^set_debug [0-9]/
      $DEBUG_LEVEL = m.message.split[1]
      m.reply 'Ok.'
    end

    if m.message.include? 'Ok - created'
      m.reply 'jo' if autojoin
    end

    if m.message.include? 'Ok, created'
      if autojoin && can_play_with?(last_creator)
        m.reply 'jo'
        proxy.tracker.reset
      end
    end

    if m.message =~  /^reload/
      proxy.game_state.reset
      load 'uno_parser.rb'
      load 'uno_card.rb'
      load 'uno_ai.rb'
      m.reply 'ca'
    end
  end

  on :notice do |m|
    if $bot.config.host_nicks.include? m.user.nick
      if m.message.include? 'draw'
        t = m.message.split(':')
        proxy.drawn_card(t[1])
        proxy.get_message_queue.each { |i| @bot.Channel($bot.config.channels[0]).send i}
        $last_acted_on_turn_message = $last_turn_message
      else
        sleep(BotConfig::LAG_DELAY)
        while $lock == true
          debug 'Waiting for the message...'
          sleep(1)
        end
        proxy.parse_hand(m.message)
        bot.play_by_value
        sleep(BotConfig::LAG_DELAY)
        proxy.get_message_queue.each { |i| @bot.Channel($bot.config.channels[0]).send i}
        $last_acted_on_turn_message = $last_turn_message
        debug 'Setting the lock.'
        $lock = true
      end
    end

  end

end

$bot.start