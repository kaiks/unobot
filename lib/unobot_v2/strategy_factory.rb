# frozen_string_literal: true

require 'json'
require 'rbconfig'

require_relative 'configuration'
require_relative 'neural_agent'
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
      return build_neural(env: env, project_root: project_root) if normalized == 'neural'

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
      %w[simple crushing neural].to_h do |name|
        [name, -> { build(name, env: env, project_root: project_root) }]
      end.freeze
    end

    def limits
      { 'neural' => 1 }.freeze
    end

    def build_neural(env:, project_root:)
      examples = neural_examples(env: env, project_root: project_root)
      checkpoint = neural_checkpoint(env: env, examples: examples)
      python = env.fetch('UNO_NEURAL_PYTHON', 'python3').to_s
      raise Configuration::Error, 'UNO_NEURAL_PYTHON cannot be empty' if python.empty?

      stochastic = Configuration.boolean(
        env.fetch('UNO_NEURAL_STOCHASTIC', 'false'), 'UNO_NEURAL_STOCHASTIC'
      )
      argv = [python, '-m', 'rl_agent.sb3_opponent', '--model', checkpoint]
      argv << '--stochastic' if stochastic
      process = ProcessAgent.new(
        argv: argv, name: 'neural', lifecycle: :persistent, chdir: examples,
        startup_timeout: float_env(env, 'UNO_NEURAL_SPAWN_TIMEOUT', 5.0),
        request_timeout: float_env(env, 'UNO_NEURAL_COLD_TIMEOUT', NeuralAgent::DEFAULT_COLD_TIMEOUT),
        shutdown_timeout: float_env(env, 'UNO_AGENT_SHUTDOWN_TIMEOUT', 2.0),
        max_stdout_line: integer_env(env, 'UNO_AGENT_MAX_STDOUT_LINE', 65_536),
        stderr_tail_bytes: integer_env(env, 'UNO_AGENT_STDERR_TAIL_BYTES', 16_384)
      )
      NeuralAgent.new(
        process: process,
        cold_timeout: float_env(env, 'UNO_NEURAL_COLD_TIMEOUT', NeuralAgent::DEFAULT_COLD_TIMEOUT),
        warm_timeout: float_env(env, 'UNO_NEURAL_WARM_TIMEOUT', NeuralAgent::DEFAULT_WARM_TIMEOUT),
        backoff_initial: float_env(env, 'UNO_NEURAL_BACKOFF_INITIAL', NeuralAgent::DEFAULT_BACKOFF_INITIAL),
        backoff_max: float_env(env, 'UNO_NEURAL_BACKOFF_MAX', NeuralAgent::DEFAULT_BACKOFF_MAX),
        stochastic: stochastic
      )
    end

    def neural_examples(env:, project_root:)
      root = env['UNO_TOURNAMENT_EXAMPLES'] || discover_examples(project_root)
      expanded = root && File.expand_path(root)
      module_file = expanded && File.join(expanded, 'rl_agent', 'sb3_opponent.py')
      unless expanded && File.directory?(expanded) && File.readable?(expanded) && File.file?(module_file)
        raise Configuration::Error,
              'neural module was not found; set UNO_TOURNAMENT_EXAMPLES to an absolute Jedna tournament examples directory'
      end
      expanded
    end

    def neural_checkpoint(env:, examples:)
      configured = env['UNO_NEURAL_CHECKPOINT']
      path = configured || File.expand_path(
        '../models/jedna_multiplayer_v3.zip', examples
      )
      expanded = File.expand_path(path)
      unless File.file?(expanded) && File.readable?(expanded)
        raise Configuration::Error,
              'neural checkpoint is not a readable file; set UNO_NEURAL_CHECKPOINT to jedna_multiplayer_v3.zip'
      end
      expanded
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
