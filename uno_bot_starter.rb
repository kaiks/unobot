require 'bundler/setup'
require './lib/uno_bot.rb'
require './lib/misc.rb'

# Signal handlers may only perform async-signal-safe work. Wake a normal Ruby
# thread through a self-pipe; that thread asks Cinch to quit, allowing the
# bridge and ProcessAgent ensure paths to terminate and reap the model pgroup.
signal_reader, signal_writer = IO.pipe
signal_writer.sync = true
previous_traps = %w[INT TERM].to_h do |signal|
  [signal, Signal.trap(signal) { signal_writer.write_nonblock("x", exception: false) }]
end
signal_thread = Thread.new do
  signal_reader.read(1)
  begin
    $bot.quit('termination signal')
  rescue StandardError
    # Cinch has no send queue before the first successful IRC connection, but
    # #quit sets its quitting flag before attempting to enqueue QUIT. The
    # reconnect loop will still stop and the ensure cleanup remains authoritative.
    nil
  end
rescue IOError
  nil
end
begin
  $bot.start
ensure
  previous_traps.each { |signal, handler| Signal.trap(signal, handler) }
  signal_writer.close rescue nil
  signal_reader.close rescue nil
  signal_thread.join(1)
  signal_thread.kill if signal_thread.alive?
  $unobot_operations&.stop if defined?($unobot_operations)
  $unobot_v2_bridge&.stop if defined?($unobot_v2_bridge)
end
