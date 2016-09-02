require_relative 'uno_card.rb'
require_relative 'uno_ai.rb'

GAME_OFF = 16
GAME_ON = 0
WAR = 1
WARWD = 2
ONE_CARD = 4

class UnoProxy
  attr_accessor :bot, :active_player
  attr_reader :tracker
  attr_reader :game_state, :lock, :card_history
  attr_reader :turn_counter, :last_player

  def initialize(bot = nil)
    @bot = bot
    @game_state = GAME_OFF
    @previous_player = nil
    @active_player = nil
    @game_players = []
    @card_history = []
    @top_card = []
    @nick = []
    @messages = []
    @not_started = true
    @tracker = Tracker.new
    @stack_size = 0
    @game_start_draw = true
    @double_play = false
    @turn_counter = 0
  end

  def add_game_state_flag f
    puts "Adding game state flag #{f}"
    @game_state |= f
  end

  def remove_game_state_flag f
    puts "Removing game state flag #{f}"
    @game_state &= ~f
  end

  def reset_game_state
    puts 'Resetting game state'
    @game_state = GAME_ON
  end

  def update_game_state(text)
    if text.include?('raws') || text.include?('passes')
      remove_game_state_flag WAR
      remove_game_state_flag WARWD
      remove_game_state_flag ONE_CARD unless text.include? $bot.nick
      @tracker.update(text, @stack_size)
      @stack_size = 0
    end
  end

  def parse_main(nick, text)
    if host? nick
      debug "[parse_main] Bot says: #{text}"
      case text
        when /must respond/
          add_game_state_flag WAR
          @stack_size = /\(total ([0-9]+)/.match(text)[1].to_i
          puts "Set stack size to #{@stack_size}"
        when /Playing two cards/
          debug 'Double play detected'
          @double_play = true
        when /Ok, created.*/
          #"Ok, created 04U09N12O08! game on #kx, say 'jo' to join in"
          initialize_game_variables
          @lock = 1
        when /joins the game/
          nick = text.split[0]
          @tracker.new_adversary nick unless nick.include? $bot.nick
        when /has only/
          @tracker.adversaries[text.split[0]].card_count = 4 unless text.include? $bot.nick
        when /For a total of/
          #@game_state = GAME_OFF
          @not_started = true
        when /has just one card left/
          add_game_state_flag ONE_CARD unless text.include? $bot.nick
          @tracker.adversaries[text.split[1]].card_count = 2 unless text.include? $bot.nick
        when /.*Top card: .*/
          @lock = 1
          @tracker.reset_cache
          @previous_player = @active_player
          @turn_counter += 1

          @active_player = /([a-z_\-\[\]\\^{}|`][a-z0-9_\-\[\]\\^{}|`]{1,15})'s/i.match(text)[1]
          if text.include? $bot.nick
            $last_turn_message = Time.now unless text.include? "#{$bot.nick} passes"
          end

          card_text_index = text.rindex(/\s/)
          card_text = text[card_text_index..65536]

          #always 1 card only, its by host
          card = parse_card_text(card_text)

          @card_history << card
          @card_history << card if @double_play

          @top_card = card

          if @top_card.is_offensive?
            add_game_state_flag WAR
          end

          if (@game_state & WAR) >= WAR && @top_card.special_card?
            add_game_state_flag WARWD
          end

          update_game_state(text)

          unless text.include?('passes')
            @last_player = @previous_player
            if @previous_player != $bot.nick
              @tracker.stack.remove! @top_card
              @tracker.stack.remove! @top_card if @double_play
              #bot cards have been removed before!
              @tracker.adversaries[@previous_player].plays @top_card, @double_play unless @previous_player.nil?
            end
          end

          @bot.last_card = @top_card
          #reset double play state
          @double_play = false

          @lock = 0
        when /raws/
          update_game_state(text)
      end
    end
  end

  def initialize_game_variables
    @game_state = GAME_ON
    @not_started = false
    @game_start_draw = true
    @previous_player = nil
    @active_player = nil
    @last_player = nil
    @turn_counter = 0
    @card_history = []
  end

  def drawn_card c
    parsed = parse_hand(c, true)
    debug "[drawn_card] Parsed card: #{parsed}"
    if parsed.length < 2
      bot.drawn_card_action parsed[0]
    end
    @tracker.stack.remove! parsed
  end

  def host? nick
    $bot.config.host_nicks.member? nick
  end

  def parse_card_text(card_text)
    debug "[parse_card_text] #{card_text}"
    figure = card_text.match(/\[(.*)\]/)[1]
    color = card_text.match(/\d+/)[0]
    color = color.to_i
    debug "[parse_card_text] Parsed figure: #{figure} color: #{color}"
    UnoCard.parse(extract_color(color).to_s+figure.to_s)
  end

  def parse_hand(card_text, noreplace = false)
    unless card_text.match('c')
      puts '[parse_hand] Got hand, I guess.'
      card_text.strip!

      card_texts = card_text.split(3.chr)
      card_texts.delete_if { |ct| ct.to_s == nil.to_s }
      cards = []
      puts "[parse_hand] card_texts: #{card_texts.join('//')}"
      cards = card_texts.map{|ct| parse_card_text(ct) }
      puts "[parse_hand] parsed: #{cards.to_s}"
      @bot.replace_hand(cards) unless noreplace

      if @game_start_draw
        @game_start_draw = false
        @tracker.stack.remove! cards
      end

      return cards
    end
  end

  def extract_color(number)
    case number
      when 3
        'g' #:green
      when 4
        'r' #:red
      when 7
        'y' #:yellow
      when 12
        'b' #:blue
      when 13
        'w' #:wild
      else
        throw 'Wrong color number'
    end
  end

  def say(text)
    puts text
  end

  def add_message(msg)
    @messages.push(msg)
  end

  def get_message_queue
    msg = @messages
    @messages = []
    return msg
  end
end