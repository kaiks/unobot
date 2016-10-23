require_relative 'uno_card.rb'
require_relative 'uno_ai.rb'
require_relative 'uno_game_state.rb'

CardAction = Struct.new(:player, :action, :attribute, :previous_card)
PLAY_ACTION = 0
PICK_ACTION = 1
PASS_ACTION = 2

class UnoProxy
  attr_accessor :bot, :active_player, :top_card
  attr_reader :tracker
  attr_reader :game_state, :lock, :history#, :top_card
  attr_reader :turn_counter, :previous_player

  def initialize(bot = nil)
    @bot = bot
    @game_state = GameState.new
    @previous_player = nil
    @active_player = nil
    @game_players = []
    @history = []
    @top_card = nil
    @messages = []
    @not_started = true
    @tracker = Tracker.new
    @stack_size = 0
    @game_start_draw = true
    @double_play = false
    @turn_counter = 0
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

          (@double_play ? 2 : 1).times {
            @history << CardAction.new(@active_player, PLAY_ACTION, card, @top_card)
          }

          @tracker.update(text, @stack_size)
          update_game_state(text, card)


          @top_card = card


          unless text.include?('passes')
            if @previous_player != $bot.nick
              @tracker.stack.remove! @top_card, @double_play
              #bot cards have been removed before!
              @tracker.adversaries[@previous_player].plays @top_card, @double_play unless @previous_player.nil?
            end
          end

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


  def drawn_card c
    parsed = parse_hand(c)
    debug "[drawn_card] Parsed card: #{parsed}"
    if parsed.length == 1
      bot.drawn_card_action parsed[0]
    end
    @tracker.stack.remove! parsed
  end


  def parse_hand(card_text)
    unless card_text.match('c')
      debug '[parse_hand] Got hand, I guess.'
      card_text.strip!

      card_texts = card_text.split(3.chr)
      card_texts.delete_if { |ct| ct.to_s == nil.to_s }
      debug "[parse_hand] card_texts: #{card_texts.join('//')}"
      cards = card_texts.map { |ct| parse_card_text(ct) }
      debug "[parse_hand] parsed: #{cards.to_s}"
      @bot.hand = Hand.new(cards)

      if @game_start_draw
        @game_start_draw = false
        @tracker.stack.remove! cards
      end

      return cards
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

  private
  # in: number, out: character in rgbyw
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

  # in: text, out: UnoCard
  def parse_card_text(card_text)
    debug "[parse_card_text] #{card_text}"
    figure = card_text.match(/\[(.*)\]/)[1]
    color = card_text.match(/\d+/)[0]
    color = color.to_i
    debug "[parse_card_text] Parsed figure: #{figure} color: #{color}"
    UnoCard.parse(extract_color(color).to_s+figure.to_s)
  end

  # in: word, out: bool
  def host? nick
    $bot.config.host_nicks.member? nick
  end

  def initialize_game_variables
    @game_state.reset
    @not_started = false
    @game_start_draw = true
    @previous_player = nil
    @active_player = nil
    @turn_counter = 0
    @card_history = []
  end

  def update_game_state(text, card = nil)
    action_nick = text.split[0]
    action_text = text.split[1]

    if action_text == 'draws' || action_text == 'passes.' || action_text == 'passes'
      action = PASS_ACTION
      if action_text == 'draws' || @stack_size > 0
        action = PICK_ACTION
      end

      @game_state.update_game_state (action_nick != $bot.nick)
      @history << CardAction.new(action_nick, action, @stack_size, @top_card)
      @stack_size = 0
    elsif !card.nil?
      if card.is_offensive?
        @game_state.war!
      end

      if @game_state.war? && card.special_card?
        @game_state.warwd!
      end
    end
  end

end