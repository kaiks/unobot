#required gems:
#cinch
#sequel

require 'cinch'
require_relative 'uno_parser.rb'
require_relative 'pts_ratio_checker.rb'


LAG_DELAY = 0.3      #sec
BOT_NICK = 'unobot'

$debug = false

$last_turn_message = Time.now+2
$last_acted_on_turn_message = Time.now

autojoin = false
last_creator = ''

proxy = UnoProxy.new(nil)
bot = Bot.new(proxy, 0)
proxy.bot = bot

$bot = Cinch::Bot.new do
  configure do |c|
    c.server = 'localhost'
    c.channels = ['#kx']
    c.nick = BOT_NICK
    c.host_nicks = ['ZbojeiJureq', 'ZbojeiJureq_', 'ZbojeiJureq__']
    c.admin_nicks = ['kx', 'kaiks']
    c.messages_per_second = 100000 if c.server == 'localhost'
    c.server_queue_size = 10000000 if c.server == 'localhost'
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
      proxy.reset_game_state
      return
    end

    if m.message == 'unobot'
      autojoin = !autojoin
      m.reply "Uno autojoin = #{autojoin ? 'on' : 'off'}"
      return
      #m.reply 'jo'
    end

    if m.message == 'ha'
      m.reply bot.hand.to_s
      return
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
      bot.reset_hand
      proxy.remove_game_state_flag 1
      proxy.remove_game_state_flag 2
      proxy.remove_game_state_flag 4
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
        sleep(LAG_DELAY)
        proxy.get_message_queue.each { |i| @bot.Channel($bot.config.channels[0]).send i}
        $last_acted_on_turn_message = $last_turn_message
      else
        while $last_acted_on_turn_message == $last_turn_message || proxy.lock == 1
          sleep(LAG_DELAY)
          puts 'Waiting for the message...'
        end
        proxy.parse_hand(m.message)
        bot.play_by_value
        sleep(LAG_DELAY)
        proxy.get_message_queue.each { |i| @bot.Channel($bot.config.channels[0]).send i}
        $last_acted_on_turn_message = $last_turn_message
      end
      #{ proxy.get_message_queue.each { |item| m.reply item } }
    end

  end

end

$bot.start