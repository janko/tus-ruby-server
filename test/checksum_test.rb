require "test_helper"

describe Tus::Checksum do
  it "calculates sha1" do
    refute_empty Tus::Checksum.new("sha1").generate("foo")
  end

  it "calculates sha256" do
    refute_empty Tus::Checksum.new("sha256").generate("foo")
  end

  it "calculates sha384" do
    refute_empty Tus::Checksum.new("sha384").generate("foo")
  end

  it "calculates sha512" do
    refute_empty Tus::Checksum.new("sha512").generate("foo")
  end

  it "calculates md5" do
    refute_empty Tus::Checksum.new("md5").generate("foo")
  end

  it "calculates crc32" do
    refute_empty Tus::Checksum.new("crc32").generate("foo")
  end
end
