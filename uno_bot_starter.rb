require 'bundler/setup'
require './lib/uno_bot.rb'
require './lib/misc.rb'
begin
  $bot.start
ensure
  $unobot_v2_bridge&.stop if defined?($unobot_v2_bridge)
end
