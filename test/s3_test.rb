require "test_helper"
require "tus/storage/s3"

require "aws-sdk"
require "dotenv"

require "base64"
require "stringio"

Dotenv.load!

describe Tus::Storage::S3 do
  before do
    @storage = s3
    capture_io { Tus::Storage::S3.const_set(:MIN_PART_SIZE, 0) }
  end

  def s3(**options)
    options[:access_key_id]     ||= ENV.fetch("S3_ACCESS_KEY_ID")
    options[:secret_access_key] ||= ENV.fetch("S3_SECRET_ACCESS_KEY")
    options[:region]            ||= ENV.fetch("S3_REGION")
    options[:bucket]            ||= ENV.fetch("S3_BUCKET")

    Tus::Storage::S3.new(options)
  end

  describe "#initialize" do
    it "accepts credentials" do
      storage = s3(
        access_key_id:     "abc",
        secret_access_key: "xyz",
        region:            "eu-west-1",
        bucket:            "tus",
      )

      assert_equal "abc",       storage.client.config.access_key_id
      assert_equal "xyz",       storage.client.config.secret_access_key
      assert_equal "eu-west-1", storage.client.config.region
      assert_equal "tus",       storage.bucket.name
    end
  end

  it "can upload a file" do
    info = {
      "Upload-Metadata" => ["content_type #{Base64.encode64("text/plain")}",
                            "filename #{Base64.encode64("foo.txt")}"].join(","),
      "Upload-Length" => "4",
      "Upload-Offset" => "0",
    }

    @storage.create_file("foo", info)

    multipart_upload = @storage.bucket.object("foo").multipart_upload(info["multipart_id"])
    assert_equal [], multipart_upload.parts.to_a

    @storage.patch_file("foo", Tus::Input.new(StringIO.new("file")), info)

    response = @storage.bucket.object("foo").get
    assert_equal "text/plain", response.content_type
    assert_equal "inline; filename=\"foo.txt\"", response.content_disposition

    response = @storage.get_file("foo", info)
    assert_equal "file", response.each.map(&:dup).join
    assert_equal 4,      response.length

    assert_equal "fi", @storage.get_file("foo", info, range: 0..1).each.map(&:dup).join

    @storage.delete_file("foo", info)
  end

  it "can concatenate partial uploads" do
    part_info = {
      "Upload-Length" => "11",
      "Upload-Offset" => "0",
    }
    @storage.create_file("part", part_info)
    @storage.update_info("part", {})
    @storage.patch_file("part", StringIO.new("hello world"), part_info)

    info = {
      "Upload-Metadata" => ["content_type #{Base64.encode64("text/plain")}",
                            "filename #{Base64.encode64("foo.txt")}"].join(","),
      "Upload-Length" => "11",
      "Upload-Offset" => "0",
    }

    result = @storage.concatenate("foo", ["part"], info)

    assert_equal 11, result

    assert_equal "hello world", @storage.get_file("foo").each.map(&:dup).join
    response = @storage.bucket.object("foo").get
    assert_equal "text/plain", response.content_type
    assert_equal "inline; filename=\"foo.txt\"", response.content_disposition

    assert_raises(Tus::NotFound) { @storage.get_file("part") }
    assert_raises(Tus::NotFound) { @storage.read_info("part") }
  end

  it "can manage info" do
    @storage.update_info("foo", {"Foo" => "Bar"})
    assert_equal Hash["Foo" => "Bar"], @storage.read_info("foo")

    @storage.delete_file("foo")
  end

  it "can delete objects and multipart uploads" do
    info = {"Upload-Length" => "4", "Upload-Offset" => "0"}

    @storage.create_file("foo", info)
    @storage.update_info("foo", {})
    @storage.delete_file("foo", info)
    assert_raises(Tus::NotFound) { @storage.patch_file("foo", StringIO.new("file"), info) }
    assert_raises(Tus::NotFound) { @storage.read_info("foo") }

    @storage.create_file("foo", info)
    @storage.update_info("foo", {})
    @storage.patch_file("foo", StringIO.new("file"), info)
    @storage.delete_file("foo", info)
    assert_raises(Tus::NotFound) { @storage.get_file("foo") }
    assert_raises(Tus::NotFound) { @storage.read_info("foo") }
  end

  it "can expire objects and multipart uploads" do
    @storage.create_file("foo", foo_info = {})
    @storage.update_info("foo", {})

    bar_info = {"Upload-Length" => "4", "Upload-Offset" => "0"}
    @storage.create_file("bar", bar_info)
    @storage.patch_file("bar", StringIO.new("file"), bar_info)

    @storage.expire_files(Time.now.utc)

    assert_raises(Tus::NotFound) { @storage.get_file("foo") }
    assert_raises(Tus::NotFound) { @storage.read_info("foo") }
    assert_raises(Tus::NotFound) { @storage.get_file("bar") }
  end

  it "returns Tus::NotFound when appropriate" do
    assert_raises(Tus::NotFound) { @storage.patch_file("foo", StringIO.new("file"), {"multipart_id" => "abc", "multipart_parts" => []}) }
    assert_raises(Tus::NotFound) { @storage.read_info("foo") }
    assert_raises(Tus::NotFound) { @storage.get_file("foo") }
  end
end
