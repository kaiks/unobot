#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'

abort 'wrong module argv' unless ARGV.shift(2) == %w[-m rl_agent.sb3_opponent]
abort 'missing model argv' unless ARGV.shift == '--model'
checkpoint = ARGV.shift
stochastic = ARGV.shift == '--stochastic'
abort 'unexpected argv' unless ARGV.empty?
abort 'module cwd missing' unless File.file?('rl_agent/sb3_opponent.py')
File.open(checkpoint, 'rb') { |file| file.read(1) }

while (line = $stdin.gets)
  message = JSON.parse(line)
  next unless message['type'] == 'request_action'

  puts JSON.generate('action' => (stochastic ? 'pass' : 'draw'))
  $stdout.flush
end
