# frozen_string_literal: true

require_relative 'test_helper'
require 'digest'
require 'open3'
require 'tmpdir'

class DeployEntrypointTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  ENTRYPOINT = File.join(ROOT, 'deploy/entrypoint')

  def test_neural_detection_is_case_insensitive_for_live_and_shadow_selection
    Dir.mktmpdir('unobot-entrypoint') do |directory|
      checkpoint = File.join(directory, 'checkpoint.zip')
      File.write(checkpoint, 'fixture-model')
      digest = Digest::SHA256.file(checkpoint).hexdigest
      base = {
        'UNO_NEURAL_CHECKPOINT' => checkpoint,
        'UNO_NEURAL_CHECKPOINT_SHA256' => digest
      }

      %w[Neural NEURAL nEuRaL].each do |strategy|
        result = run_entrypoint(base.merge('UNO_STRATEGY' => strategy))
        assert result.success?, strategy
      end
      result = run_entrypoint(base.merge('UNO_STRATEGY' => 'simple', 'UNO_SHADOW_STRATEGY' => 'NeUrAl'))
      assert result.success?
    end
  end

  def test_non_neural_selection_does_not_require_checkpoint
    result = run_entrypoint(
      'UNO_STRATEGY' => 'Crushing', 'UNO_SHADOW_STRATEGY' => 'Simple',
      'UNO_NEURAL_CHECKPOINT' => '/definitely/missing'
    )
    assert result.success?
  end

  def test_case_insensitive_neural_selection_fails_closed_without_checkpoint
    status = run_entrypoint('UNO_STRATEGY' => 'NEURAL', 'UNO_NEURAL_CHECKPOINT' => '/definitely/missing')
    refute status.success?
    assert_equal 78, status.exitstatus
  end

  def test_supervised_child_retains_piped_standard_input
    stdout, stderr, status = Open3.capture3(
      clean_environment,
      ENTRYPOINT, RbConfig.ruby, '-e', 'STDOUT.write(STDIN.read)',
      stdin_data: "one\ntwo\n", chdir: ROOT
    )

    assert status.success?, stderr
    assert_equal "one\ntwo\n", stdout
  end

  private

  def run_entrypoint(environment)
    _stdout, _stderr, status = Open3.capture3(
      clean_environment.merge(environment),
      ENTRYPOINT, 'true', chdir: ROOT
    )
    status
  end

  def clean_environment
    { 'UNO_STRATEGY' => nil, 'UNO_SHADOW_STRATEGY' => nil,
      'UNO_NEURAL_CHECKPOINT' => nil, 'UNO_NEURAL_CHECKPOINT_SHA256' => nil }
  end
end
