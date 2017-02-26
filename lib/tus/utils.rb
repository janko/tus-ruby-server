module Tus
  module Utils
    module_function

    def read_chunks(io, chunk_size: 16384)
      loop do
        chunk = io.read(chunk_size, buf ||= "")

        if chunk
          yield chunk
        else
          io.rewind
          break
        end
      end
    end
  end
end
