# frozen_string_literal: true

require 'bundler/setup'
require 'cinch'
require 'fileutils'
require 'sequel'
require 'tmpdir'

host_root, port, channel = ARGV
abort 'usage: host_runner.rb HOST_ROOT PORT CHANNEL' unless channel
srand(Integer(ENV.fetch('UNO_STAGE7_SEED', '7331')))

database_directory = Dir.mktmpdir('uno-stage7-host-db')
at_exit { FileUtils.remove_entry(database_directory) if File.directory?(database_directory) }
FileUtils.cp(File.join(host_root, 'db/uno.db'), File.join(database_directory, 'uno.db'))

define_method(:sqlite_load) do |filename|
  Sequel.sqlite(File.join(database_directory, filename))
end

Dir.chdir(host_root)
require './plugins/uno_plugin'

bot = Cinch::Bot.new do
  configure do |config|
    config.nick = 'Host'
    config.server = '127.0.0.1'
    config.port = Integer(port)
    config.channels = [channel]
    config.messages_per_second = 100_000
    config.server_queue_size = 100_000
    config.verbose = false
    config.shared[:database] = Sequel.sqlite
    config.plugins.plugins = [UnoPlugin]
  end
end

%w[INT TERM].each { |signal| Signal.trap(signal) { Thread.new { bot.quit('stage7 shutdown') } } }
bot.start
