require "bundler/setup"

ENV["MT_NO_EXPECTATIONS"] = "1"

require "minitest/autorun"
require "minitest/pride"

require "tus-server"

class Rack::Lint::InputWrapper
  # All major web servers have inputs that respond to this method, and we
  # need it for implementation of `Tus::Input#eof?`.
  def size
    @input.size
  end
end
