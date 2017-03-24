module Tus
  class Input
    def initialize(input)
      @input = input
      @bytes_read = 0
    end

    def read(*args)
      result = @input.read(*args)
      @bytes_read += result.bytesize if result.is_a?(String)
      result
    end

    def eof?
      @bytes_read == size
    end

    def rewind
      @input.rewind
      @bytes_read = 0
    end

    def size
      @input.size
    end

    def close
      # Rack input shouldn't be closed, we just support the interface
    end
  end
end
