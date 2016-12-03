require 'extend_logger.rb'

$logger = Logger.new('logs/unobot.log', 'daily')

def log(text, severity = Logger::INFO)
  $logger.add(severity, text)
end

def debug text
  puts text if $DEBUG
  log(text)
end

def debug(text, detail = 1)
  log(text)
  if $DEBUG_LEVEL >= detail
    puts "#{detail >= 3 ? '' : caller[0]} #{text}"
  end
end

def set_debug(level)
  $DEBUG = true
  $DEBUG_LEVEL = level
end

def unset_debug
  $DEBUG = false
  $DEBUG_LEVEL = 0
end

class Array
  #array exists and has nth element (1=array start) not null
  def exists_and_has n
    size >= n && !at(n-1).nil?
  end

  def equal_partial? array
    each_with_index.all? { |a,i| :_ == a || :_ == array[i] || a == array[i] }
  end
end

class NilClass
  def exists_and_has n
    false
  end
end

module Misc
  NICK_REGEX = /([a-z_\-\[\]\\^{}|`][a-z0-9_\-\[\]\\^{}|`]{1,15})'s/i
  NICK_REGEX_PURE = /([a-z_\-\[\]\\^{}|`][a-z0-9_\-\[\]\\^{}|`]{1,15})/i
end