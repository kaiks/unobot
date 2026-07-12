# frozen_string_literal: true

require_relative 'test_helper'
require 'json'
require 'open3'
require 'rbconfig'

class BotConfigTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  KEYS = %w[IRC_SERVER IRC_PORT IRC_NICK IRC_MESSAGES_PER_SECOND UNO_CHANNELS
            UNO_HOST_NICKS UNO_ADMIN_NICKS].freeze

  def test_defaults_and_valid_deployment_values
    defaults = probe({})
    assert defaults[:status].success?, defaults[:stderr]
    assert_equal 6667, defaults[:json].fetch('port')
    assert_equal '#kx', defaults[:json].fetch('channels').first

    configured = probe(
      'IRC_SERVER' => '127.0.0.1', 'IRC_PORT' => '16667', 'IRC_NICK' => 'Uno_Bot-1',
      'IRC_MESSAGES_PER_SECOND' => '3', 'UNO_CHANNELS' => '#one,&two,+local,!safe',
      'UNO_HOST_NICKS' => 'Host,Host_', 'UNO_ADMIN_NICKS' => 'Admin'
    )
    assert configured[:status].success?, configured[:stderr]
    assert_equal 16_667, configured[:json].fetch('port')
    assert_equal %w[#one &two +local !safe], configured[:json].fetch('channels')
  end

  def test_invalid_port_server_nick_lists_and_rate_fail_before_startup
    invalid = [
      ['IRC_PORT', '0'], ['IRC_PORT', '65536'], ['IRC_PORT', 'not-a-port'],
      ['IRC_SERVER', ''], ['IRC_SERVER', "irc.example\npoison"],
      ['IRC_NICK', 'bad nick'], ['UNO_CHANNELS', 'uno'],
      ['UNO_CHANNELS', '#ok,'], ['UNO_HOST_NICKS', 'Host,bad nick'],
      ['UNO_ADMIN_NICKS', ''], ['IRC_MESSAGES_PER_SECOND', '0']
    ]
    invalid.each do |name, value|
      result = probe(name => value)
      refute result[:status].success?, "#{name}=#{value.inspect}"
      assert_nil result[:json], "#{name}=#{value.inspect}"
    end
  end

  private

  def probe(values)
    script = <<~'RUBY'
      require 'json'
      require './bot_config'
      puts JSON.generate(
        server: BotConfig::SERVER, port: BotConfig::PORT, nick: BotConfig::NICK,
        rate: BotConfig::MESSAGES_PER_SECOND, channels: BotConfig::CHANNELS,
        hosts: BotConfig::HOST_NICKS, admins: BotConfig::ADMIN_NICKS
      )
    RUBY
    clean = KEYS.to_h { |key| [key, nil] }
    stdout, stderr, status = Open3.capture3(clean.merge(values), RbConfig.ruby, '-e', script, chdir: ROOT)
    line = stdout.lines.find { |candidate| candidate.start_with?('{') }
    { status: status, stderr: stderr, json: line && JSON.parse(line) }
  end
end
