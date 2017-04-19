require "test_helper"
require "stringio"
require "digest"
require "zlib"
require "base64"

describe Tus::Checksum do
  %w[sha1 sha256 sha384 sha512 md5 crc32].each do |algorithm|
    it "calculates #{algorithm}" do
      checksum = Tus::Checksum.new(algorithm)
      io       = StringIO.new("foo")

      refute_empty checksum.generate(io)

      assert 0, io.pos
    end

    it "calculates #{algorithm} of empty files" do
      checksum = Tus::Checksum.new(algorithm)
      io       = StringIO.new("")

      refute_empty checksum.generate(io)

      assert 0, io.pos
    end
  end

  it "calculates correct signature from the IO object" do
    content = "a" * 40*1024
    io = StringIO.new(content)

    assert_equal Digest::MD5.base64digest(content),    Tus::Checksum.new(:md5).generate(io)
    assert_equal Digest::SHA1.base64digest(content),   Tus::Checksum.new(:sha1).generate(io)
    assert_equal Digest::SHA256.base64digest(content), Tus::Checksum.new(:sha256).generate(io)
    assert_equal Digest::SHA384.base64digest(content), Tus::Checksum.new(:sha384).generate(io)
    assert_equal Digest::SHA512.base64digest(content), Tus::Checksum.new(:sha512).generate(io)

    assert_equal Base64.encode64(Zlib.crc32(content).to_s).chomp, Tus::Checksum.new(:crc32).generate(io)
  end
end
