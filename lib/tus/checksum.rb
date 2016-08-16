require "base64"
require "digest"
require "zlib"

module Tus
  class Checksum
    attr_reader :algorithm

    def initialize(algorithm)
      @algorithm = algorithm
    end

    def match?(checksum, content)
      checksum = Base64.decode64(checksum)
      generate(content) == checksum
    end

    def generate(content)
      send("generate_#{algorithm}", content)
    end

    private

    def generate_sha1(content)
      Digest::SHA1.hexdigest(content)
    end

    def generate_sha256(content)
      Digest::SHA256.hexdigest(content)
    end

    def generate_sha384(content)
      Digest::SHA384.hexdigest(content)
    end

    def generate_sha512(content)
      Digest::SHA512.hexdigest(content)
    end

    def generate_md5(content)
      Digest::MD5.hexdigest(content)
    end

    def generate_crc32(content)
      Zlib.crc32(content).to_s
    end
  end
end
