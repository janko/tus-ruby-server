require "tus/utils"

require "base64"
require "digest"
require "zlib"

module Tus
  class Checksum
    attr_reader :algorithm

    def initialize(algorithm)
      @algorithm = algorithm
    end

    def match?(checksum, io)
      checksum = Base64.decode64(checksum)
      generate(io) == checksum
    end

    def generate(io)
      send("generate_#{algorithm}", io)
    end

    private

    def generate_sha1(io)
      digest(:SHA1, io)
    end

    def generate_sha256(io)
      digest(:SHA256, io)
    end

    def generate_sha384(io)
      digest(:SHA384, io)
    end

    def generate_sha512(io)
      digest(:SHA512, io)
    end

    def generate_md5(io)
      digest(:MD5, io)
    end

    def generate_crc32(io)
      crc = nil
      Utils.read_chunks(io) { |chunk| crc = Zlib.crc32(chunk, crc) }
      crc.to_s
    end

    def digest(name, io)
      digest = Digest.const_get(name).new
      Utils.read_chunks(io) { |chunk| digest.update(chunk) }
      digest.hexdigest
    end
  end
end
