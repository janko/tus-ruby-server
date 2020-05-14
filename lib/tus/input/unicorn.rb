module Tus
  class Input
    # Extension for Unicorn to gracefully handle interrupted uploads.
    module Unicorn
      # Rescues Unicorn::ClientShutdown exception when reading, and instead of
      # failing just returns blank data to signal end of input.
      def read(length = nil, outbuf = nil)
        super
      rescue => exception
        raise unless exception.class.name == "Unicorn::ClientShutdown"

        data   = outbuf.clear if outbuf
        data ||= "".dup

        data unless length
      end
    end
  end
end
