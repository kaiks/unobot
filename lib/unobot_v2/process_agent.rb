# frozen_string_literal: true

require 'json'
require 'open3'
require 'rbconfig'
require 'thread'

require_relative 'action_validator'

module UnobotV2
  # Bounded JSON-lines strategy process. Commands are argv arrays and are never
  # passed through a shell. One instance serves one request at a time.
  class ProcessAgent
    class Error < StandardError
      attr_reader :code

      def initialize(code, message)
        @code = code.to_sym
        super(message)
      end
    end

    DEFAULT_STARTUP_TIMEOUT = 5.0
    DEFAULT_REQUEST_TIMEOUT = 5.0
    DEFAULT_SHUTDOWN_TIMEOUT = 1.0
    DEFAULT_MAX_STDOUT_LINE = 64 * 1024
    DEFAULT_STDERR_TAIL = 16 * 1024
    READ_CHUNK = 4 * 1024

    attr_reader :name, :lifecycle

    def initialize(argv:, name:, lifecycle: :per_game,
                   startup_timeout: DEFAULT_STARTUP_TIMEOUT,
                   request_timeout: DEFAULT_REQUEST_TIMEOUT,
                   shutdown_timeout: DEFAULT_SHUTDOWN_TIMEOUT,
                   max_stdout_line: DEFAULT_MAX_STDOUT_LINE,
                   stderr_tail_bytes: DEFAULT_STDERR_TAIL,
                   clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @argv = validate_argv(argv).freeze
      @name = name.to_s.dup.freeze
      raise ArgumentError, 'agent name cannot be empty' if @name.empty?

      @lifecycle = lifecycle.to_sym
      raise ArgumentError, 'lifecycle must be per_game or persistent' unless %i[per_game persistent].include?(@lifecycle)

      @startup_timeout = positive_float(startup_timeout, 'startup timeout')
      @request_timeout = positive_float(request_timeout, 'request timeout')
      @shutdown_timeout = positive_float(shutdown_timeout, 'shutdown timeout')
      @max_stdout_line = positive_integer(max_stdout_line, 'maximum stdout line')
      @stderr_tail_bytes = positive_integer(stderr_tail_bytes, 'stderr tail')
      @clock = clock
      @state_mutex = Mutex.new
      @request_mutex = Mutex.new
      @write_mutex = Mutex.new
      @lifecycle_mutex = Mutex.new
      @stderr_mutex = Mutex.new
      @generation = 0
      @stderr_tail = +''
      @stderr_bytes = 0
      @stdout_buffer = +''
      @status = :stopped
      @last_error = nil
      @game_key = nil
      @closed = false
      validate_command!
    end

    def start_game(game_key)
      key = game_key.to_s
      raise Error.new(:invalid_game, 'game key cannot be empty') if key.empty?

      current = @state_mutex.synchronize { @game_key }
      return self if current == key

      end_game(current, reason: 'game_replaced') if current
      token = @state_mutex.synchronize do
        raise Error.new(:shutdown, 'agent has been shut down') if @closed

        @game_key = key
        @generation += 1
      end
      start_process(expected_generation: token) unless running?
      self
    end

    def decide(request)
      @request_mutex.synchronize do
        token = @state_mutex.synchronize do
          raise Error.new(:shutdown, 'agent has been shut down') if @closed
          raise Error.new(:no_game, 'start_game must be called first') unless @game_key

          @generation += 1
        end
        start_process(expected_generation: token) unless running?
        reject_pending_stdout!
        write_request(request, token)
        raw = read_response(token, deadline: now + @request_timeout)
        parsed = parse_response(raw)
        ensure_current!(token)
        action = ActionValidator.validate(parsed, request: request)
        @state_mutex.synchronize { @status = :running }
        action
      rescue Error, Canonical::ValidationError => error
        fail_request(error)
        raise
      rescue StandardError => error
        wrapped = Error.new(:process_error, error.message)
        fail_request(wrapped)
        raise wrapped
      end
    end

    def end_game(game_key = nil, reason: 'game_end')
      should_end = @state_mutex.synchronize do
        next false unless @game_key
        next false if game_key && @game_key != game_key.to_s

        @generation += 1
        @game_key = nil
        true
      end
      return false unless should_end

      if running?
        notify(type: 'game_end', reason: reason.to_s)
        stop_process(graceful: true) if lifecycle == :per_game
      end
      true
    end

    def cancel(reason: 'cancelled')
      @state_mutex.synchronize do
        @generation += 1
        @game_key = nil
        @last_error = { code: :cancelled, message: reason.to_s }.freeze
      end
      stop_process(graceful: false)
      true
    end

    def shutdown
      already_closed = @state_mutex.synchronize do
        old = @closed
        @closed = true
        @generation += 1
        @game_key = nil
        old
      end
      return self if already_closed

      stop_process(graceful: true)
      @state_mutex.synchronize { @status = :shutdown }
      self
    end

    def running?
      @state_mutex.synchronize { !!@wait_thread&.alive? }
    end

    def retry_capable? = false

    # Deliberately excludes argv, environment, and stderr contents.
    def diagnostics
      @state_mutex.synchronize do
        {
          name: name, lifecycle: lifecycle, status: @status,
          running: !!@wait_thread&.alive?, game_active: !@game_key.nil?,
          generation: @generation, last_error: @last_error,
          stderr_bytes: @stderr_mutex.synchronize { @stderr_bytes },
          stderr_tail_bytes: @stderr_mutex.synchronize { @stderr_tail.bytesize }
        }.freeze
      end
    end

    private

    def validate_argv(argv)
      unless argv.is_a?(Array) && !argv.empty? && argv.all? { |part| part.is_a?(String) && !part.empty? }
        raise ArgumentError, 'agent argv must be a non-empty array of non-empty strings'
      end

      argv.map { |part| part.dup.freeze }
    end

    def validate_command!
      executable = @argv.first
      unless executable_available?(executable)
        raise Error.new(:missing_executable, "agent executable does not exist: #{File.basename(executable)}")
      end
      return unless @argv[1] && (ruby_executable?(executable) || script_path?(@argv[1]))
      return if File.file?(@argv[1]) && File.readable?(@argv[1])

      raise Error.new(:missing_script, "agent script does not exist: #{File.basename(@argv[1])}")
    end

    def executable_available?(executable)
      return File.file?(executable) && File.executable?(executable) if executable.include?(File::SEPARATOR)

      ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? do |directory|
        path = File.join(directory, executable)
        File.file?(path) && File.executable?(path)
      end
    end

    def ruby_executable?(executable)
      File.basename(executable).match?(/\Aruby(?:\d+(?:\.\d+)*)?\z/)
    end

    def script_path?(argument)
      argument.include?(File::SEPARATOR) || argument.match?(/\.(?:rb|py)\z/i)
    end

    def start_process(expected_generation: nil)
      failure = nil
      @lifecycle_mutex.synchronize do
        wait_thread = nil
        begin
          @state_mutex.synchronize do
            raise Error.new(:shutdown, 'agent has been shut down') if @closed
            if expected_generation && (@generation != expected_generation || @game_key.nil?)
              raise Error.new(:cancelled, 'agent start was cancelled')
            end
            return if @wait_thread&.alive?
            cleanup_io_locked
            @status = :starting
          end

          result = Queue.new
          starter = Thread.new do
            begin
              result << [:ok, Open3.popen3(*@argv, pgroup: true)]
            rescue StandardError => error
              result << [:error, error]
            end
          end
          unless starter.join(@startup_timeout)
            starter.kill
            raise Error.new(:startup_timeout, 'agent startup exceeded its deadline')
          end
          kind, value = result.pop
          raise Error.new(:startup_failed, value.message) if kind == :error

          stdin, stdout, stderr, wait_thread = value
          stdin.sync = true
          cancelled = @state_mutex.synchronize do
            invalid = @closed || (expected_generation &&
              (@generation != expected_generation || @game_key.nil?))
            unless invalid
              @stdin, @stdout, @stderr, @wait_thread = stdin, stdout, stderr, wait_thread
              @stdout_buffer = +''
              @status = :running
            end
            invalid
          end
          raise Error.new(:cancelled, 'agent start was cancelled') if cancelled

          start_stderr_drain(stderr)
          Thread.pass
          raise Error.new(:startup_failed, "agent exited during startup (status #{wait_thread.value.exitstatus})") unless wait_thread.alive?
        rescue Error => error
          failure = error
          if wait_thread&.alive?
            terminate(wait_thread, 'TERM')
            wait_thread.join(@shutdown_timeout)
            terminate(wait_thread, 'KILL') if wait_thread.alive?
            wait_thread.join(@shutdown_timeout)
          end
          [stdin, stdout, stderr].compact.each { |io| io.close rescue nil }
          cleanup_process_locked
        end
      end

      raise failure if failure
    end

    def write_request(request, token)
      @write_mutex.synchronize do
        ensure_current!(token)
        line = JSON.generate(request.protocol_h)
        stdin = @state_mutex.synchronize { @stdin }
        raise Error.new(:not_running, 'agent input is unavailable') unless stdin

        stdin.write(line)
        stdin.write("\n")
        stdin.flush
      end
    rescue Errno::EPIPE, IOError => error
      ensure_current!(token)
      raise Error.new(:process_eof, error.message)
    end

    def read_response(token, deadline:)
      loop do
        ensure_current!(token)
        if (newline = @stdout_buffer.index("\n"))
          line = @stdout_buffer.slice!(0, newline + 1)
          raise Error.new(:oversized_output, 'agent stdout line exceeded limit') if line.bytesize > @max_stdout_line
          reject_duplicate_buffer!
          return line.chomp
        end
        raise Error.new(:oversized_output, 'agent stdout line exceeded limit') if @stdout_buffer.bytesize > @max_stdout_line

        remaining = deadline - now
        raise Error.new(:request_timeout, 'agent request exceeded its deadline') unless remaining.positive?

        stdout = @state_mutex.synchronize { @stdout }
        raise Error.new(:process_eof, 'agent output is unavailable') unless stdout
        ready = IO.select([stdout], nil, nil, [remaining, 0.05].min)
        next unless ready

        chunk = stdout.read_nonblock(READ_CHUNK, exception: false)
        case chunk
        when :wait_readable then next
        when nil
          ensure_current!(token)
          raise Error.new(:process_eof, 'agent closed stdout')
        else @stdout_buffer << chunk
        end
      end
    end

    def reject_pending_stdout!
      stdout = @state_mutex.synchronize { @stdout }
      return unless stdout

      while IO.select([stdout], nil, nil, 0)
        chunk = stdout.read_nonblock(READ_CHUNK, exception: false)
        break if chunk == :wait_readable
        raise Error.new(:process_eof, 'agent closed stdout') if chunk.nil?

        @stdout_buffer << chunk
        raise Error.new(:oversized_output, 'agent stdout buffer exceeded limit') if @stdout_buffer.bytesize > @max_stdout_line
      end
      return if @stdout_buffer.empty?

      raise Error.new(:unexpected_output, 'agent wrote stdout outside a request')
    end

    def reject_duplicate_buffer!
      return if @stdout_buffer.empty?

      code = @stdout_buffer.include?("\n") ? :duplicate_output : :noisy_output
      raise Error.new(code, 'agent emitted more than one response')
    end

    def parse_response(line)
      value = JSON.parse(line)
      raise Error.new(:invalid_response, 'agent response must be one JSON object') unless value.is_a?(Hash)

      value
    rescue JSON::ParserError
      raise Error.new(:malformed_output, 'agent returned malformed JSON')
    end

    def ensure_current!(token)
      current = @state_mutex.synchronize { @generation }
      raise Error.new(:cancelled, 'agent request was cancelled') unless current == token
    end

    def fail_request(error)
      @state_mutex.synchronize do
        @last_error = { code: error.respond_to?(:code) ? error.code : :invalid_action,
                        message: error.message.to_s.byteslice(0, 256) }.freeze
        @status = :failed unless @closed
        @generation += 1
      end
      stop_process(graceful: false)
    end

    def notify(message)
      @write_mutex.synchronize do
        stdin = @state_mutex.synchronize { @stdin }
        return false unless stdin && !stdin.closed?

        stdin.write(JSON.generate(message))
        stdin.write("\n")
        stdin.flush
        true
      end
    rescue Errno::EPIPE, IOError
      false
    end

    def start_stderr_drain(stderr)
      thread = Thread.new do
        loop do
          chunk = stderr.readpartial(READ_CHUNK)
          @stderr_mutex.synchronize do
            @stderr_bytes += chunk.bytesize
            @stderr_tail << chunk
            overflow = @stderr_tail.bytesize - @stderr_tail_bytes
            @stderr_tail = @stderr_tail.byteslice(overflow, @stderr_tail_bytes) if overflow.positive?
          end
        end
      rescue EOFError, IOError
        nil
      end
      thread.report_on_exception = false
      @state_mutex.synchronize { @stderr_thread = thread }
    end

    def stop_process(graceful:)
      @lifecycle_mutex.synchronize do
        stdin, wait_thread = @state_mutex.synchronize { [@stdin, @wait_thread] }
        unless wait_thread
          cleanup_process_locked
          next
        end

        @write_mutex.synchronize { stdin&.close unless stdin&.closed? }
        wait_thread.join(graceful ? @shutdown_timeout : 0.05)
        terminate(wait_thread, 'TERM') if wait_thread.alive?
        wait_thread.join(@shutdown_timeout)
        terminate(wait_thread, 'KILL') if wait_thread.alive?
        wait_thread.join(@shutdown_timeout)
      ensure
        cleanup_process_locked
      end
    end

    def terminate(wait_thread, signal)
      Process.kill(signal, -wait_thread.pid)
    rescue Errno::ESRCH, Errno::ECHILD, Errno::EPERM
      begin
        Process.kill(signal, wait_thread.pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end

    def cleanup_process_locked
      stderr_thread = @state_mutex.synchronize do
        thread = @stderr_thread
        cleanup_io_locked
        @status = :stopped unless @closed || @status == :failed
        thread
      end
      stderr_thread&.join(0.1)
    end

    def cleanup_io_locked
      [@stdin, @stdout, @stderr].compact.each do |io|
        io.close unless io.closed?
      rescue IOError
        nil
      end
      @stdin = @stdout = @stderr = @wait_thread = @stderr_thread = nil
      @stdout_buffer = +''
    end

    def positive_float(value, label)
      parsed = Float(value)
      raise ArgumentError, "#{label} must be positive" unless parsed.positive?

      parsed
    end

    def positive_integer(value, label)
      parsed = Integer(value)
      raise ArgumentError, "#{label} must be positive" unless parsed.positive?

      parsed
    end

    def now = Float(@clock.call)
  end
end
