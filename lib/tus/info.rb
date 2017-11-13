# frozen-string-literal: true

require "base64"
require "time"

module Tus
  # Holds request headers and other information about tus uploads.
  class Info
    HEADERS = %w[
      Upload-Length
      Upload-Offset
      Upload-Defer-Length
      Upload-Metadata
      Upload-Concat
      Upload-Expires
    ]

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

    def headers
      @hash.select { |key, value| HEADERS.include?(key) && !value.nil? }
    end

    def length
      Integer(@hash["Upload-Length"]) if @hash["Upload-Length"]
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

    def concatenation?
      @hash["Upload-Concat"].to_s.start_with?("final")
    end

    def defer_length?
      @hash["Upload-Defer-Length"] == "1"
    end

    def partial_uploads
      urls = @hash["Upload-Concat"].split(";").last.split(" ")
      urls.map { |url| url.split("/").last }
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
        hash[key] = value && Base64.decode64(value)
      end

      hash
    end
  end
end
