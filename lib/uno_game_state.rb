require_relative 'uno_constants.rb'

include UnoConstants

class GameState
  attr_reader :game_state

  def initialize
    @game_state = GAME_OFF
  end

  def in_war?
    (has_state? WAR) || (has_state? WARWD)
  end

  def reset
    bot_debug 'Resetting game state'
    @game_state = GAME_ON
  end

  def update_game_state(bot_picked = false)
    remove_state WAR
    remove_state WARWD
    remove_state ONE_CARD if bot_picked
  end

  def clean?
    !((has_state? WAR) || (has_state? WARWD) || (has_state? ONE_CARD))
  end

  def war?
    has_state? WAR
  end

  def war!
    add_state WAR
  end

  def one_card?
    has_state? ONE_CARD
  end

  def one_card!
    add_state ONE_CARD
  end

  def warwd?
    has_state? WARWD
  end

  def warwd!
    add_state WARWD
  end

  def above_war?
    (has_state? WARWD) || (has_state? ONE_CARD)
  end

  def remove_war
    remove_state WAR
    remove_state WARWD
  end

  def to_s
    states = []
    states << 'WAR' if @game_state & WAR != 0
    states << 'WARWD' if @game_state & WARWD != 0
    states << 'ONE_CARD' if @game_state & ONE_CARD != 0
    states << 'GAME_OFF' if @game_state & GAME_OFF != 0
    states.join(' ')
  end

  private

  def add_state(f)
    bot_debug "Adding game state flag #{f}"
    @game_state |= f
  end

  def has_state?(state)
    bot_debug "[#{caller[1]} -> #has_state?] Checking game state: #{state} (is: #{game_state})"
    (game_state & state) == state
  end

  def remove_state(f)
    bot_debug "Removing game state flag #{f}"
    @game_state &= ~f
  end
end
