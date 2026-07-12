#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'

mode = ARGV.fetch(0, 'valid')
exit 17 if mode == 'immediate_exit'
sleep 10 if mode == 'non_reading'

while (line = $stdin.gets)
  request = JSON.parse(line)
  if request['type'] == 'game_end'
    next if %w[persistent_valid persistent_slow health_then_eof].include?(mode)
    break
  end
  next unless request['type'] == 'request_action'

  case mode
  when 'valid'
    puts JSON.generate('action' => 'draw')
  when 'malformed'
    puts '{'
  when 'array'
    puts '[]'
  when 'duplicate'
    puts JSON.generate('action' => 'draw')
    puts JSON.generate('action' => 'draw')
  when 'delayed_duplicate'
    puts JSON.generate('action' => 'draw')
    $stdout.flush
    sleep 0.2
    puts JSON.generate('action' => 'draw')
  when 'noise'
    puts 'diagnostic noise'
  when 'oversized'
    puts({ payload: 'x' * 100_000 }.to_json)
  when 'timeout'
    sleep 10
  when 'eof'
    exit 3
  when 'stderr_flood'
    2_000.times { $stderr.write('diagnostic-' + ('x' * 100) + "\n") }
    $stderr.flush
    puts JSON.generate('action' => 'draw')
  when 'invalid_action'
    puts JSON.generate('action' => 'play', 'card' => 'b9')
  when 'working_directory'
    puts JSON.generate('action' => (File.exist?('working-directory-marker') ? 'draw' : 'pass'))
  when 'persistent_valid'
    puts JSON.generate('action' => 'draw')
  when 'persistent_slow'
    sleep 0.1
    puts JSON.generate('action' => 'draw')
  when 'persistent_exit_slow'
    sleep 0.1
    puts JSON.generate('action' => 'draw')
  when 'exit_slow_response'
    sleep 0.1
    puts JSON.generate('action' => 'draw')
    $stdout.flush
    exit
  when 'health_then_eof'
    if defined?(@health_response_sent) && @health_response_sent
      exit
    else
      @health_response_sent = true
      puts JSON.generate('action' => 'draw')
    end
  end
  $stdout.flush
end
