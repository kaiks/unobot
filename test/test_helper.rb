require 'bundler/setup'
require 'minitest/autorun'

class UnoTest < Minitest::Test
  def assert_not_nil(value, message = nil)
    refute_nil(value, message)
  end

  def assert_not_equal(actual, expected, message = nil)
    refute_equal(expected, actual, message)
  end
end
