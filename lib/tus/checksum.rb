module Tus
  class Checksum
    CHUNK_SIZE = 16*1024

    attr_reader :algorithm

    def self.generate(algorithm, input)
      new(algorithm).generate(input)
    end

    def initialize(algorithm)
      @algorithm = algorithm
    end

    def match?(checksum, io)
      generate(io) == checksum
    end

    def generate(io)
      hash = send("generate_#{algorithm}", io)
      io.rewind
      hash
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
      require "zlib"
      require "base64"
      crc = Zlib.crc32("")
      while (data = io.read(CHUNK_SIZE, buffer ||= ""))
        crc = Zlib.crc32(data, crc)
      end
      Base64.strict_encode64(crc.to_s)
    end

    def digest(name, io)
      require "digest"
      digest = Digest.const_get(name).new
      while (data = io.read(CHUNK_SIZE, buffer ||= ""))
        digest.update(data)
      end
      digest.base64digest
    end
  end
end
