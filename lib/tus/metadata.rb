require "base64"

module Tus
  class Metadata
    def self.parse(string)
      return nil if string == ""

      pairs = string.split(",").map { |s| s.split(" ") }

      hash = Hash[pairs]
      hash.each do |key, value|
        hash[key] = Base64.decode64(value)
      end

      hash
    end

    def self.serialize(hash)
      return "" if hash == nil

      values = hash.map do |key, value|
        "#{key} #{Base64.encode64(value)}"
      end

      string = values.join(",")

      string
    end
  end
end
