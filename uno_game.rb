require_relative 'uno_card_stack.rb'
require_relative 'uno_player.rb'

class UnoGame
  attr_reader :players
  attr_reader :card_stack
  def initialize
    @players = []
    @stacked_cards = 0
    @card_stack = nil
    @played_cards = nil
    @top_card = nil
    @locked = false #= can't join game
  end


  def start_game
    @card_stack = CardStack.new
    @card_stack.fill
    @card_stack.shuffle!

    @played_cards = CardStack.new

    deal_cards_to_players

    put_card_on_top @card_stack.pick(1)[0]

    @players.shuffle!

    next_turn
  end

  def put_card_on_top card
    @stacked_cards += card.offensive_value
    @locked = true
    @played_cards << card
    @top_card = card
  end

  def next_turn
    @players.rotate!
    notify_player_turn @players[0]
    notify_top_card
  end

  def deal_cards_to_players
    @players.each { |p|
      deal_cards_to_player p
    }
  end

  def deal_cards_to_player p
    p.hand << @card_stack.pick(7)
  end



  def card_played card
    @locked = true
    @played_cards << card
  end


  def notify_player_turn p
    puts "Hey #{p} it's your turn!"
  end

  def add_player p
    if @locked
      notify "Sorry, it's not possible to join this game anymore."
    else
      @players.push p
      @players.shuffle!
    end
  end

  def notify_order
    puts 'Current player order is: ' + @players.join(' ')
  end

  def notify_top_card
    puts 'Top card: ' + @top_card.to_s
  end

  def notify text
    puts text
  end

  def notify_player(p,text)
    puts "[To #{p}]: #{text}"
  end

  def debug(text)
    puts "-debug- #{text}"
  end

  def player_card_play(player, card)
    debug "#{player} plays #{card}"
    if @players[0] == player
      if card.plays_after? @top_card
        put_card_on_top card
        player.hand.destroy(card)
        notify "#{player} played #{card}!"
        next_turn
      else
        notify "Sorry #{player}, that card doesn't play."
      end
    else
      notify "It's not your turn."
    end

  end
end

g = UnoGame.new
p1 = UnoPlayer.new('a')
p2 = UnoPlayer.new('b')
g.add_player(p1)
g.add_player(p2)
g.start_game
puts g.inspect
puts '---'
g.players.each {|p|
  puts "#{p}'s cards:"
  puts p.hand
}
g.player_card_play(p1,p1.hand[0])