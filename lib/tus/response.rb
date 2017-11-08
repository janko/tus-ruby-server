module Tus
  # Object that responds to #each, #length, and #close, suitable for returning
  # as a Rack response body.
  class Response
    def initialize(chunks:, length:, close: ->{})
      @chunks = chunks
      @close  = close
      @length = length
    end

    def length
      @length
    end

    def each(&block)
      @chunks.each(&block)
    end

    def close
      @close.call
    end
  end
end
