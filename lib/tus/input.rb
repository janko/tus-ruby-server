require "tus/errors"

module Tus
  class Input
    def initialize(input, limit: nil)
      @input = input
      @limit = limit
      @pos   = 0
    end

    def read(length = nil, outbuf = nil)
      data = @input.read(length, outbuf)

      @pos += data.bytesize if data
      raise MaxSizeExceeded if @limit && @pos > @limit

      data
    rescue => exception
      raise unless exception.class.name == "Unicorn::ClientShutdown"
      outbuf = outbuf.to_s.clear
      outbuf unless length
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
