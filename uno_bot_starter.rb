require 'bundler/setup'

# Install signal handling before loading the side-effectful application. Model
# health inference is allowed to finish under its existing cold deadline; the
# signal thread never raises into it. Cleanup then owns process-group reaping.
$unobot_termination_requested = false
$unobot_startup_finished = false
$unobot_restart_requested = false
signal_reader, signal_writer = IO.pipe
signal_writer.sync = true
previous_traps = %w[INT TERM].to_h do |signal|
  [signal, Signal.trap(signal) { signal_writer.write_nonblock("x", exception: false) }]
end
signal_thread = Thread.new do
  if signal_reader.read(1)
    $unobot_termination_requested = true
    loop do
      bot = $bot if defined?($bot)
      if bot
        begin
          bot.quit('termination signal')
        rescue StandardError
          # Cinch sets its quitting flag before using the send queue, which is
          # not present until the first connection. Ensure cleanup is authoritative.
        end
        break
      end
      break if $unobot_startup_finished

      sleep 0.01
    end
  end
rescue IOError
  nil
end
begin
  require './lib/uno_bot.rb'
  require './lib/misc.rb'
  $bot.start unless $unobot_termination_requested
ensure
  $unobot_operations&.stop if defined?($unobot_operations)
  $unobot_v2_bridge&.stop if defined?($unobot_v2_bridge)
  $unobot_startup_finished = true
  previous_traps.each { |signal, handler| Signal.trap(signal, handler) }
  signal_writer.close rescue nil
  signal_thread.join(1)
  signal_reader.close rescue nil
  raise RuntimeError, 'signal coordination thread did not stop' if signal_thread.alive?
end

exit 75 if $unobot_restart_requested
