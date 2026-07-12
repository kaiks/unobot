# frozen_string_literal: true

require 'fileutils'
require 'thread'

# Minimal IO-compatible file used by Cinch. Every write is split at the byte
# boundary, so the active file and each retained backup are strictly bounded.
class BoundedLog
  def initialize(path, max_bytes:, backups:)
    @path = File.expand_path(path)
    @max_bytes = Integer(max_bytes)
    @backups = Integer(backups)
    raise ArgumentError, 'log max bytes must be positive' unless @max_bytes.positive?
    raise ArgumentError, 'log backups must be nonnegative' if @backups.negative?

    FileUtils.mkdir_p(File.dirname(@path))
    @mutex = Mutex.new
    @closed = false
    open_file
  end

  def write(value)
    data = String(value).b
    original_size = data.bytesize
    @mutex.synchronize do
      raise IOError, 'closed log' if @closed

      until data.empty?
        rotate if @io.size >= @max_bytes
        available = @max_bytes - @io.size
        chunk = data.byteslice(0, available)
        @io.write(chunk)
        data = data.byteslice(chunk.bytesize, data.bytesize - chunk.bytesize) || ''.b
      end
    end
    original_size
  end

  def puts(*values)
    values = [nil] if values.empty?
    values.each do |value|
      line = value.nil? ? '' : value.to_s
      write(line.end_with?("\n") ? line : "#{line}\n")
    end
    nil
  end

  def flush
    @mutex.synchronize { @io.flush unless @closed }
    self
  end

  def close
    @mutex.synchronize do
      return if @closed

      @closed = true
      @io.close
    end
  end

  def tty? = false

  private

  def open_file
    @io = File.open(@path, 'ab')
    @io.sync = true
  end

  def rotate
    @io.close
    File.delete("#{@path}.#{@backups}") if @backups.positive? && File.exist?("#{@path}.#{@backups}")
    (@backups - 1).downto(1) do |index|
      source = "#{@path}.#{index}"
      File.rename(source, "#{@path}.#{index + 1}") if File.exist?(source)
    end
    if @backups.positive?
      File.rename(@path, "#{@path}.1") if File.exist?(@path)
    else
      File.delete(@path) if File.exist?(@path)
    end
    open_file
  end
end
