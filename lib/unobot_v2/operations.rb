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
    MAX_RESPONSE_BYTES = 65_536
    DEFAULT_TIMEOUT = 5.0
    DEFAULT_SHUTDOWN_TIMEOUT = 30.0
    DEFAULT_WORKERS = 4
    DEFAULT_CLIENT_CAPACITY = 32
    COMMANDS = %w[health ready status reload fallback select restart].freeze
    STOP = Object.new.freeze

    attr_reader :socket_path

    def initialize(socket_path:, bridge:, primary:, shadow: nil, timeout: DEFAULT_TIMEOUT,
                   input_timeout: nil, output_timeout: nil,
                   shutdown_timeout: DEFAULT_SHUTDOWN_TIMEOUT,
                   worker_count: DEFAULT_WORKERS, client_capacity: DEFAULT_CLIENT_CAPACITY,
                   on_restart: nil)
      @socket_path = File.expand_path(String(socket_path))
      raise ArgumentError, 'operations socket path must be absolute' unless String(socket_path).start_with?('/')

      @bridge = bridge
      @primary = primary
      @shadow = shadow
      @input_timeout = positive_timeout(input_timeout || timeout, 'input timeout')
      @output_timeout = positive_timeout(output_timeout || timeout, 'output timeout')
      @shutdown_timeout = positive_timeout(shutdown_timeout, 'shutdown timeout')
      @worker_count = Integer(worker_count)
      @client_capacity = Integer(client_capacity)
      raise ArgumentError, 'operations worker count must be positive' unless @worker_count.positive?
      raise ArgumentError, 'operations client capacity must be positive' unless @client_capacity.positive?

      @on_restart = on_restart
      @mutex = Mutex.new
      @stopping = false
      @server = nil
      @accept_worker = nil
      @client_workers = []
      @client_queue = SizedQueue.new(@client_capacity)
      @active_clients = {}
      @started_at = monotonic_now
      @restart_requested = false
      @restart_failed = false
      @restart_worker = nil
      @restart_leases = []
    end

    def start
      @mutex.synchronize do
        return self if @accept_worker&.alive?
        raise RuntimeError, 'operations server has been stopped' if @stopping

        prepare_socket!
        @client_workers = Array.new(@worker_count) { Thread.new { consume_clients } }
        @accept_worker = Thread.new { serve }
      end
      self
    end

    def stop
      accept_worker, client_workers, restart_worker, active = @mutex.synchronize do
        return self if @stopping && !@accept_worker

        @stopping = true
        @server&.close
        [@accept_worker, @client_workers.dup, @restart_worker, @active_clients.keys]
      end
      active.each { |client| client.close rescue nil }
      deadline = monotonic_now + @shutdown_timeout
      join_bounded(accept_worker, deadline, 'accept')
      drain_queued_clients
      client_workers.length.times { @client_queue << STOP }
      client_workers.each { |worker| join_bounded(worker, deadline, 'client') }
      join_bounded(restart_worker, deadline, 'restart')
      @mutex.synchronize do
        @accept_worker = nil
        @client_workers.clear
        @restart_worker = nil
      end
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
        unless enqueue_client(client)
          write_response(client, failure(:server_busy, 'operations server is busy'), timeout: 0.1)
          client.close rescue nil
        end
      rescue IOError, Errno::EBADF
        break if @stopping
      rescue StandardError
        next unless @stopping

        break
      end
    end

    def enqueue_client(client)
      @client_queue.push(client, true)
      true
    rescue ThreadError
      false
    end

    def consume_clients
      loop do
        client = @client_queue.pop
        break if client.equal?(STOP)

        begin
          @mutex.synchronize { @active_clients[client] = true }
          handle(client)
        ensure
          @mutex.synchronize { @active_clients.delete(client) }
        end
      end
    end

    def handle(client)
      line = bounded_line(client)
      response = line ? dispatch(JSON.parse(line)) : failure(:invalid_request, 'request is missing or too large')
      write_response(client, response)
    rescue JSON::ParserError
      write_response(client, failure(:invalid_json, 'request must be one JSON object'))
    rescue StandardError
      nil
    ensure
      client.close rescue nil
    end

    def bounded_line(client)
      deadline = monotonic_now + @input_timeout
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

    def write_response(client, response, timeout: @output_timeout)
      data = JSON.generate(response) << "\n"
      if data.bytesize > MAX_RESPONSE_BYTES
        data = JSON.generate(failure(:response_too_large, 'operations response exceeded its bound')) << "\n"
      end
      deadline = monotonic_now + timeout
      offset = 0
      while offset < data.bytesize
        remaining = deadline - monotonic_now
        return false unless remaining.positive?

        ready = IO.select(nil, [client], nil, [remaining, 0.05].min)
        next unless ready

        written = client.write_nonblock(data.byteslice(offset, data.bytesize - offset), exception: false)
        next if written == :wait_writable

        offset += written
      end
      true
    rescue IOError, SystemCallError
      false
    end

    def health
      payload = status_payload
      healthy = healthy_payload?(payload)
      healthy ? success(payload) : failure(:unhealthy, 'model or bridge is not healthy', payload)
    end

    def ready
      payload = status_payload
      channels = payload.dig(:bridge, :configured_channels) || []
      joined = payload.dig(:bridge, :joined_channels) || []
      available = healthy_payload?(payload) && payload.dig(:bridge, :started) &&
                  payload.dig(:bridge, :timer_alive) &&
                  payload.dig(:bridge, :runtime, :ingress, :alive) &&
                  (channels - joined).empty?
      available ? success(payload) : failure(:not_ready, 'IRC session is not ready', payload)
    end

    def reload
      with_maintenance do |leases|
        results = managers.map do |manager|
          manager.health_check(maintenance: lease_for(manager, leases))
        end
        failed = results.find(&:error?)
        next failure(failed.code, 'strategy health check failed') if failed

        success(status_payload)
      end
    end

    def fallback
      with_maintenance do |_leases|
        transition = @bridge.runtime.transition_to('human')
        if transition.success?
          success(status_payload)
        else
          failure(transition.code, 'messaging transition was refused')
        end
      end
    end

    def select_strategy(request)
      target = request['strategy'].to_s
      return failure(:invalid_strategy, 'strategy is required') if target.empty?
      if target.casecmp?('neural') && @shadow&.selected_name == 'neural'
        return failure(:model_capacity, 'live and shadow strategies cannot both own the neural model')
      end

      with_maintenance do |leases|
        result = @primary.select(target, maintenance: lease_for(@primary, leases))
        result.success? ? success(status_payload) : failure(result.code, 'strategy selection was refused')
      end
    end

    def restart
      return failure(:restart_unavailable, 'restart callback is not configured') unless @on_restart

      admitted = @mutex.synchronize do
        next false if @restart_requested

        @restart_requested = true
      end
      return failure(:restart_pending, 'restart is already pending') unless admitted

      leases = acquire_maintenance
      if leases.is_a?(Hash)
        @mutex.synchronize { @restart_requested = false }
        return leases
      end
      @restart_leases = leases
      @restart_worker = Thread.new { perform_restart }
      success(restart: 'scheduled')
    end

    def perform_restart
      sleep 0.05
      @on_restart.call
    rescue StandardError
      release_maintenance(@restart_leases)
      @mutex.synchronize do
        @restart_failed = true
        @restart_requested = false
        @restart_leases = []
      end
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
        restart_pending: @restart_requested, restart_failed: @restart_failed
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
        maintenance: value[:maintenance],
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

    def healthy_payload?(payload)
      payload.dig(:model, :health).to_s == 'ready' && payload.dig(:model, :running) &&
        payload.dig(:bridge, :worker_alive)
    end

    def managers
      [@primary, @shadow].compact.sort_by(&:object_id)
    end

    def acquire_maintenance
      leases = []
      managers.each do |manager|
        lease = manager.acquire_maintenance
        if lease.respond_to?(:error?) && lease.error?
          release_maintenance(leases)
          return failure(lease.code, 'operator maintenance was refused')
        end
        leases << lease
      end
      leases.freeze
    end

    def release_maintenance(leases)
      Array(leases).reverse_each { |lease| lease.manager.release_maintenance(lease) }
    end

    def with_maintenance
      leases = acquire_maintenance
      return leases if leases.is_a?(Hash)

      yield leases
    ensure
      release_maintenance(leases) if leases && !leases.is_a?(Hash)
    end

    def lease_for(manager, leases)
      leases.find { |lease| lease.manager.equal?(manager) }
    end

    def drain_queued_clients
      loop do
        client = @client_queue.pop(true)
        client.close rescue nil unless client.equal?(STOP)
      rescue ThreadError
        break
      end
    end

    def join_bounded(worker, deadline, label)
      return unless worker

      remaining = deadline - monotonic_now
      worker.join(remaining) if remaining.positive?
      raise RuntimeError, "operations #{label} worker did not stop before its bounded command deadline" if worker.alive?
    end

    def positive_timeout(value, label)
      parsed = Float(value)
      raise ArgumentError, "operations #{label} must be positive" unless parsed.positive?

      parsed
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
