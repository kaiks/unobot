#gem install dbi
#gem install dbd-jdbc
#gem install jdbc-sqlite3
#require 'jdbc-sqlite3'

require 'sequel'

=begin
Makes sure that the 33% ratio rule is obeyed

A player can have at most 33% of games with unobot, unless he has less than 200 games

First check:
select games from uno where nick = 'irc_ninja';

then, if games < 200:

select game from player_action pa where pa.action = 0 and pa.player = 'cauchy' and
    exists (select game from player_action pa2 where pa2.game = pa2.game and pa2.action = 0 and pa2.player = 'unobot') and
    exists (select 1 from games where id = pa.game and end is not null)

better yet
select count(game) from player_action pa where pa.action = 0 and pa.player = 'cauchy' and exists (select game from player_action pa2 where pa.game = pa2.game and pa2.action = 0 and pa2.player = 'unobot') and exists (select 1 from games where id = pa.game and end is not null)

=end

$db = Sequel.connect(
    'jdbc:sqlite:uno.db') # need to set the driver





#percentage of games played with unobot
def game_ratio(nick)
  pa = $db[:player_action]
  udb = $db[:uno]

  games = udb.where(:nick => nick).all[0]

  dataset = $db["SELECT count(game) FROM player_action pa where pa.action = 0 and pa.player = ?
  and exists (select game from player_action pa2 where pa.game = pa2.game and pa2.action = 0 and pa2.player like 'unobot%')
  and exists (select 1 from games where id = pa.game and end is not null)", nick]
  puts dataset.all[0].to_a[0][1].to_f, games[:games].to_f
  return dataset.all[0].to_a[0][1].to_f/games[:games].to_f
end

#temporarily disabled
#todo: make sure it works
def can_play_with?(nick)
	puts "checking for #{nick}"
  true
    #games = $db[:uno].where(:nick => nick).all[0][:games] unless
	#games ||= 0
  #games < 200 or game_ratio(nick) < 0.33
end

