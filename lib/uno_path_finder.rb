# Path finder class supposed to find optimal path given a hand.
# Input: hand, tracker
# Output: order of cards to be played

class PathFinder
  attr_reader :tracker
  def initialize(tracker)
    @tracker = tracker
  end

  def find(_hand)
    raise 'Virtual method'
  end
end
