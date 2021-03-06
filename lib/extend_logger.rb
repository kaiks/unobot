# source: http://stackoverflow.com/questions/6499654/is-there-an-asynchronous-logging-library-for-ruby

require 'thread'
require 'singleton'
require 'delegate'
require 'monitor'
require 'logger'

class Async
  include Singleton

  def initialize
    @queue = Queue.new
    Thread.new { loop { @queue.pop.call; sleep(0.1) } }
  end

  def run(&blk)
    @queue.push blk
  end
end

class Work < Delegator
  include MonitorMixin

  def initialize(&work)
    super work; @work = work
    @done = false
    @lock = new_cond
  end

  def calc
    synchronize do
      @result = @work.call
      @done = true
      @lock.signal
    end
  end

  def __getobj__
    synchronize { @lock.wait_while { !@done } }
    @result
  end
end

Module.class.class_exec do
  def async(*method_names)
    method_names.each do |method_name|
      original_method = instance_method(method_name)
      define_method(method_name) do |*args, &blk|
        work = Work.new { original_method.bind(self).call(*args, &blk) }
        Async.instance.run { work.calc }
        return work
      end
    end
  end
end

class Logger
  async :bot_debug
end
