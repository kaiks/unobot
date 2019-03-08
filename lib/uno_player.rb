class UnoPlayer
  attr_accessor :hand
  attr_reader :nick
  def initialize(nick)
    @joined = Time.now
    @nick = nick
    @hand = Hand.new
  end

  def to_s
    nick
  end
end

class UnoAdversary < UnoPlayer
  attr_accessor :card_count
  def initialize(nick)
    super(nick)
    @card_count = 0
  end

  def draw(n = 1)
    bot_debug "UnoAdversary#draws(#{n})"
    @card_count += n
  end

  def plays(card, double = false)
    bot_debug "UnoAdversary#plays(#{card}, false)"
    @card_count -= 1
    @card_count -= 1 if double
  end
end
