require "base64"
require "time"

module Tus
  class Info
    def initialize(hash)
      @hash = hash
    end

    def [](key)
      @hash[key]
    end

    def []=(key, value)
      @hash[key] = value
    end

    def to_h
      @hash
    end

    def length
      Integer(@hash["Upload-Length"])
    end

    def offset
      Integer(@hash["Upload-Offset"])
    end

    def metadata
      parse_metadata(@hash["Upload-Metadata"])
    end

    def expires
      Time.parse(@hash["Upload-Expires"])
    end

    def remaining_length
      length - offset
    end

    private

    def parse_metadata(string)
      return {} if string == nil || string == ""

      pairs = string.split(",").map { |s| s.split(" ") }

      hash = Hash[pairs]
      hash.each do |key, value|
        hash[key] = Base64.decode64(value)
      end

      hash
    end
  end
end
