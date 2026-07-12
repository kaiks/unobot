# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../lib/bounded_log'
require 'tmpdir'

class BoundedLogTest < Minitest::Test
  def test_files_and_backup_count_remain_strictly_bounded
    Dir.mktmpdir('unobot-bounded-log') do |directory|
      path = File.join(directory, 'bot.log')
      log = BoundedLog.new(path, max_bytes: 64, backups: 2)
      100.times { |index| log.puts("line-#{index}-#{'x' * 20}") }
      log.close

      files = Dir["#{path}*"]
      assert_operator files.length, :<=, 3
      assert files.all? { |file| File.size(file) <= 64 }
      assert File.size(path).positive?
    end
  end

  def test_concurrent_oversized_writes_are_split_without_exceeding_limit
    Dir.mktmpdir('unobot-bounded-log') do |directory|
      path = File.join(directory, 'bot.log')
      log = BoundedLog.new(path, max_bytes: 32, backups: 3)
      threads = 4.times.map { Thread.new { 20.times { log.write('z' * 100) } } }
      threads.each { |thread| assert thread.join(2) }
      log.flush
      log.close

      assert Dir["#{path}*"].all? { |file| File.size(file) <= 32 }
    end
  end

  def test_invalid_bounds_and_closed_writes_fail
    assert_raises(ArgumentError) { BoundedLog.new('/tmp/nope', max_bytes: 0, backups: 1) }
    assert_raises(ArgumentError) { BoundedLog.new('/tmp/nope', max_bytes: 1, backups: -1) }
    Dir.mktmpdir do |directory|
      log = BoundedLog.new(File.join(directory, 'bot.log'), max_bytes: 8, backups: 0)
      log.close
      assert_raises(IOError) { log.write('closed') }
    end
  end
end
