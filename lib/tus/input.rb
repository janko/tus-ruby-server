# frozen-string-literal: true

require "tus/input/unicorn"
require "tus/errors"

module Tus
  # Wrapper around the Rack input, which adds the ability to limit the amount of
  # bytes that will be read from the Rack input. If there are more bytes in the
  # Rack input than the specified limit, a Tus::MaxSizeExceeded exception is
  # raised.
  class Input
    prepend Tus::Input::Unicorn

    def initialize(input, limit: nil)
      @input = input
      @limit = limit
      @pos   = 0
    end

    def read(length = nil, outbuf = nil)
      data = @input.read(*length, *outbuf)

      @pos += data.bytesize if data
      raise MaxSizeExceeded if @limit && @pos > @limit

      data
    end

    def pos
      @pos
    end

    def rewind
      @input.rewind
      @pos = 0
    end

    def close
      # Rack input shouldn't be closed, we just support the interface
    end
  end
end
