module Tus
  class Input
    def initialize(input)
      @input = input
      @eof   = false
    end

    def read(*args)
      result = @input.read(*args)
      @eof = (result == "" || result == nil)
      result
    end

    def eof?
      @eof || (@input.eof? if @input.respond_to?(:eof?))
    end

    def rewind
      @input.rewind
    end

    def size
      @input.size
    end

    def close
      # Rack input shouldn't be closed, we just support the interface
    end
  end
end
