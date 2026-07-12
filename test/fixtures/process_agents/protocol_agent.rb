#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'

mode = ARGV.fetch(0, 'valid')

while (line = $stdin.gets)
  request = JSON.parse(line)
  break if request['type'] == 'game_end'
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
  end
  $stdout.flush
end
