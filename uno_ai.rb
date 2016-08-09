require 'uno_hand.rb'
require 'uno_tracker.rb'
#todo: make path its own object
#todo: improve number of enemy cards tracking
#todo:
WAR = 1
WARWD = 2
ONE_CARD = 4
GAME_OFF = 16
GAME_ON = 0

ALGORITHM_CARD_NO_THRESHOLD = 8

class Bot
  attr_accessor :last_card
  attr_accessor :proxy, :hand
  attr_accessor :continue_skip

  def initialize(proxy, autostart = 1)
    @PLAY_DEBUG = $debug
    @proxy = proxy
    @hand = Hand.new
    @continue_skip = nil
    if autostart == 1
      @hand.add_random(8)

      @last_card = @hand[0]
      puts 'Starting the game with'
      play(@last_card)

      puts "Hello. My hand is #{@hand}"
      puts "Hello. My hand is #{@hand.bot_output}"
    else
      puts 'Hello.'
    end
  end

  def reset_hand
    @hand.each { |x| @hand.destroy(x) }
  end

  def set_debug(n)
    @PLAY_DEBUG = n
  end

  def play(card)
    #puts "<bot> pl #{card}"
    @proxy.add_message("pl #{card}")
    @hand.destroy(card)
  end

  def double_play(card)
    @proxy.add_message("pl #{card}#{card}")
    @hand.destroy(card)
    @hand.destroy(card)
  end

  def draw_n_fake(n)
    @hand.add_random(n)
  end

  def draw_fake
    puts 'pe'
    puts 'pa'
    draw_n_fake(1)
  end

  def draw
    debug 'Draw function'
    if game_has_state WAR
      debug '(We are in the war state)'
      @proxy.add_message('pa')
      @proxy.reset_game_state
    else
      @proxy.add_message('pe')
    end
  end

  def play_by_value
    while @proxy.lock == 1
      sleep(0.5)
    end

    if !(@continue_skip.nil?)
      play @continue_skip
      @continue_skip = nil
    end

    if @last_card.special_card? && game_has_state(ONE_CARD) && !game_has_state(WAR) && !game_has_state(WARWD)
      card = attempt_color_change
      if !card.nil?
        play card
        return
      end
    end



    if @hand.size < ALGORITHM_CARD_NO_THRESHOLD
      #longest_path = get_longest_path(@last_card)
      longest_path = calculate_best_path_by_probability_chain unless game_has_state WAR

      unless @proxy.game_state >= WAR || !path_valid?(longest_path)
        debug "[play_by_value] Apparently best option is #{longest_path}"
        if longest_path[2][0].is_regular? || longest_path[2][0].figure == 'reverse'
          unless longest_path[2][1].nil?
            #two cards,same color, same figure
            if longest_path[2][1] == longest_path[2][0]
              return double_play longest_path[0]
            end
          end
        end
        return play longest_path[0]
      end
    end


    playable_cards = @hand.playable_after @last_card
    debug "Playable cards are: #{playable_cards} GAME STATE IS #{@proxy.game_state}"

    playable_cards.sort_by! { |x| -(x.value%10) }


    #both players have one card
    if game_has_state(ONE_CARD) && path_valid?(longest_path) && turn_score(longest_path[2]) < 2 && longest_path[2].size == @hand.size && !game_has_state(WAR)
      debug 'We are assuming that we can end the game right now.'
      playable_cards[0].set_wild_color best_chain_color if playable_cards[0].special_card?
      return play playable_cards[0]
    end

    if game_has_state WAR
      playable_cards.select! { |c| c.is_war_playable? }
      playable_cards.select! { |c| c.figure == 'reverse' || c.special_card? } if (@proxy.game_state & WARWD) >= WARWD
    elsif game_has_state ONE_CARD
      playable_cards.select! { |c| c.is_offensive? || c.special_card? }
    end


    playable_special_cards = playable_cards.select { |c| c.special_card? }


    playable_special_cards.sort_by! { |c| c.figure }
    debug "Playable special cards: #{playable_special_cards}"
    debug "Playable cards: #{playable_cards}"

    playable_normal_cards = playable_cards - playable_special_cards
    debug "Playable normal cards: #{playable_normal_cards}"


    if playable_cards.length == 0
      return draw
    else
      if playable_normal_cards.length > 0
        debug "Playing normal card: #{playable_normal_cards[0]} [should only be here if >=#{ALGORITHM_CARD_NO_THRESHOLD} cards (#{@hand.size}]"
        raise "Tried playing normal card with naive algorithm, while having #{@hand.size} cards. \
          Should have #{ALGORITHM_CARD_NO_THRESHOLD}" if @hand.size < ALGORITHM_CARD_NO_THRESHOLD && @proxy.game_state == 0
        play playable_normal_cards[0]
      else
        #Non-wild cards should be rejected at this point. The first card should be wild.
        #if playable_special_cards[0].figure == 'wild+4'

        if @proxy.game_state < WARWD
          if turns_required(@hand) >= 2
            return draw
          end
        end
        if @hand.length > 7
          debug 'h>7'
          playable_special_cards[0].set_wild_color get_wild_color_heuristic
        else
          debug 'h<=7'
          playable_special_cards[0].set_wild_color best_chain_color
        end
        puts playable_special_cards[0].to_s
        play playable_special_cards[0]
      end
    end
  end

  def get_wild_color_heuristic
    #Get color list. Make them into [color, no. of cards with that color] array.
    #Find the largest number in such a couple. Return the color that is matched.
    best_color = Uno::NORMAL_COLORS.map{ |col| [col, @hand.select{|card| card.color == col}.length] }.max{|v| v[1]}[0]
    best_color ||= Uno.random_color
  end

  def path_valid? path
    path.exists_and_has(3) && path[2].size > 0 && path[1] > 0
  end

  def attempt_color_change
    wilds = @hand.select{|c| c.special_card? }
    if wilds.length > 0
      c = get_wild_color_heuristic
      #todo: make it not random
      while c == @last_card.color
        c = Uno.random_color
      end
      wilds[0].set_wild_color c
      return wilds[0]
    else
      skips = @hand.select{|c| c.figure == 'skip' }
      if skips.length > 1 && skips.select{|c| c.color == @last_card.color } > 0 && skips.select{|c| c.color != @last_card.color }.length > 0
        @continue_skip = skips.select{|c| c.color != @last_card.color}[0]
        return skips.select{|c| c.color == @last_card.color }[0]
      end
      #todo: reverse
    end
    return nil
  end

  def best_chain_color p = nil
    debug 'Getting best chain color'
    p ||= get_longest_path(UnoCard.new(:wild, 'wild'))
    if p.exists_and_has 1
      debug "Apparently it's #{p[0].color}"
      return p[0].color if p[0].color != :wild
    end

    debug 'Failed to find a color.'
    return most_valuable_color
  end

  def drawn_card_action c
    debug "Drawn card action with #{c}"
    @hand.push(c)
    if c.plays_after? @last_card
      if c.special_card?
        #war & <3 => wd4 play
        #war & >3 => wd4 play
        #nowar & <3 => any play
        #nowar & >3 => no play
        #but I don't think we are actually ever in a war state here.
        path = get_longest_path(UnoCard.new(:wild, 'wild'))

        if (path_valid?(path) && (turns_required(path[2]) < 2) || game_has_state(ONE_CARD))
          c.set_wild_color best_chain_color path
        else
          @proxy.add_message('pa')
          return
        end
      end
      play c
    else
      @proxy.add_message('pa')
    end
  end

  def all_cards_same_color?
    hand_colors = @hand.colors
    debug "Hand colors: #{hand_colors}"
    hand_colors.delete(:wild)
    debug "Are all cards same color? #{hand_colors.size < 2}"
    hand_colors.size < 2
  end

  def game_has_state(state)
    (@proxy.game_state & state) == state
  end

  def calculate_color_values
    @color_value = Array.new(4)
    4.times do |color|
      @color_value[color] = @hand.select { |card| card.color == Uno::COLORS[color] }.value || -1
    end
  end

  def most_valuable_color
    calculate_color_values
    most_valuable = @color_value.max
    most_valuable_color_index = @color_value.index(most_valuable)
    debug "Most valuable color is #{Uno::COLORS[most_valuable_color_index]}"
    return Uno::COLORS[most_valuable_color_index]
  end

  def war_cards
    @hand.select { |card| card.is_war_playable? }
  end

  def replace_hand(hand)
    @hand.delete_if { |x| true }
    hand.each { |i| @hand.push(i) }
  end


  def turn_score(sequence) #which should be minimized to play cards as fast as possible
    return 99999 if sequence == []

    last_index = sequence.size - 1
    score = 0
    sequence.each_with_index { |card, index|
      if index != last_index
        if card.figure == 'skip'
          score += 0
        elsif card.figure == 'reverse' #old code
          score += 1
        else
          score += 1
        end
      else
        score += 1
      end
    }
    return score
  end

  def collateral_score(sequence) #which should be minimized
    score = 0
    sequence.each_with_index { |card, index|
      score += card.playability_value * index
    }
    return score
  end

  def sequence_readable(sequence)
    sequence.map(&:to_s).reduce { |old, new| old += " #{new}" }
  end

  #works if first card is wild
  def assign_wildcard_color_with_sequence(sequence)
    sequence_copy = Array.new(sequence)
    sequence_copy.delete_if { |x| x.special_card? }

    if sequence_copy.length == 0
      sequence[0].set_wild_color Uno.random_color
    else
      sequence[0].set_wild_color sequence_copy[0].color
    end
  end

  #[best_sequence[0], maxchildren, best_sequence]
  def get_longest_path(card, accu = 0, past_cards = [])
    debug "lvl#{accu}: Trying to find the longest path for #{card} with #{accu}. Visited? #{card.visited}"
    return if card.visited == 1
    card.visited = 1


    playable = @hand.select { |c| (c.plays_after? card) && (c.visited == 0) && (c.figure != 'wild+4') }

    maxchildren = 0
    best_sequence = []
    best_turn_score = 999980


    playable.each { |i|
      this_past_cards_copy = []
      path_result = get_longest_path(i, accu + 1, this_past_cards_copy)
      this_path = [i] + path_result[2]
      this_child_max = path_result[1] + 1
      debug "lvl#{accu}: This path's max #{this_child_max}"
      if maxchildren < this_child_max

        maxchildren = this_child_max
        best_sequence = this_path
        debug "lvl#{accu}: Got new best path boys! Its #{sequence_readable(best_sequence)}"
        best_turn_score = turn_score best_sequence

      elsif maxchildren == this_child_max
        this_turn_score = turn_score(this_path)
        debug "lvl#{accu}: two paths were similar #{maxchildren}.
              Other info: this:#{sequence_readable(this_path)}
                          best:#{sequence_readable(best_sequence)}
              Now trying to establish better scores:
                this #{this_turn_score} best #{best_turn_score}"

        if best_turn_score > this_turn_score #smaller is better
          best_sequence = this_path
          best_turn_score = this_turn_score
        elsif best_turn_score == this_turn_score
          debug "lvl#{accu}: two paths were similar again
                Now trying to establish better: this #{collateral_score path_result[2]} best #{collateral_score best_sequence}"

          if (collateral_score best_sequence) > (collateral_score path_result[2])
            best_sequence = this_path
            best_turn_score = this_turn_score
          end

        end
      end
    }
    card.visited = 0
    debug "lvl#{accu}: returning #{[best_sequence[0], maxchildren, best_sequence]}"
    if !best_sequence[0].nil? && best_sequence[0].special_card?
      assign_wildcard_color_with_sequence best_sequence
    end
    return [best_sequence[0], maxchildren, best_sequence]

  end

  def debug text
    if @PLAY_DEBUG
      puts text
    end
  end


  ##NEW AI
  def probability(cards, prev_card, total_score = 0, prev_iter = 1)
    #completion condition
    puts "prob -> #{cards.map { |c| c.to_s }} --  #{prev_card} --  #{total_score} -- #{prev_iter}" if $debug
    return total_score if cards == []
    #reject any further calculation below 5% probability threshold
    return total_score if prev_iter > 0 && prev_iter < 0.05

    if total_score == 0
      return probability(cards.drop(1), cards[0], 1, 1) if cards[0].plays_after? prev_card
      return probability(cards.drop(1), cards[0], 0, 0)
    end
    prob_of_continuing = 0

    if (cards[0].figure == 'skip' && prev_card.figure == 'skip') || cards[0].special_card?
      prob_of_continuing = 1
      #puts (cards[0].figure == 'skip' && prev_card.figure == 'skip')
      #puts cards[0].special_card?
    elsif cards[0].to_s == prev_card.to_s || prev_card.color == :wild #aka: figure = old.figure + color = old.color
      prob_of_continuing = 0.9352
    elsif cards[0].color == prev_card.color || (cards[0].figure=='+2' && prev_card.figure == '+2') #same color, different figure
      prob_of_continuing = 0.88
    elsif cards[0].figure == prev_card.figure
      prob_of_continuing = 0.72
    else
      prob_of_continuing = 0.11
      #nothing in common, not much chance
    end

    return probability(cards.drop(1), cards[0], total_score + prev_iter*prob_of_continuing, prev_iter*prob_of_continuing)
  end

  def smart_probability(cards, prev_card, total_score = 0, prev_iter = 1)
    #completion condition
    puts "prob -> #{cards.map { |c| c.to_s }} --  #{prev_card} --  #{total_score} -- #{prev_iter}" if $debug
    return [total_score, prev_iter] if cards == []
    #reject any further calculation below 5% probability threshold
    return [total_score, prev_iter] if prev_iter > 0 && prev_iter < 0.05

    if total_score == 0
      return smart_probability(cards.drop(1), cards[0], 1, 1) if cards[0].plays_after? prev_card
      return smart_probability(cards.drop(1), cards[0], 0, 0)
    end
    prob_of_continuing = 0

    if (cards[0].figure == 'skip' && prev_card.figure == 'skip') || cards[0].special_card?
      prob_of_continuing = 1
      #puts (cards[0].figure == 'skip' && prev_card.figure == 'skip')
      #puts cards[0].special_card?
    elsif cards[0].to_s == prev_card.to_s || prev_card.color == :wild #aka: figure = old.figure + color = old.color
      prob_of_continuing = @proxy.tracker.change_from_wild_probability
    elsif cards[0].color == prev_card.color || (cards[0].figure=='+2' && prev_card.figure == '+2') #same color, different figure
      prob_of_continuing = @proxy.tracker.color_change_probability cards[0]
    elsif cards[0].figure == prev_card.figure
      prob_of_continuing = @proxy.tracker.figure_change_probability cards[0]
    else
      prob_of_continuing = @proxy.tracker.successive_probability cards[0], prev_card
      #nothing in common, not much chance
    end
    puts "tracker probability #{prob_of_continuing}" if $debug
    return smart_probability(cards.drop(1), cards[0], total_score + prev_iter*prob_of_continuing, prev_iter*prob_of_continuing)
  end


  #i should be able to get rid of most of this
  def special_card_penalty(cards, score)
    len = cards.length
    penalty_divisor = 1000000000

    cards.each_with_index { |c, i|
      cards_left = cards.drop(i+1)
      turns_left = turns_required(cards_left)
      playable_after = cards_left.select { |card| card.plays_after? c }
      penalty_divisor = 1000000000 - 100000000 + rand(100000000)
      if c.figure == 'wild+4'
        penalty_divisor = 1.05*(i+1)
        penalty_divisor += 0.15
        penalty_divisor -= 0.6 if @proxy.tracker.adversaries[@proxy.tracker.adversaries.to_a[0][0]].card_count > 3
        penalty_divisor += 0.5 if @hand.select{|c| !c.special_card?}.count <= 1
        penalty_divisor += 0.45 if score[1] > 0.75
      elsif c.figure == 'wild'
        penalty_divisor = 1.10*(i+1)
        penalty_divisor -= 0.5 if @proxy.tracker.adversaries[@proxy.tracker.adversaries.to_a[0][0]].card_count > 3
        penalty_divisor += 0.5 if @hand.select{|c| !c.special_card?}.count <= 1
        penalty_divisor += 0.45 if score[1] > 0.75
      elsif c.figure == '+2'
        if score[1] < 0.75
          penalty_divisor = 8
        else
          if i == (len-2) && playable_after.length == 1
            penalty_divisor = -4
          elsif i == (len-3) && cards[i+1].to_s == cards[i+2].to_s
            penalty_divisor = -4
          end
        end
      elsif c.figure == 'reverse'
        penalty_divisor = 15
      elsif c.figure == 'skip'
        other_skips = playable_after.select { |card| card.figure == 'skip' }
        non_skips = playable_after.select { |card| card.figure != 'skip' }.uniq { |card| card.to_s }
        non_wilds = non_skips.select { |card| !card.special_card? }
        #we premium skips if the next card is the only non wild
        if non_wilds.length == 1 && other_skips.length == 0 && (cards[i+1].plays_after?(c) && cards[i+1].figure != 'skip' && !cards[i+1].special_card?)
          penalty_divisor = -7
        elsif non_wilds.length > 1
          penalty_divisor = 5
        end
      end
      turns_left += 1

      penalty = (turns_left) / penalty_divisor.to_f
      penalty = -2.5 / turns_left.to_f if penalty < 0
      puts "TL:#{turns_left} PD#{penalty_divisor.to_f} Card #{i} #{c} removing #{penalty}" if $debug
      score[0] -= penalty
    }
    turn_multiplier = 1.0-0.15*turns_required(cards)
    turn_multiplier = 0.1 if turn_multiplier < 0
    puts "b4 multi: #{score[0]} after: #{score * turn_multiplier}" if $debug
    return score[0] * turn_multiplier
  end

  def first_non_wild_color(cards)
    c = Array.new(cards)
    while c.length > 0
      if c[0].special_card?
        c = c.drop(1)
      else
        #puts c if c.is_a? Array
        return c[0].color
      end
    end
    return Uno.random_color
  end

  #turns required:
  # r4 -> 1
  # rs r4 -> 1
  def turns_required(hand)
    counter = 0
    previous_card = @last_card
    hand.each { |c|
      if counter == 0
        counter += 1
        counter -= 0.1 if c.special_card?
        previous_card = c
        next
      end

      if c.to_s == previous_card.to_s
        next
      end
      if previous_card.figure == 'skip' && (c.color == previous_card.color || c.figure == 'skip')
        previous_card = c
        next
      end
      if c.special_card?
        if c.is_offensive?
          counter += 0.25
        else
          counter += 0.50
        end
        previous_card = c
        next
      end
      previous_card = c
      counter += 1
    }
    return counter
  end


  def calculate_best_path_by_probability_chain
    if @hand.length < 10
      best_score = 0
      best_permutation = []
      @hand.permutation(@hand.length) { |p|
        next unless p[0].plays_after? @last_card
        probability_output = smart_probability(p, @last_card)
        #puts p.map{|c|c.to_s}.to_s
        puts "Before: #{probability_output}" if $debug
        probability_score = special_card_penalty(p, probability_output)
        puts "After: #{probability_score}" if $debug
        #puts probability_output

        if probability_score > best_score
          best_score = probability_score
          best_permutation = p
        end
      }
      debug "Found best permutation: #{best_permutation.map { |c| c.to_s }.to_s}"
      if best_permutation.length > 0 && best_permutation[0].special_card?
        best_permutation[0].set_wild_color first_non_wild_color(best_permutation)
      end
      return [best_permutation[0], best_permutation.length, best_permutation] unless best_permutation == []
    else
      raise 'we should not be here'
    end
  end

end

