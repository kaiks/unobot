require 'bundler/setup'
require 'minitest'

running_under_mutant = defined?(Mutant)

require 'mutant/minitest/coverage' if running_under_mutant

Minitest.autorun unless running_under_mutant

class UnoTest < Minitest::Test
  cover 'Hand*' if defined?(Mutant)

  def assert_not_nil(value, message = nil)
    refute_nil(value, message)
  end

  def assert_not_equal(actual, expected, message = nil)
    refute_equal(expected, actual, message)
  end
end
