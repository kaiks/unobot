# frozen_string_literal: true

require 'json'
require 'rbconfig'

require_relative 'configuration'
require_relative 'process_agent'

module UnobotV2
  module StrategyFactory
    AGENT_FILES = {
      'simple' => 'simple_agent.rb',
      'crushing' => 'crushing_agent.rb'
    }.freeze
    ENV_ARGV = {
      'simple' => 'UNO_SIMPLE_ARGV',
      'crushing' => 'UNO_CRUSHING_ARGV'
    }.freeze

    module_function

    def build(name, env: ENV, project_root: File.expand_path('../..', __dir__))
      normalized = Configuration::STRATEGIES.include?(name.to_s.downcase) ? name.to_s.downcase :
        raise(Configuration::Error, "unknown strategy #{name.inspect}")
      if normalized == 'legacy'
        raise Configuration::Error,
              'UNO_RUNTIME=v2 with UNO_STRATEGY=legacy is unsupported: UnoAI requires historical IRC tracker state'
      end

      ProcessAgent.new(
        argv: argv_for(normalized, env: env, project_root: project_root),
        name: normalized,
        lifecycle: env.fetch('UNO_AGENT_LIFECYCLE', 'per_game'),
        startup_timeout: float_env(env, 'UNO_AGENT_STARTUP_TIMEOUT', 5.0),
        request_timeout: float_env(env, 'UNO_AGENT_REQUEST_TIMEOUT', 5.0),
        shutdown_timeout: float_env(env, 'UNO_AGENT_SHUTDOWN_TIMEOUT', 1.0),
        max_stdout_line: integer_env(env, 'UNO_AGENT_MAX_STDOUT_LINE', 65_536),
        stderr_tail_bytes: integer_env(env, 'UNO_AGENT_STDERR_TAIL_BYTES', 16_384)
      )
    rescue ProcessAgent::Error, ArgumentError => error
      raise Configuration::Error, "cannot configure #{normalized || name} strategy: #{error.message}"
    end

    def factories(env: ENV, project_root: File.expand_path('../..', __dir__))
      %w[simple crushing].to_h do |name|
        [name, -> { build(name, env: env, project_root: project_root) }]
      end.freeze
    end

    def argv_for(name, env:, project_root:)
      variable = ENV_ARGV.fetch(name)
      return parse_argv(env.fetch(variable), variable) if env.key?(variable)

      root = env['UNO_TOURNAMENT_EXAMPLES'] || discover_examples(project_root)
      unless root
        raise Configuration::Error,
              'Jedna tournament examples were not found; set UNO_TOURNAMENT_EXAMPLES or an agent argv variable'
      end
      script = File.expand_path(AGENT_FILES.fetch(name), root)
      [RbConfig.ruby, script]
    end

    def discover_examples(project_root)
      candidates = [
        File.expand_path('../jedna/extension-gems/jedna-tournaments/examples', project_root),
        File.expand_path('../../jedna/extension-gems/jedna-tournaments/examples', project_root),
        File.expand_path('../extension-gems/jedna-tournaments/examples', project_root)
      ]
      candidates.find { |path| File.file?(File.join(path, 'simple_agent.rb')) &&
                               File.file?(File.join(path, 'crushing_agent.rb')) }
    end

    def parse_argv(value, variable)
      parsed = JSON.parse(value)
      unless parsed.is_a?(Array) && !parsed.empty? && parsed.all? { |part| part.is_a?(String) && !part.empty? }
        raise Configuration::Error, "#{variable} must be a JSON array of non-empty strings"
      end

      parsed
    rescue JSON::ParserError => error
      raise Configuration::Error, "#{variable} is invalid JSON: #{error.message}"
    end

    def float_env(env, key, default)
      Float(env.fetch(key, default))
    rescue ArgumentError, TypeError
      raise Configuration::Error, "#{key} must be a number"
    end

    def integer_env(env, key, default)
      Integer(env.fetch(key, default))
    rescue ArgumentError, TypeError
      raise Configuration::Error, "#{key} must be an integer"
    end
  end
end
