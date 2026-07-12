# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../lib/unobot_v2'
require 'json'
require 'socket'
require 'tmpdir'

class UnobotV2OperationsTest < Minitest::Test
  Result = Struct.new(:code, :message, keyword_init: true) do
    def success? = code == :ok
    def error? = !success?
  end

  class FakeManager
    attr_accessor :active, :health_result, :select_result
    attr_reader :selected, :health_checks, :selections

    def initialize(selected: 'neural', health: :ready)
      @selected = selected
      @active = false
      @health_checks = 0
      @selections = []
      @health_result = Result.new(code: :ok)
      @select_result = nil
      @health = health
    end

    def active? = active
    def selected_name = selected

    def health_check
      @health_checks += 1
      health_result
    end

    def select(name)
      @selections << name
      result = select_result || Result.new(code: :ok)
      @selected = name if result.success?
      result
    end

    def diagnostics
      {
        selected: selected, active_games: active ? ['machine:#uno:g1'] : [], shutdown: false,
        standby: {
          'neural' => [{
            name: 'neural', health: @health, running: true, deterministic: true,
            retry_in_seconds: 0, last_error: { code: :hidden, message: 'PRIVATE STDERR' },
            argv: ['/secret/python'], model_path: '/models/private.zip', stderr: 'PRIVATE STDERR'
          }]
        }, sessions: {}
      }
    end
  end

  class FakeRuntime
    attr_accessor :transition
    attr_reader :requests

    def initialize
      @requests = []
      @transition = UnobotV2::Runtime::Transition.new(code: :ok, mode: 'human')
    end

    def transition_to(mode)
      requests << mode
      transition
    end
  end

  class FakeBridge
    attr_reader :runtime
    attr_accessor :started, :joined, :worker_alive, :mode

    def initialize
      @runtime = FakeRuntime.new
      @started = true
      @joined = ['#uno']
      @worker_alive = true
      @mode = 'machine'
    end

    def diagnostics
      {
        mode: mode, attached: true, started: started, stopped: false,
        connected_once: true, joined_channels: joined,
        configured_channels: ['#uno'], accepting: true,
        worker_alive: worker_alive, timer_alive: true,
        queue_depth: 2, queue_capacity: 128, error_count: 3,
        runtime: {
          callback_error_count: 1,
          ingress: { alive: true, queue_depth: 1, queue_capacity: 128, error_count: 2 },
          channels: { '#uno' => { lifecycle: :active, game_id: 'g1', decision_id: 'd1' } }
        }
      }
    end
  end

  def setup
    @directory = Dir.mktmpdir('unobot-operations')
    @socket = File.join(@directory, 'run', 'control.sock')
    @bridge = FakeBridge.new
    @primary = FakeManager.new
    @operations = nil
  end

  def teardown
    @operations&.stop
    FileUtils.remove_entry(@directory)
  end

  def test_status_is_bounded_to_nonsecret_operational_fields
    operations = build
    response = operations.dispatch('command' => 'status')

    assert response[:ok]
    assert_equal 'machine', response.dig(:data, :messaging)
    assert_equal 'neural', response.dig(:data, :live_strategy)
    assert_equal 'ready', response.dig(:data, :model, :health).to_s
    assert_equal 'd1', response.dig(:data, :bridge, :runtime, :channels, '#uno', :decision_id)
    encoded = JSON.generate(response)
    refute_includes encoded, '/secret/python'
    refute_includes encoded, '/models/private.zip'
    refute_includes encoded, 'PRIVATE STDERR'
  end

  def test_health_and_readiness_have_distinct_failure_semantics
    operations = build
    assert operations.dispatch('command' => 'health')[:ok]
    assert operations.dispatch('command' => 'ready')[:ok]

    @bridge.joined = []
    readiness = operations.dispatch('command' => 'ready')
    refute readiness[:ok]
    assert_equal :not_ready, readiness[:code]
    assert operations.dispatch('command' => 'health')[:ok]

    @bridge.worker_alive = false
    health = operations.dispatch('command' => 'health')
    refute health[:ok]
    assert_equal :unhealthy, health[:code]
  end

  def test_health_fails_when_ready_model_process_is_not_running
    @primary = FakeManager.new
    diagnostics = @primary.method(:diagnostics)
    @primary.define_singleton_method(:diagnostics) do
      value = diagnostics.call
      value[:standby]['neural'][0][:running] = false
      value
    end

    response = build.dispatch('command' => 'health')
    refute response[:ok]
    assert_equal :unhealthy, response[:code]
  end

  def test_reload_checks_live_and_shadow_models_and_refuses_active_games
    shadow = FakeManager.new
    operations = build(shadow: shadow)
    assert operations.dispatch('command' => 'reload')[:ok]
    assert_equal 1, @primary.health_checks
    assert_equal 1, shadow.health_checks

    @primary.active = true
    failure = operations.dispatch('command' => 'reload')
    refute failure[:ok]
    assert_equal :game_active, failure[:code]
    assert_equal 1, @primary.health_checks
  end

  def test_reload_reports_sanitized_health_failure
    @primary.health_result = Result.new(code: :health_failed, message: 'PRIVATE STDERR /model/path')
    response = build.dispatch('command' => 'reload')
    refute response[:ok]
    assert_equal :health_failed, response[:code]
    refute_includes JSON.generate(response), 'PRIVATE STDERR'
  end

  def test_fallback_uses_the_bounded_runtime_transition_and_reports_refusal
    operations = build
    assert operations.dispatch('command' => 'fallback')[:ok]
    assert_equal ['human'], @bridge.runtime.requests

    @bridge.runtime.transition = UnobotV2::Runtime::Transition.new(
      code: :fallback_disabled, message: 'machine fallback is disabled', mode: 'machine'
    )
    response = operations.dispatch('command' => 'fallback')
    refute response[:ok]
    assert_equal :fallback_disabled, response[:code]
  end

  def test_select_delegates_to_manager_and_preserves_active_game_freeze
    operations = build
    assert operations.dispatch('command' => 'select', 'strategy' => 'simple')[:ok]
    assert_equal ['simple'], @primary.selections

    @primary.select_result = Result.new(code: :game_active, message: 'game active')
    response = operations.dispatch('command' => 'select', 'strategy' => 'neural')
    refute response[:ok]
    assert_equal :game_active, response[:code]
    assert_equal :invalid_strategy, operations.dispatch('command' => 'select')[:code]

    neural_shadow = FakeManager.new(selected: 'neural')
    @operations&.stop
    @operations = nil
    response = build(shadow: neural_shadow).dispatch('command' => 'select', 'strategy' => 'neural')
    assert_equal :model_capacity, response[:code]
    assert_empty @primary.selections.drop(2)
  end

  def test_restart_is_single_shot_and_refuses_active_or_unconfigured_use
    restarted = Queue.new
    operations = build(on_restart: -> { restarted << true })
    assert operations.dispatch('command' => 'restart')[:ok]
    assert restarted.pop(timeout: 1)
    assert_equal :restart_pending, operations.dispatch('command' => 'restart')[:code]

    @operations&.stop
    @operations = nil
    @primary.active = true
    assert_equal :game_active, build.dispatch('command' => 'restart')[:code]

    @operations&.stop
    @operations = nil
    @primary.active = false
    assert_equal :restart_unavailable, build(on_restart: nil).dispatch('command' => 'restart')[:code]
  end

  def test_socket_is_owner_only_and_handles_valid_malformed_oversized_and_unknown_requests
    operations = build.start
    assert_equal 0o600, File.stat(@socket).mode & 0o777
    assert_equal 0o700, File.stat(File.dirname(@socket)).mode & 0o777

    assert wire({ command: 'status' })['ok']
    assert_equal 'invalid_json', raw_wire("not-json\n")['code']
    assert_equal 'invalid_request', raw_wire(("x" * 5_000) + "\n")['code']
    assert_equal 'invalid_command', wire({ command: 'destroy' })['code']

    operations.stop
    refute File.exist?(@socket)
  end

  def test_socket_refuses_shared_or_symlink_parent_without_changing_permissions
    shared = File.join(@directory, 'shared')
    Dir.mkdir(shared, 0o755)
    before = File.stat(shared).mode & 0o777
    operations = UnobotV2::Operations.new(
      socket_path: File.join(shared, 'control.sock'), bridge: @bridge, primary: @primary
    )
    assert_raises(SecurityError) { operations.start }
    assert_equal before, File.stat(shared).mode & 0o777

    target = File.join(@directory, 'private')
    Dir.mkdir(target, 0o700)
    link = File.join(@directory, 'linked')
    File.symlink(target, link)
    operations = UnobotV2::Operations.new(
      socket_path: File.join(link, 'control.sock'), bridge: @bridge, primary: @primary
    )
    assert_raises(SecurityError) { operations.start }
  end

  private

  def build(shadow: nil, on_restart: :default)
    callback = on_restart == :default ? -> {} : on_restart
    @operations = UnobotV2::Operations.new(
      socket_path: @socket, bridge: @bridge, primary: @primary, shadow: shadow,
      timeout: 0.5, on_restart: callback
    )
  end

  def wire(value)
    raw_wire(JSON.generate(value) << "\n")
  end

  def raw_wire(value)
    socket = UNIXSocket.new(@socket)
    socket.write(value)
    JSON.parse(socket.gets)
  ensure
    socket&.close
  end
end
