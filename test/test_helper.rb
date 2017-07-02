require "bundler/setup"

ENV["MT_NO_EXPECTATIONS"] = "1"

require "minitest/autorun"
require "minitest/pride"

require "tus-server"

require "stringio"
require "forwardable"

class RackInput
  def initialize(content)
    @io = StringIO.new(content)
  end

  extend Forwardable
  delegate [:read, :rewind, :gets, :each, :close] => :@io
end
