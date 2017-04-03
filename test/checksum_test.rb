require "test_helper"
require "stringio"

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
end
