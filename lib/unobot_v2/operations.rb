# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'socket'
require 'thread'

module UnobotV2
  # Permissioned, local-only operations surface. The Unix socket is mode 0600
  # and every request is one bounded JSON object. It intentionally never
  # returns argv, environment values, model paths, private state, or stderr.
  class Operations
    MAX_REQUEST_BYTES = 4_096
    DEFAULT_TIMEOUT = 5.0
    COMMANDS = %w[health ready status reload fallback select restart].freeze

    attr_reader :socket_path

    def initialize(socket_path:, bridge:, primary:, shadow: nil, timeout: DEFAULT_TIMEOUT,
                   on_restart: nil)
      @socket_path = File.expand_path(String(socket_path))
      raise ArgumentError, 'operations socket path must be absolute' unless String(socket_path).start_with?('/')

      @bridge = bridge
      @primary = primary
      @shadow = shadow
      @timeout = Float(timeout)
      raise ArgumentError, 'operations timeout must be positive' unless @timeout.positive?

      @on_restart = on_restart
      @mutex = Mutex.new
      @stopping = false
      @server = nil
      @worker = nil
      @started_at = monotonic_now
      @restart_requested = false
    end

    def start
      @mutex.synchronize do
        return self if @worker&.alive?

        prepare_socket!
        @worker = Thread.new { serve }
      end
      self
    end

    def stop
      worker = @mutex.synchronize do
        return self if @stopping && !@worker

        @stopping = true
        @server&.close
        @worker
      end
      worker&.join(@timeout)
      if worker&.alive?
        worker.kill
        worker.join
      end
      @mutex.synchronize { @worker = nil }
      remove_socket
      self
    end

    def dispatch(request)
      command = request.is_a?(Hash) ? request['command'].to_s : ''
      return failure(:invalid_command, 'command is not supported') unless COMMANDS.include?(command)

      case command
      when 'health' then health
      when 'ready' then ready
      when 'status' then success(status_payload)
      when 'reload' then reload
      when 'fallback' then fallback
      when 'select' then select_strategy(request)
      when 'restart' then restart
      end
    rescue StandardError
      failure(:operation_failed, 'operation failed')
    end

    private

    def prepare_socket!
      directory = File.dirname(socket_path)
      prepare_directory!(directory)
      remove_socket
      @server = UNIXServer.new(socket_path)
      File.chmod(0o600, socket_path)
    end

    def prepare_directory!(directory)
      if File.exist?(directory) || File.symlink?(directory)
        stat = File.lstat(directory)
        unless stat.directory? && !stat.symlink? && stat.uid == Process.uid && (stat.mode & 0o077).zero?
          raise SecurityError, 'operations directory must be private, owned, and must not be a symlink'
        end
        return
      end

      parent = File.dirname(directory)
      parent_stat = File.lstat(parent)
      raise SecurityError, 'operations parent must be a real directory' unless parent_stat.directory? && !parent_stat.symlink?

      Dir.mkdir(directory, 0o700)
    end

    def remove_socket
      return unless File.exist?(socket_path) || File.socket?(socket_path)
      stat = File.lstat(socket_path)
      unless stat.socket? && !stat.symlink? && stat.uid == Process.uid
        raise SecurityError, 'refusing to replace an unowned or non-socket operations path'
      end

      File.unlink(socket_path)
    rescue Errno::ENOENT
      nil
    end

    def serve
      loop do
        client = @server.accept
        handle(client)
      rescue IOError, Errno::EBADF
        break if @stopping
      rescue StandardError
        next unless @stopping

        break
      end
    end

    def handle(client)
      line = bounded_line(client)
      response = line ? dispatch(JSON.parse(line)) : failure(:invalid_request, 'request is missing or too large')
      client.write(JSON.generate(response) << "\n")
    rescue JSON::ParserError
      client.write(JSON.generate(failure(:invalid_json, 'request must be one JSON object')) << "\n")
    rescue StandardError
      nil
    ensure
      client.close rescue nil
    end

    def bounded_line(client)
      deadline = monotonic_now + @timeout
      buffer = +''
      loop do
        return nil if buffer.bytesize > MAX_REQUEST_BYTES
        newline = buffer.index("\n")
        return buffer.byteslice(0, newline) if newline

        remaining = deadline - monotonic_now
        return nil unless remaining.positive?

        ready = IO.select([client], nil, nil, [remaining, 0.1].min)
        next unless ready

        chunk = client.read_nonblock(1_024, exception: false)
        return nil if chunk.nil?
        next if chunk == :wait_readable

        buffer << chunk
      end
    end

    def health
      payload = status_payload
      healthy = payload.dig(:model, :health).to_s == 'ready' && payload.dig(:model, :running) &&
                payload.dig(:bridge, :worker_alive)
      healthy ? success(payload) : failure(:unhealthy, 'model or bridge is not healthy', payload)
    end

    def ready
      payload = status_payload
      channels = payload.dig(:bridge, :configured_channels) || []
      joined = payload.dig(:bridge, :joined_channels) || []
      available = payload.dig(:model, :health).to_s == 'ready' && payload.dig(:model, :running) &&
                  payload.dig(:bridge, :started) &&
                  (channels - joined).empty?
      available ? success(payload) : failure(:not_ready, 'IRC session is not ready', payload)
    end

    def reload
      return failure(:game_active, 'reload is disabled during a game') if manager_active?

      results = [@primary, @shadow].compact.map(&:health_check)
      failed = results.find(&:error?)
      return failure(failed.code, 'strategy health check failed') if failed

      success(status_payload)
    end

    def fallback
      transition = @bridge.runtime.transition_to('human')
      transition.success? ? success(status_payload) : failure(transition.code, 'messaging transition was refused')
    end

    def select_strategy(request)
      target = request['strategy'].to_s
      return failure(:invalid_strategy, 'strategy is required') if target.empty?
      if target.casecmp?('neural') && @shadow&.selected_name == 'neural'
        return failure(:model_capacity, 'live and shadow strategies cannot both own the neural model')
      end

      result = @primary.select(target)
      result.success? ? success(status_payload) : failure(result.code, 'strategy selection was refused')
    end

    def restart
      return failure(:game_active, 'restart is disabled during a game') if manager_active?
      return failure(:restart_unavailable, 'restart callback is not configured') unless @on_restart

      admitted = @mutex.synchronize do
        next false if @restart_requested

        @restart_requested = true
      end
      return failure(:restart_pending, 'restart is already pending') unless admitted

      Thread.new do
        sleep 0.05
        @on_restart.call
      rescue StandardError
        nil
      end
      success(restart: 'scheduled')
    end

    def manager_active?
      [@primary, @shadow].compact.any?(&:active?)
    end

    def status_payload
      bridge = @bridge.diagnostics
      primary = sanitize_manager(@primary.diagnostics)
      shadow = @shadow && sanitize_manager(@shadow.diagnostics)
      model = model_status(primary, shadow)
      {
        uptime_seconds: (monotonic_now - @started_at).round(3),
        messaging: @bridge.mode, live_strategy: primary[:selected],
        shadow_strategy: shadow&.dig(:selected), bridge: sanitize_bridge(bridge),
        strategy: primary, shadow: shadow, model: model,
        restart_pending: @restart_requested
      }.compact.freeze
    end

    def sanitize_bridge(value)
      runtime = value[:runtime] || {}
      {
        mode: value[:mode], attached: value[:attached], started: value[:started],
        stopped: value[:stopped], connected_once: value[:connected_once],
        joined_channels: value[:joined_channels], configured_channels: value[:configured_channels],
        accepting: value[:accepting], worker_alive: value[:worker_alive],
        timer_alive: value[:timer_alive], queue_depth: value[:queue_depth],
        queue_capacity: value[:queue_capacity], error_count: value[:error_count],
        runtime: {
          callback_error_count: runtime[:callback_error_count], ingress: runtime[:ingress],
          channels: runtime[:channels]
        }
      }.freeze
    end

    def sanitize_manager(value)
      {
        selected: value[:selected], active_games: value[:active_games], shutdown: value[:shutdown],
        standby: sanitize_instances(value[:standby]), sessions: sanitize_sessions(value[:sessions])
      }.freeze
    end

    def sanitize_instances(groups)
      (groups || {}).transform_values { |instances| instances.map { |item| sanitize_agent(item) } }.freeze
    end

    def sanitize_sessions(sessions)
      (sessions || {}).transform_values do |session|
        { strategy: session[:strategy], diagnostics: sanitize_agent(session[:diagnostics] || {}) }.freeze
      end.freeze
    end

    def sanitize_agent(value)
      allowed = %i[name lifecycle status running game_active generation process_generation
                   stderr_bytes stderr_tail_bytes health deterministic consecutive_failures
                   retry_in_seconds cold_timeout warm_timeout]
      value.select { |key, _item| allowed.include?(key) }
           .merge(last_failure_code: value.dig(:last_failure, :code),
                  last_error_code: value.dig(:last_error, :code)).compact.freeze
    end

    def model_status(primary, shadow)
      neural = [primary, shadow].compact.flat_map do |manager|
        manager.fetch(:standby, {}).fetch('neural', []) +
          manager.fetch(:sessions, {}).values.filter_map do |session|
            session[:diagnostics] if session[:strategy] == 'neural'
          end
      end.first
      neural || { health: :not_configured }.freeze
    end

    def success(data = nil, **values)
      { ok: true, code: :ok, data: data, **values }.compact.freeze
    end

    def failure(code, message, data = nil)
      { ok: false, code: code, message: message.to_s.byteslice(0, 160), data: data }.compact.freeze
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
