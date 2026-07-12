# frozen_string_literal: true

require 'bundler/setup'
require 'fileutils'
require 'json'
require 'socket'
require 'tmpdir'
require 'timeout'

ROOT = File.expand_path('../..', __dir__)
HOST_ROOT = ENV.fetch('UNO_STAGE7_HOST_ROOT', File.expand_path('../ZbojeiJureq', ROOT))
JEDNA_ROOT = ENV.fetch('UNO_STAGE7_JEDNA_ROOT', File.expand_path('../jedna', ROOT))
CHANNEL = '#uno-e2e'
SEED = Integer(ENV.fetch('UNO_STAGE7_SEED', '7331'))

$LOAD_PATH.unshift(File.join(ROOT, 'lib'))
require 'unobot_v2'

class IrcClient
  attr_reader :socket

  def initialize(port:, nick:)
    @socket = TCPSocket.new('127.0.0.1', port)
    send_raw("NICK #{nick}")
    send_raw("USER #{nick} 0 * :#{nick}")
  end

  def send_channel(channel, text) = send_raw("PRIVMSG #{channel} :#{text}")
  def send_raw(line) = socket.write("#{line}\r\n")

  def read_line(timeout: 0.25)
    ready = IO.select([socket], nil, nil, timeout)
    ready ? socket.gets&.chomp : nil
  end
end

def allocate_port
  server = TCPServer.new('127.0.0.1', 0)
  server.local_address.ip_port
ensure
  server&.close
end

def spawn_child(env, *argv, log:)
  Process.spawn(env, *argv, pgroup: true, out: log, err: log)
end

def stop_child(pid)
  return unless pid

  Process.kill('TERM', -pid)
  Timeout.timeout(5) { Process.wait(pid) }
rescue Errno::ESRCH, Errno::ECHILD
  nil
rescue Timeout::Error
  Process.kill('KILL', -pid) rescue nil
  Process.wait(pid) rescue nil
end

def wait_port(port, timeout: 5)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  loop do
    TCPSocket.new('127.0.0.1', port).close
    return
  rescue Errno::ECONNREFUSED
    raise 'isolated ngIRCd did not become ready' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

    sleep 0.02
  end
end

Dir.mktmpdir('uno-stage7-e2e') do |directory|
  port = allocate_port
  config = File.join(directory, 'ngircd.conf')
  artifact = File.join(directory, 'decisions.jsonl')
  log_path = File.join(directory, 'processes.log')
  File.write(config, <<~CONFIG)
    [Global]
    Name = uno-e2e.local
    Info = isolated uno Stage 7
    Listen = 127.0.0.1
    Ports = #{port}
    PidFile = #{directory}/ngircd.pid
    MotdPhrase = isolated uno Stage 7

    [Options]
    DNS = no
    Ident = no
    PAM = no

    [Limits]
    MaxConnections = 32
    MaxConnectionsIP = 32
    MaxJoins = 8
    MaxNickLength = 16
    MaxPenaltyTime = 0

    [Channel]
    Name = #{CHANNEL}
    Modes = +tn
  CONFIG
  raise 'invalid generated ngIRCd config' unless system('ngircd', '-t', '-f', config, out: File::NULL, err: File::NULL)

  log = File.open(log_path, 'a')
  pids = []
  begin
    pids << spawn_child({}, 'ngircd', '-n', '-f', config, log: log)
    wait_port(port)
    common = { 'BUNDLE_GEMFILE' => File.join(__dir__, 'Gemfile') }
    pids << spawn_child(
      common.merge('UNO_MACHINE_ALLOWLIST' => 'unobot'),
      RbConfig.ruby, File.join(__dir__, 'host_runner.rb'), HOST_ROOT, port.to_s, CHANNEL, log: log
    )
    pids << spawn_child(
      common.merge(
        'UNO_MESSAGING' => 'machine', 'UNO_STRATEGY' => ENV.fetch('UNO_STRATEGY', 'simple'),
        'UNO_SHADOW_STRATEGY' => ENV.fetch('UNO_SHADOW_STRATEGY', 'none'),
        'UNO_AUTOJOIN' => 'true',
        'UNO_TOURNAMENT_EXAMPLES' => File.join(JEDNA_ROOT, 'extension-gems/jedna-tournaments/examples'),
        'UNO_NEURAL_CHECKPOINT' => File.join(
          JEDNA_ROOT, 'extension-gems/jedna-tournaments/checkpoints/overnight-dagger/checkpoint_17500000_steps.zip'
        )
      ),
      RbConfig.ruby, File.join(__dir__, 'unobot_runner.rb'), ROOT, port.to_s, CHANNEL, artifact, log: log
    )

    client = IrcClient.new(port: port, nick: 'Human')
    adapter = nil
    decisions = 0
    reload_sent = false
    reload_confirmed = false
    sent = lambda do |_target, command|
      client.send_channel(CHANNEL, command)
    end
    adapter = UnobotV2::Human::Adapter.new(
      channel: CHANNEL, own_nick: 'Human', host_nicks: ['Host'], transport: sent,
      on_request: lambda do |request|
        decisions += 1
        raise 'human decision bound exceeded' if decisions > 300
        reload_at = ENV['UNO_STAGE7_RELOAD_AT']&.to_i
        if reload_at&.positive? && decisions == reload_at
          client.send_channel(CHANNEL, '.uno reload')
          reload_sent = true
        end

        action = if request.playable_cards.any?
                   card = request.playable_cards.first
                   values = { action: 'play', card: card }
                   values[:wild_color] = 'red' if UnobotV2::Canonical::Cards.wild?(card)
                   UnobotV2::Canonical::Action.new(**values)
                 elsif request.available_actions.include?('draw')
                   UnobotV2::Canonical::Action.new(action: 'draw')
                 else
                   UnobotV2::Canonical::Action.new(action: 'pass')
                 end
        result = adapter.submit(action, decision_id: request.decision_id)
        raise "human action refused: #{result.code}" unless result.success?
      end
    )

    registered = false
    joined = false
    present = []
    game_created = false
    bot_joined = false
    dealt = false
    finished = false
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Float(ENV.fetch('UNO_STAGE7_TIMEOUT', '90'))
    until finished
      raise 'local IRC game timed out' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      line = client.read_line
      next unless line
      if line.start_with?('PING ')
        client.send_raw(line.sub('PING', 'PONG'))
        next
      end
      registered = true if line.match?(/\s001\s/)
      if registered && !joined
        client.send_raw("JOIN #{CHANNEL}")
        joined = true
      end
      if (names = line.match(/\s353\s+Human\s+[^ ]+\s+#{Regexp.escape(CHANNEL)}\s+:(.*)\z/))
        present |= names[1].split.map { |nick| nick.sub(/\A[~&@%+]/, '') }
      end
      if (join = line.match(/\A:([^! ]+)[^ ]* JOIN :?#{Regexp.escape(CHANNEL)}\z/))
        present << join[1] unless present.include?(join[1])
      end
      if joined && !game_created && %w[Host unobot].all? { |nick| present.any? { |seen| seen.casecmp?(nick) } }
        client.send_channel(CHANNEL, '.uno casual')
        game_created = true
      end

      match = line.match(/\A:([^! ]+)[^ ]* (PRIVMSG|NOTICE) ([^ ]+) :(.*)\z/)
      next unless match

      source, command, target, text = match.captures
      if source.casecmp?('Host')
        private_message = command == 'NOTICE' && target.casecmp?('Human')
        adapter.receive(UnobotV2::Human::Event.new(
          channel: CHANNEL, source: source, recipient: target, text: text,
          private: private_message
        )) unless command == 'NOTICE' && !private_message
        bot_joined = true if text == 'unobot joins the game'
        reload_confirmed = true if text == 'Uno reloaded.'
        if bot_joined && !dealt
          client.send_channel(CHANNEL, '.deal')
          dealt = true
        end
        finished = true if text.match?(/ gains \d+ points\.|loses instantly/)
      end
    end

    shadow_name = UnobotV2::Configuration.shadow_strategy(ENV)
    drain_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    records = []
    loop do
      records = File.readlines(artifact, chomp: true).map { |line| JSON.parse(line) }
      differentials = records.count { |record| record['type'] == 'differential' }
      shadows = records.select { |record| record['type'] == 'shadow' }
      break unless shadow_name
      break if shadows.length >= differentials
      raise 'shadow observations did not drain before deadline' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= drain_deadline

      sleep 0.02
    end
    differential = records.select { |record| record['type'] == 'differential' }
    raise 'no machine decisions were differentially checked' if differential.empty?
    raise 'differential mismatch was recorded' unless differential.all? { |record| record['equal'] }
    raise 'strategy failure was recorded' if records.any? { |record| record['type'] == 'strategy_error' }
    shadow = records.select { |record| record['type'] == 'shadow' }
    if shadow_name
      unless shadow.length == differential.length
        raise "shadow count #{shadow.length} did not match machine decision count #{differential.length}"
      end
      failures = shadow.reject { |record| record['status'] == 'ok' }
      raise "shadow gate recorded #{failures.length} errors or drops" unless failures.empty?
    end
    raise 'host did not confirm requested reload' if reload_sent && !reload_confirmed

    destination = ENV['UNO_STAGE7_ARTIFACT_DIR']
    retained_artifacts = if destination
                           FileUtils.mkdir_p(destination)
                           FileUtils.cp(artifact, destination)
                           FileUtils.cp(log_path, destination)
                           { retained: true, decisions: File.join(destination, File.basename(artifact)),
                             processes: File.join(destination, File.basename(log_path)) }
                         else
                           { retained: false }
                         end
    output = {
      result: 'ok', port: port, human_decisions: decisions,
      machine_decisions: differential.length,
      shadow_observations: shadow.length,
      seed: SEED, reload_exercised: reload_confirmed,
      artifacts: retained_artifacts
    }
    puts JSON.pretty_generate(output)
  ensure
    client&.socket&.close
    pids.reverse_each { |pid| stop_child(pid) }
    log.close
    if (destination = ENV['UNO_STAGE7_ARTIFACT_DIR'])
      FileUtils.mkdir_p(destination)
      FileUtils.cp(artifact, destination) if File.file?(artifact)
      FileUtils.cp(log_path, destination) if File.file?(log_path)
    end
  end
end
