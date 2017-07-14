require "tus/errors"

require "tempfile"
require "stringio"

module Tus
  class Input
    def initialize(input, content_length: nil, limit: nil)
      @input          = input
      @content_length = content_length
      @limit          = limit
      @bytes_read     = 0
    end

    def read(length = nil, outbuf = nil)
      result = @input.read(length, outbuf)

      @bytes_read += result.bytesize if result
      raise MaxSizeExceeded if @limit && @bytes_read > @limit

      result
    rescue defined?(Unicorn) && Unicorn::ClientShutdown
      raise if @content_length # we are only recovering on chunked uploads
      outbuf = outbuf.to_s.clear
      outbuf unless length
    end

    def rewind
      @input.rewind
      @bytes_read = 0
    end

    def size
      if @input.is_a?(Tempfile) || @input.is_a?(StringIO)
        @input.size
      else
        @content_length
      end
    end

    def close
      # Rack input shouldn't be closed, we just support the interface
    end

    def bytes_read
      @bytes_read
    end
  end
end
