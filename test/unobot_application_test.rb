# frozen_string_literal: true

require_relative 'test_helper'
require 'json'
require 'open3'
require 'rbconfig'

class UnobotApplicationTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  PROBE = <<~'RUBY'.freeze
    require 'json'
    require './lib/uno_bot'
    puts JSON.generate(
      runtime: UNOBOT_RUNTIME,
      bridge: !!$unobot_v2_bridge,
      strategy: $unobot_strategy_manager&.selected_name,
      plugins: $bot.config.plugins.plugins.map(&:name)
    )
    $unobot_v2_bridge&.stop
  RUBY

  def test_default_installs_only_the_legacy_uno_plugin
    result = probe({})
    assert result[:status].success?, result[:stderr]
    assert_equal 'legacy', result[:json].fetch('runtime')
    assert_equal false, result[:json].fetch('bridge')
    assert_equal ['UnobotPlugin'], result[:json].fetch('plugins')
  end

  def test_v2_installs_strategy_manager_and_bridge_without_legacy_callbacks
    result = probe('UNO_RUNTIME' => 'v2', 'UNO_MESSAGING' => 'human', 'UNO_STRATEGY' => 'simple')
    assert result[:status].success?, result[:stderr]
    assert_equal 'v2', result[:json].fetch('runtime')
    assert_equal true, result[:json].fetch('bridge')
    assert_equal 'simple', result[:json].fetch('strategy')
    assert_empty result[:json].fetch('plugins')
  end

  def test_v2_configuration_fails_before_connecting_when_strategy_is_unavailable
    result = probe(
      'UNO_RUNTIME' => 'v2', 'UNO_MESSAGING' => 'machine', 'UNO_STRATEGY' => 'crushing',
      'UNO_TOURNAMENT_EXAMPLES' => '/definitely/missing'
    )
    refute result[:status].success?
    assert_match(/cannot configure crushing strategy/, result[:stderr])
    assert_match(/crushing_agent\.rb/, result[:stderr])
  end

  def test_legacy_rejects_strategy_or_messaging_settings_it_cannot_honor
    strategy = probe('UNO_RUNTIME' => 'legacy', 'UNO_STRATEGY' => 'simple')
    refute strategy[:status].success?
    assert_match(/supports only UNO_MESSAGING=human/, strategy[:stderr])

    messaging = probe('UNO_RUNTIME' => 'legacy', 'UNO_MESSAGING' => 'machine')
    refute messaging[:status].success?
    assert_match(/supports only UNO_MESSAGING=human/, messaging[:stderr])

    invalid = probe('UNO_RUNTIME' => 'legacy', 'UNO_STRATEGY' => 'random')
    refute invalid[:status].success?
    assert_match(/invalid UNO_STRATEGY/, invalid[:stderr])
  end

  private

  def probe(environment)
    clean = {
      'UNO_RUNTIME' => nil, 'UNO_MESSAGING' => nil, 'UNO_STRATEGY' => nil,
      'UNO_TOURNAMENT_EXAMPLES' => nil, 'UNO_SIMPLE_ARGV' => nil,
      'UNO_CRUSHING_ARGV' => nil
    }
    stdout, stderr, status = Open3.capture3(
      clean.merge(environment), RbConfig.ruby, '-rbundler/setup', '-Ilib', '-e', PROBE,
      chdir: ROOT
    )
    json_line = stdout.lines.reverse.find { |line| line.start_with?('{') }
    { stdout: stdout, stderr: stderr, status: status,
      json: json_line ? JSON.parse(json_line) : nil }
  end
end
