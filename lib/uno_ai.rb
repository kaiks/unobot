require_relative 'uno_hand.rb'
require_relative 'uno_tracker.rb'
#todo: track what color the enemy didn't have in the last x rounds:
#using revamped card_history
#todo: use the above to make color change smart
#todo: use the above to create figure change
WAR = 1
WARWD = 2
ONE_CARD = 4
GAME_OFF = 16
GAME_ON = 0

ALGORITHM_CARD_NO_THRESHOLD = 8

class UnoAI
  attr_accessor :proxy, :hand
  attr_accessor :predefined_path
  attr_reader :busy

  def initialize(proxy, autostart = 1)
    @proxy = proxy
    @hand = Hand.new
    @predefined_path = []
    @turns_required_cache = {}
    @turn = nil
    @busy = false
    if autostart == 1
      @hand.add_random(8)

      #@last_card = @hand[0]
      puts 'Starting the game with'
      #play(@last_card)

      puts "Hello. My hand is #{@hand}"
      puts "Hello. My hand is #{@hand.bot_output}"
    else
      puts 'Hello.'
    end
  end

  def last_card
    @proxy.top_card
  end

  def reset_cache
    @turns_required_cache = {}
  end


  def play(card)
    @proxy.add_message("pl #{card}")
    @hand.destroy(card)
    @busy = false
    card
  end

  def double_play(card)
    @proxy.add_message("pl #{card}#{card}")
    @hand.destroy(card)
    @hand.destroy(card)
    @busy = false
    card
  end


  def draw
    bot_debug 'Draw function', 2
    if game_state.war?
      bot_debug '(We are in the war state)', 2
      @proxy.add_message('pa')
    else
      @proxy.add_message('pe')
    end
    @busy = false
  end


  def default_adversary
    tracker.default_adversary
  end

  def more_cards_than_adversary? adversary = nil
    adversary ||= default_adversary
    @hand.size > adversary.card_count
  end

  def game_state
    @proxy.game_state
  end

#todo: change color normally when last few cards include w by adversary
  def play_by_value
    bot_debug "Top card: #{last_card}", 2
    while @proxy.lock == 1
      sleep(0.5)
    end

    @busy = true
    if @predefined_path.length>0
      return play_predefined_path
    end

    if last_card.special_card? && @proxy.last_card_player!=$bot.nick && !game_state.in_war? && more_cards_than_adversary?
      random_threshold = 6
      randomly_change_color = rand(10) < random_threshold
      with_wd4 = true
      if has_one_card_or_late_game? || (randomly_change_color && default_adversary.card_count <= 4 && with_wd4 = false)
        color_change_success = attempt_color_change with_wd4
        if color_change_success
          return play_predefined_path
        end
      end
    end
    #todo: export that to play_aggressive and integrate with what's below
    if has_one_card_or_late_game? && !game_state.war? && (@hand.size >= ALGORITHM_CARD_NO_THRESHOLD || last_card.special_card? && @proxy.previous_player!=$bot.nick)
      playable_cards = @hand.playable_after(last_card).offensive
      if playable_cards.length > 0
        if playable_cards[0].special_card?
          playable_cards[0].set_wild_color get_wild_color_heuristic
        end
        return play playable_cards[0]
      else
        @predefined_path = get_offensive_path
        bot_debug 'Considering predefined path: ' + @predefined_path.to_s
        if @predefined_path.length > 0
          return play_predefined_path
        end
      end
    end


    bot_debug "Game state: #{game_state}"
    if @hand.size < ALGORITHM_CARD_NO_THRESHOLD
      longest_path = calculate_best_path_by_probability_chain unless game_state.in_war?

      if game_state.clean? && path_valid?(longest_path)
        bot_debug "[play_by_value] Normal best path: #{longest_path}"
        next_card = longest_path[2][0]
        unless longest_path[2][1].nil?
          #two cards,same color, same figure
          if longest_path[2][1].code == next_card.code
            if next_card.special_card? || next_card.figure==:skip
              return play longest_path[0]
            else
              return double_play longest_path[0]
            end
          end
        end
        return play longest_path[0]
      end
    end

    playable_cards = @hand.playable_after last_card
    bot_debug "Top card: #{last_card}. Playable cards are: #{playable_cards} GAME STATE IS #{game_state.game_state}"

    playable_cards.sort_by! { |x| -(x.value%10) }


    #both players have one card
    if game_state.one_card? && path_valid?(longest_path) && turn_score(longest_path[2]) < 2 && longest_path[2].size == @hand.size && !game_state.in_war?
      bot_debug 'We are assuming that we can end the game right now.'
      longest_path[0].set_wild_color best_chain_color if longest_path[0].special_card?
      if longest_path[2].length > 1 && longest_path[2][0].code == longest_path[2][1].code
        return double_play longest_path[0]
      else
        return play longest_path[0]
      end

    end

    #todo: if can play offensive, play offensive. Otherwise, play wild
    do_nothing = false
    if game_state.war?
      playable_cards.select! { |c| c.is_war_playable? } #+2 or reverse
      playable_cards.select! { |c| c.figure == :reverse || c.special_card? } if game_state.warwd?
    elsif game_state.one_card?
      if @hand.length < 5
        path = calculate_best_path_by_probability_chain

        if path_valid?(path)
          probability = smart_probability(path[2], last_card)
          if probability[1] >= 0.8 && turns_required(path[2]) <= 2
            do_nothing = true
          end
        end
      end
      playable_cards.select! { |c| c.is_offensive? || c.special_card? } unless do_nothing && playable_cards.offensive.empty?
    elsif has_one_card_or_late_game?
      playable_cards.select! { |c| c.is_offensive? || c.special_card? } if playable_cards.select { |c| c.is_offensive? }.length>0
    end

    playable_special_cards = playable_cards.wild


    playable_special_cards.sort_by! { |c| c.figure }
    bot_debug "Playable special cards: #{playable_special_cards}"
    bot_debug "Playable cards: #{playable_cards}"

    playable_normal_cards = playable_cards - playable_special_cards
    bot_debug "Playable normal cards: #{playable_normal_cards}"


    if playable_cards.length == 0
      return draw
    else
      if playable_normal_cards.length > 0
        bot_debug "Playing normal card: #{playable_normal_cards[0]} [should only be here if >=#{ALGORITHM_CARD_NO_THRESHOLD} cards (#{@hand.size}]"
        raise "Tried playing normal card with naive algorithm, while having #{@hand.size} cards. \
          Should have #{ALGORITHM_CARD_NO_THRESHOLD}" if @hand.size < ALGORITHM_CARD_NO_THRESHOLD && game_state.clean?
        play playable_normal_cards[0]
      else
        #Non-wild cards should be rejected at this point. The first card should be wild.
        #if playable_special_cards[0].figure == 'wild+4'

        if game_state.clean?
          if turns_required >= 2
            return draw
          end
        end
        if @hand.length >= ALGORITHM_CARD_NO_THRESHOLD
          bot_debug 'h>7'
          playable_special_cards[0].set_wild_color get_wild_color_heuristic
        else
          bot_debug 'h<=7'
          playable_special_cards[0].set_wild_color best_chain_color
        end
        play playable_special_cards[0]
      end
    end
  end

  def has_one_card_or_late_game?
    game_state.one_card? || default_adversary.card_count <= [1+@proxy.turn_counter/20, 5].min
  end

#Tries to find offensive path through skips or double reverses.
#Returns [first_card, rest_of_path], rest_of_path for predefined_path
#todo: extension to plays: brbr -> rrrr -> rs -> ys -> y+2
  def get_offensive_path
    #Check if we have a chance to play offensive cards at all
    offensive_cards = @hand.of_figure(:plus2)
    return [] if offensive_cards.length == 0
    #First attempt: try to build a 0 turn path with skips
    skips = @hand.of_figure(:skip)
    start = skips.playable_after last_card
    bridges = skips.select { |c| offensive_cards.map { |o| o.color }.include? c.color }
    if start.length > 0 && bridges.length > 0
      return [start[0], bridges[0], offensive_cards.find { |c| c.plays_after? bridges[0] }]
    else
      reverses = @hand.of_figure :reverse
      start = reverses.playable_after last_card
      return [] unless start.length > 1
      continuation = reverses.select { |c| offensive_cards.map { |o| o.color }.include? c.color }
      continuation = continuation.group_by { |i| i.to_s }.each_with_object({}) { |(k, v), h| h[k] = v if v.length>1 }.to_a
      if continuation.length > 0
        return [start[0], start[1], continuation[0][1][0], continuation[0][1][1],
                offensive_cards.find { |c| c.plays_after? continuation[0][1][0] }]
      end
    end
    []
  end

  def play_predefined_path
    bot_debug "#{@predefined_path}", 2
    raise 'Predefined path is empty' if @predefined_path.length == 0
    raise 'Predefined path is wrong: can\'t play' unless @predefined_path[0].plays_after? last_card
    if @predefined_path.length >= 2
      if @predefined_path[0].code == @predefined_path[1].code &&
          !@predefined_path[0].special_card? && !(@predefined_path[0].figure==:skip)
        double_play @predefined_path[0] unless @predefined_path[0].special_card?
        @predefined_path = @predefined_path.drop(2)
      end
    end

    play @predefined_path[0]
    @predefined_path = @predefined_path.drop(1)
  end

#todo
  def play_aggressive
  end

  def get_wild_color_heuristic
    #Get color list. Make them into [color, no. of cards with that color] array.
    #Find the largest number in such a couple. Return the color that is matched.
    best_color = @hand.select { |c| !c.special_card? }
    if best_color.length > 0
      best_color = best_color.group_by { |c| c.color }.map { |k, v| [k, v.length] }.
          max { |x, y| x[1]<=>y[1] }[0]
    else
      Uno.random_normal_color
    end
  end

  def path_valid? path
    path.exists_and_has(3) && !path[2].empty? && path[1] > 0
  end

  #we only get here if the last card played was wild
  #todo: look at the colors that he doesn't have
  def attempt_color_change(with_wd4 = true)
    wilds = @hand.select { |c| c.figure == :wild || with_wd4 && c.figure==:wild4 }
    if !wilds.empty?
      #order proposed colors first by what we have, second by what he DOESN'T have
      #the *1000 thing should be refactored
      hand_color_counts = @hand.group_by { |c| c.color }.each_with_object({}) { |(k, v), h| h[k] = v.length*1000 }
      #the line below is incorrect: ai shouldn't interact with tracker stack
      stack_color_counts = tracker.stack.group_by { |c| c.color }.each_with_object({}) { |(k, v), h| h[k] = v.length }

      hand_color_counts.each { |k, v| hand_color_counts[k] -= stack_color_counts[k] }

      hand_colors_ordered = hand_color_counts.to_a.sort_by { |x| -x[1] }.map { |c| c[0] }
      #stack_colors_ordered = stack_color_counts.to_a.sort_by { |x| x[1] }.map { |c| c[0] }
      stack_colors_ordered = Uno::NORMAL_COLORS.
          map{|x| [x, tracker.prob_cache[x]] }.
          sort_by{|x| x[1] }.
          map{|x| x[0] }
      colors_enemy_doesnt_have = Uno::NORMAL_COLORS.
          map{|x| [x,tracker.prob_cache[x]]}.
          select{|x| x[1] == 0.0 }.
          map{|x| x[0] }

      c = (colors_enemy_doesnt_have + hand_colors_ordered + stack_colors_ordered).uniq
      while c[0] == last_card.color || c[0] == :wild
        c = c.drop(1)
      end
      wilds[0].set_wild_color c[0]
      @predefined_path = [wilds[0]]
      bot_debug 'Considering predefined path: ' + @predefined_path.to_s
      return true
    else
      skips = @hand.of_figure(:skip)
      if skips.length > 1 && !skips.of_color(last_card.color).empty? && !skips.select { |c| c.color != last_card.color }.empty?
        @predefined_path = [skips.of_color(last_card.color)[0], skips.find { |c| c.color != last_card.color }]
        bot_debug 'Considering predefined path: ' + @predefined_path.to_s
        return true
      end

      reverses = @hand.of_figure :reverse
      start = reverses.playable_after last_card
      continuation = reverses.select { |c| c.color != last_card.color }
      if continuation.length > 0 && start.length > 1
        @predefined_path = [start[0], start[1], continuation[0]]
        bot_debug 'Considering predefined path: ' + @predefined_path.to_s
        return true
      end
    end
    return false
  end

  def best_chain_color p = nil
    bot_debug 'Getting best chain color'
    p ||= get_longest_path(UnoCard.new(:wild, :wild))
    if p.exists_and_has 1
      bot_debug "Apparently it's #{p[0].color}"
      return p[0].color if p[0].color != :wild
    end

    bot_debug 'Failed to find a color.'
    return most_valuable_color
  end

  def drawn_card_action c
    bot_debug "[drawn_card_action] Card: #{c}"
    if c.plays_after? last_card
      if c.special_card?
        if has_one_card_or_late_game? && (!(tracker.color_change_probability(last_card) == 0) || hand.length<=2)
          c.set_wild_color get_wild_color_heuristic
          return play c
        end

        path = calculate_best_path_by_probability_chain unless @hand.size > 7
        if !path_valid?(path) || path[0].figure != c.figure
          @proxy.add_message('pa')
          @busy = false
          return
        end
        c = path[0]
      end
      play c
    else
      @busy = false
      @proxy.add_message('pa')
    end
  end

  def calculate_color_values
    @color_value = Array.new(4)
    4.times do |color|
      @color_value[color] = @hand.of_color(Uno::COLORS[color]).value || -1
    end
  end

  def most_valuable_color
    calculate_color_values
    most_valuable = @color_value.max
    most_valuable_color_index = @color_value.index(most_valuable)
    bot_debug "Most valuable color is #{Uno::COLORS[most_valuable_color_index]}"
    return Uno::COLORS[most_valuable_color_index]
  end


  def turn_score(sequence) #which should be minimized to play cards as fast as possible
    return 99999 if sequence == []

    last_index = sequence.size - 1
    score = 0
    sequence.each_with_index { |card, index|
      if index != last_index
        if card.figure == :skip
          next
        elsif card.figure == :reverse #old code
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
  def assign_sequence_wild_color(sequence)
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
    bot_debug "lvl#{accu}: Trying to find the longest path for #{card} with #{accu}. Visited? #{card.visited}", 2
    return if card.visited == 1
    card.visited = 1


    playable = @hand.playable_after(card).select { |c| (c.visited == 0) && (c.figure != :wild4) }

    maxchildren = 0
    best_sequence = []
    best_turn_score = 999980


    playable.each { |i|
      this_past_cards_copy = []
      path_result = get_longest_path(i, accu + 1, this_past_cards_copy)
      this_path = [i] + path_result[2]
      this_child_max = path_result[1] + 1
      bot_debug "lvl#{accu}: This path's max #{this_child_max}", 3
      if maxchildren < this_child_max

        maxchildren = this_child_max
        best_sequence = this_path
        bot_debug "lvl#{accu}: Got new best path boys! Its #{sequence_readable(best_sequence)}", 3
        best_turn_score = turn_score best_sequence

      elsif maxchildren == this_child_max
        this_turn_score = turn_score(this_path)
        bot_debug "lvl#{accu}: two paths were similar #{maxchildren}.
              Other info: this:#{sequence_readable(this_path)}
                          best:#{sequence_readable(best_sequence)}
              Now trying to establish better scores:
                this #{this_turn_score} best #{best_turn_score}", 3

        if best_turn_score > this_turn_score #smaller is better
          best_sequence = this_path
          best_turn_score = this_turn_score
        elsif best_turn_score == this_turn_score
          bot_debug "lvl#{accu}: two paths were similar again
                Now trying to establish better: this #{collateral_score path_result[2]} best #{collateral_score best_sequence}", 3

          if (collateral_score best_sequence) > (collateral_score path_result[2])
            best_sequence = this_path
            best_turn_score = this_turn_score
          end

        end
      end
    }
    card.visited = 0
    bot_debug "lvl#{accu}: returning #{[best_sequence[0], maxchildren, best_sequence]}", 2
    if !best_sequence[0].nil? && best_sequence[0].special_card?
      assign_sequence_wild_color best_sequence
    end
    return [best_sequence[0], maxchildren, best_sequence]

  end



##NEW AI
  def smart_probability(cards, prev_card = nil)
    prev_card ||= last_card
    total_score = 0
    prev_iter = 1

    cards.each_with_index { |c, i|
      return [total_score,0.001] if prev_iter < 0.02
      if i == 0
        if c.plays_after? prev_card
          total_score = 1.0
          prev_iter = 1.0
        else
          total_score = 0.0
          prev_iter = 0.0
        end
        next
      else
        prev_card = cards[i-1]
      end

      prob_of_continuing = 0.0
      if (c.figure == :skip && prev_card.figure == :skip) || c.special_card?
        prob_of_continuing = 1.0
      elsif prev_card.figure == :skip && prev_card.color == c.color
        prob_of_continuing = 1.0
      elsif i>2 && cards[i-2].figure == :reverse && cards[i-1].code == cards[i-2].code && c.color==cards[i-1].color
        prob_of_continuing = 1.0
      elsif c.code == prev_card.code
        prob_of_continuing = 1.0 #double plays
      elsif prev_card.figure == :wild
        prob_of_continuing = 1.0 - (tracker.change_from_wild_probability * (@hand.length>2?0.2:1))
      elsif prev_card.figure == :wild4
        prob_of_continuing = 1.0 - (tracker.change_from_wd4_probability c.color)
      elsif prev_card.figure == :plus2
        #we will not be able to play it only if the next card is wd4 or reverse
        if c.figure == :plus2 || c.color == prev_card.color && c.figure == :reverse
          prob_of_continuing = 1.0 - (tracker.change_from_wd4_probability prev_card.color)
        elsif c.color == prev_card.color
          prob_of_continuing = 1.0 - (tracker.change_from_plus2_probability prev_card)
        else
          #temporary fix. y+2 -> g7 is really unlikely
          prob_of_continuing = (tracker.successive_probability c, prev_card)/3.0
        end
      elsif c.color == prev_card.color #same color, different figure
        if i == cards.length-1
          prob_of_continuing = 1.0 - tracker.forced_color_change_probability(prev_card)
        else
          prob_of_continuing = 1.0 - (tracker.color_change_probability prev_card)
        end
      elsif c.figure == prev_card.figure
        prob_of_continuing = 1.0 - (tracker.figure_change_probability prev_card)
      else
        #nothing in common, not much chance
        prob_of_continuing = tracker.successive_probability c, prev_card
      end
      bot_debug "#{prob_of_continuing} #{prev_card.to_s} -> #{c.to_s}", 2
      total_score += 0.1*prev_iter*prob_of_continuing+prob_of_continuing
      prev_iter = prev_iter*prob_of_continuing
    }
    bot_debug "For card set #{cards.map{|c|c.to_s}.to_s}"
    bot_debug "total_score: Returning #{total_score} #{prev_iter}", 2
    return [total_score, prev_iter]
  end


#i should be able to get rid of most of this
  def special_card_penalty(cards, score)
    bot_debug "Special card penalty: #{cards.map{|c|c.to_s}.join(' ')} #{score.to_s}", 3
    len = cards.length
    penalty_divisor = 1000000000
    adversary = tracker.default_adversary

    cards.each_with_index { |c, i|
      turns_left = turns_required(cards[i..-1])
      penalty_divisor = 1000000000 - 100000000 + rand(100000000)
      penalty_divisor -= 100000000 if c.figure == :reverse || c.figure==:plus2
      if c.figure == :wild4
        if score[1] < 0.7
          if i==0
            penalty_divisor = 0.1
          else
            penalty_divisor = 10.0/turns_left
          end
        end
      elsif c.figure == :wild
        if score[1] < 0.5
          if i==0
            penalty_divisor = 0.1
          else
            penalty_divisor = 100.0/turns_left
          end
        end
      end
      #turns_left += 1

      penalty = (turns_left) / penalty_divisor.to_f
      #bot_debug "#{cards_left.map { |c| c.to_s }.join(' ')}", 3
      bot_debug "TL:#{turns_left} PD#{penalty_divisor.to_f} Card #{i} #{c} removing #{penalty}. Score before: #{score[0]}", 3
      score[0] -= penalty
    }
    return score[0] if score[1] >= 0.95
    return score[0] * Math::sqrt((turn_score_b(cards)+0.001))
  end


  def first_non_wild_color(cards)
    c = Array.new(cards)
    while c.length > 0
      if c[0].special_card?
        c = c.drop(1)
      else
        return c[0].color
      end
    end
    return Uno.random_color
  end

#turns required:
# r4 -> 1
# rs r4 -> 1
  def turns_required(hand = nil)
    hand ||= @hand
    counter = 0
    previous_card = last_card
    skipped = false
    hand.each_with_index { |c, i|
      previous_card = hand[i-1] if i > 0

      if counter == 0
        counter += 1
        counter -= 0.1 if c.special_card?
        next
      end

      if c.code == previous_card.code
        next
      end
      if previous_card.figure == :skip && (c.color == previous_card.color || c.figure == :skip)
        next
      end

      if i > 1 && hand[i-1].code == hand[i-2].code && hand[i-1].figure == :reverse
        next
      end

      if c.special_card?
        if c.is_offensive?
          counter += 0.25
        else
          counter += 0.50
        end
        next
      end
      counter += 1
    }
    return counter
  end

#  n cards:
# 1. divide the interval into n equal parts
# 2. score is 1 for 1 turn
# 3. score is 0 for n turns
#   4. score is between (n-k)/n and (n-k+1)/n for k turns
#     4.b for a score between (n-k)/n and (n-k+1)/n, it's: (n-k)/n + score(the rest)/10

  def turn_score_b(hand = nil)
    hand ||= @hand
    counter = 0
    previous_card = last_card
    scores = []
    hand.each_with_index { |c, i|
      previous_card = hand[i-1] if i > 0

      if counter == 0
        counter += 1
        counter -= 0.1 if c.special_card?
        scores.push(hand.length - i)
        next
      end

      if c.code == previous_card.code
        next
      end

      if previous_card.figure == :skip && (c.color == previous_card.color || c.figure == :skip)
        next
      end

      if i > 1 && hand[i-1].code == hand[i-2].code && hand[i-1].figure == :reverse
        next
      end

      if c.special_card?
        if c.is_offensive?
          counter += 0.25
        else
          counter += 0.50
        end
        scores.push(hand.length - i)
        next
      end
      counter += 1
      scores.push(hand.length - i)
    }

    return calculate_score(scores)
  end

  def calculate_score scores

    n = scores[0]
    k = scores.length
    return 0.0 if n == k
    return 1.0 if k == 1
    calculation = calculate_score(scores.drop(1))/10.0
    return (n-k)*1.0/n*1.0 + calculation
  end

  def tracker
    @proxy.tracker
  end

  def calculate_best_path_by_probability_chain
    if @hand.length < 10
      best_score = 0
      best_permutation = []
      @hand.permutation(@hand.length) { |p|
        next unless p[0].plays_after? last_card
        probability_output = smart_probability(p)
        bot_debug "Before: #{probability_output}", 3
        probability_score = special_card_penalty(p, probability_output)
        bot_debug "After: #{probability_score}", 3

        if probability_score > best_score
          best_score = probability_score
          best_permutation = p
        end
      }
      bot_debug "Found best permutation: #{best_permutation.map { |c| c.to_s }.to_s}"
      if best_permutation.length > 0 && best_permutation[0].special_card?
        best_permutation[0].set_wild_color first_non_wild_color(best_permutation)
      end
      return [best_permutation[0], best_permutation.length, best_permutation] unless best_permutation == []
    else
      raise 'we should not be here'
    end
  end

  def wd4_sample
    @wd4 ||= UnoCard.parse('wd4')
  end

end

