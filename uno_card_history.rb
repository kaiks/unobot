PLAY_ACTION = 0
PICK_ACTION = 1
PASS_ACTION = 2
ACTION_STRINGS = %w(PLAY PICK PASS)

class CardAction
  attr_reader :player, :action, :attribute, :previous_card
  def initialize(player, action, attribute, previous_card)
    @player = player
    @action = action
    @attribute = attribute
    @previous_card = previous_card
  end

  def to_s
    "#{@player}: #{ACTION_STRINGS[@action]} #{@attribute.to_s} #{@previous_card.to_s}"
  end
end