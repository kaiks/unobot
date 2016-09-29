require_relative 'uno_card.rb'
require_relative 'uno_ai.rb'
require_relative 'uno_game_state.rb'
class UnoProxy
  attr_accessor :bot, :active_player
  attr_reader :tracker
  attr_reader :game_state, :lock, :card_history
  attr_reader :turn_counter, :last_player

  def initialize(bot = nil)
    @bot = bot
    @game_state = GameState.new
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


  def update_game_state(text)
    if text.include?('raws') || text.include?('passes')
      adversary_passed = !((text.include? "#{$bot.nick} pass") || (text.include? "#{$bot.nick} draw"))
      @game_state.update adversary_passed
      @tracker.update(text, @stack_size)
      @stack_size = 0
    end
  end

  def parse_main(nick, text)
    if host? nick
      debug "[parse_main] Bot says: #{text}"
      case text
        when /must respond/
          @game_state.war!
          @stack_size = /\(total ([0-9]+)/.match(text)[1].to_i
          debug "Set stack size to #{@stack_size}"
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
          @not_started = true
        when /has just one card left/
          @game_state.one_card! unless text.include? $bot.nick
          @tracker.adversaries[text.split[1]].card_count = 2 unless text.include? $bot.nick
        when /.*Top card: .*/
          @lock = 1
          @tracker.reset_cache
          @previous_player = @active_player
          @turn_counter += 1

          @active_player = Misc::NICK_REGEX.match(text)[1]


          card_text_index = text.rindex(/\s/)
          card_text = text[card_text_index..-1]

          #always 1 card only, its by host
          card = parse_card_text(card_text)

          @card_history << card
          @card_history << card if @double_play

          @top_card = card

          if @top_card.is_offensive?
            @game_state.war!
          end

          if @game_state.war? && @top_card.special_card?
            @game_state.warwd!
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
          if text.include? $bot.nick
            if !text.include? "#{$bot.nick} passes"
              @tracker.calculate_color_probabilities
              $last_turn_message = Time.now unless text.include? "#{$bot.nick} passes"
              debug 'Opening the lock.'
              $lock = false
            end
          end
          @lock = 0

        when /raws/
          update_game_state(text)
      end
    end
  end

  def initialize_game_variables
    @game_state.reset
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
      debug '[parse_hand] Got hand, I guess.'
      card_text.strip!

      card_texts = card_text.split(3.chr)
      card_texts.delete_if { |ct| ct.to_s == nil.to_s }
      cards = []
      debug "[parse_hand] card_texts: #{card_texts.join('//')}"
      cards = card_texts.map{|ct| parse_card_text(ct) }
      debug "[parse_hand] parsed: #{cards.to_s}"
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

  def add_message(msg)
    @messages.push(msg)
  end

  def get_message_queue
    msg = @messages
    @messages = []
    return msg
  end
end