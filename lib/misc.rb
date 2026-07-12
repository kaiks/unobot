# TODO: separate logger from the rest
# require 'extend_logger.rb'
require 'logger'
require 'fileutils'

log_directory = File.expand_path('../logs', __dir__)
FileUtils.mkdir_p(log_directory)

log_max_bytes = Integer(ENV.fetch('UNO_LOG_MAX_BYTES', (10 * 1024 * 1024).to_s))
log_backups = Integer(ENV.fetch('UNO_LOG_BACKUPS', '3'))
raise ArgumentError, 'UNO_LOG_MAX_BYTES must be positive' unless log_max_bytes.positive?
raise ArgumentError, 'UNO_LOG_BACKUPS must be nonnegative' if log_backups.negative?

$logger = Logger.new(File.join(log_directory, 'unobot.log'), log_backups, log_max_bytes)
$logger_queue = Queue.new
$logger.datetime_format = '%H:%M:%S'

$logger_thread = Thread.new do
  loop do
    while $DEBUG == true && (engine = $bot&.config&.engine) && engine.busy == false
      $logger.add(Logger::INFO, $logger_queue.pop)
    end
    sleep(0.5)
  end
end

def log(text)
  $logger_queue << "\n#{text}"
end

def bot_debug(text, detail = 1)
  log(text)

  if $DEBUG_LEVEL >= detail
    puts "#{detail >= 3 ? '' : caller[0]} #{text}"
  end
end

def set_debug(level)
  $DEBUG = true
  $DEBUG_LEVEL = level.to_i
end

def unset_debug
  $DEBUG = false
  $DEBUG_LEVEL = 0
end

class Array
  # array exists and has nth element (1=array start) not null
  def exists_and_has(n)
    size >= n && !at(n - 1).nil?
  end

  def equal_partial?(array)
    each_with_index.all? { |a, i| a == :_ || array[i] == :_ || a == array[i] }
  end
end

class NilClass
  def exists_and_has(_n)
    false
  end
end

module Misc
  NICK_REGEX = /([a-z_\-\[\]\\^{}|`][a-z0-9_\-\[\]\\^{}|`]{1,15})'s/i
  NICK_REGEX_PURE = /([a-z_\-\[\]\\^{}|`][a-z0-9_\-\[\]\\^{}|`]{1,15})/i
end
