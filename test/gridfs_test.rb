require "test_helper"
require "tus/storage/gridfs"

require "mongo"

require "logger"
require "stringio"
require "base64"

describe Tus::Storage::Gridfs do
  before do
    @storage = gridfs
  end

  after do
    @storage.bucket.files_collection.find.delete_many
    @storage.bucket.chunks_collection.find.delete_many
  end

  def gridfs(**options)
    client = Mongo::Client.new("mongodb://127.0.0.1:27017/mydb", logger: Logger.new(nil))
    Tus::Storage::Gridfs.new(client: client, **options)
  end

  describe "#initialize" do
    it "accepts prefix" do
      assert_equal "fs_temp", gridfs(prefix: "fs_temp").bucket.prefix
    end
  end

  describe "#create_file" do
    it "creates a new empty file" do
      @storage.create_file("foo")
      assert_equal "", @storage.get_file("foo").each.to_a.join
    end

    it "stores content type" do
      @storage.create_file("foo", {"Upload-Metadata" => "content_type #{Base64.encode64("image/jpeg")}"})
      grid_info = @storage.bucket.files_collection.find.first
      assert_equal "image/jpeg", grid_info[:contentType]
    end

    it "sets the chunk size" do
      @storage = gridfs(chunk_size: 10)
      @storage.create_file("foo")
      grid_info = @storage.bucket.files_collection.find.first
      assert_equal 10, grid_info[:chunkSize]
    end
  end

  describe "#concatenate" do
    it "creates a new file which is a concatenation of given parts" do
      @storage = gridfs(chunk_size: 3)
      @storage.create_file("a")
      @storage.patch_file("a", StringIO.new("hel"))
      @storage.create_file("b")
      @storage.patch_file("b", StringIO.new("lo "))
      @storage.create_file("c")
      @storage.patch_file("c", StringIO.new("wor"))
      @storage.create_file("d")
      @storage.patch_file("d", StringIO.new("ld"))
      @storage.concatenate("abcd", ["a", "b", "c", "d"])
      assert_equal ["hel", "lo ", "wor", "ld"], @storage.get_file("abcd").each.to_a
    end

    it "returns size of the concatenated file" do
      @storage = gridfs(chunk_size: 5)
      @storage.create_file("a")
      @storage.patch_file("a", StringIO.new("hello"))
      @storage.create_file("b")
      @storage.patch_file("b", StringIO.new(" world"))
      assert_equal 11, @storage.concatenate("ab", ["a", "b"])
    end

    it "stores content type" do
      @storage.create_file("a")
      @storage.create_file("b")
      @storage.concatenate("ab", ["a", "b"], {"Upload-Metadata" => "content_type #{Base64.encode64("image/jpeg")}"})
      grid_info = @storage.bucket.files_collection.find.first
      assert_equal "image/jpeg", grid_info[:contentType]
    end

    it "deletes concatenated files" do
      @storage.create_file("a")
      @storage.create_file("b")
      @storage.concatenate("ab", ["a", "b"])
      assert_raises(Tus::NotFound) { @storage.read_info("a") }
      assert_raises(Tus::NotFound) { @storage.read_info("b") }
    end

    it "raises an error when parts are missing" do
      assert_raises(Tus::Error) { @storage.concatenate("ab", ["a", "b"]) }
    end

    it "raises an error when parts don't have full chunks" do
      @storage = gridfs(chunk_size: 3)
      @storage.create_file("a")
      @storage.patch_file("a", StringIO.new("hel"))
      @storage.create_file("b")
      @storage.patch_file("b", StringIO.new("lo"))
      @storage.create_file("c")
      @storage.patch_file("c", StringIO.new(" world"))
      assert_raises(Tus::Error) { @storage.concatenate("abc", ["a", "b", "c"]) }
    end
  end

  describe "#patch_file" do
    it "appends content" do
      @storage = gridfs(chunk_size: 3)
      @storage.create_file("foo")
      @storage.patch_file("foo", StringIO.new("hello"))
      @storage.patch_file("foo", StringIO.new(" world"))
      assert_equal ["hel", "lo ", "wor", "ld"], @storage.get_file("foo").each.to_a
    end

    it "accepts Tus::Input" do
      @storage = gridfs(chunk_size: 3)
      @storage.create_file("foo")
      @storage.patch_file("foo", Tus::Input.new(StringIO.new("hello")))
      @storage.patch_file("foo", Tus::Input.new(StringIO.new(" world")).tap(&:read).tap(&:rewind))
      assert_equal ["hel", "lo ", "wor", "ld"], @storage.get_file("foo").each.to_a
    end

    it "updates :length and :uploadDate" do
      @storage = gridfs(chunk_size: 3)
      @storage.create_file("foo")
      original_info = @storage.bucket.files_collection.find(filename: "foo").first
      @storage.patch_file("foo", StringIO.new("hello"))
      @storage.patch_file("foo", StringIO.new(" world"))
      new_info = @storage.bucket.files_collection.find(filename: "foo").first
      assert_equal 11, new_info[:length]
      assert_operator new_info[:uploadDate], :>, original_info[:uploadDate]
    end
  end

  describe "#get_file" do
    it "returns a chunked response" do
      @storage = gridfs(chunk_size: 2)
      @storage.create_file("foo")
      @storage.patch_file("foo", StringIO.new("hello world"))
      response = @storage.get_file("foo")
      assert_equal ["he", "ll", "o ", "wo", "rl", "d"], response.each.to_a
      assert_equal 11, response.length
      response.close
    end

    it "supports partial responses" do
      @storage = gridfs(chunk_size: 3)
      @storage.create_file("foo")
      @storage.patch_file("foo", StringIO.new("hello world"))

      response = @storage.get_file("foo", range: 0..11)
      assert_equal ["hel", "lo ", "wor", "ld"], response.each.to_a

      response = @storage.get_file("foo", range: 6..11)
      assert_equal ["wor", "ld"], response.each.to_a

      response = @storage.get_file("foo", range: 4..6)
      assert_equal ["o ", "w"], response.each.to_a
    end
  end

  describe "#delete_file" do
    it "deletes info and chunks" do
      @storage = gridfs(chunk_size: 5)
      @storage.create_file("foo")
      @storage.patch_file("foo", StringIO.new("hello"))
      @storage.patch_file("foo", StringIO.new(" world"))

      assert_equal 1, @storage.bucket.files_collection.find.count
      assert_equal 3, @storage.bucket.chunks_collection.find.count

      @storage.delete_file("foo")

      assert_equal 0, @storage.bucket.files_collection.find.count
      assert_equal 0, @storage.bucket.chunks_collection.find.count
    end

    it "doesn't fail when file doesn't exist" do
      @storage.delete_file("foo")
    end
  end

  describe "#read_info" do
    it "reads info" do
      @storage.create_file("foo")
      assert_equal Hash.new, @storage.read_info("foo")
      @storage.update_info("foo", {"Foo" => "Bar"})
      assert_equal Hash["Foo" => "Bar"], @storage.read_info("foo")
    end

    it "raises Tus::NotFound on missing file" do
      assert_raises(Tus::NotFound) { @storage.read_info("unknown") }
    end
  end

  describe "#update_info" do
    it "replaces existing info" do
      @storage.create_file("foo", {"Foo" => "Foo"})
      @storage.update_info("foo", {"Bar" => "Bar"})
      assert_equal Hash["Bar" => "Bar"], @storage.read_info("foo")
    end
  end

  describe "#expire_files" do
    it "deletes files past the given expiration date" do
      @storage = gridfs(chunk_size: 5)
      time = Time.utc(2017, 3, 12)

      @storage.create_file("foo")
      @storage.patch_file("foo", StringIO.new("hello"))
      @storage.patch_file("foo", StringIO.new(" world"))
      @storage.bucket.files_collection.find(filename: "foo").update_one("$set" => {uploadDate: time})

      @storage.create_file("bar")
      @storage.patch_file("bar", StringIO.new("hello"))
      @storage.patch_file("bar", StringIO.new(" world"))
      @storage.bucket.files_collection.find(filename: "bar").update_one("$set" => {uploadDate: time - 1})

      @storage.create_file("baz")
      @storage.patch_file("baz", StringIO.new("hello"))
      @storage.patch_file("baz", StringIO.new(" world"))
      @storage.bucket.files_collection.find(filename: "baz").update_one("$set" => {uploadDate: time - 2})

      @storage.expire_files(time - 1)

      assert_equal 1, @storage.bucket.files_collection.find.count
      assert_equal 3, @storage.bucket.chunks_collection.find.count

      grid_info = @storage.bucket.files_collection.find.first
      assert_equal "foo", grid_info[:filename]

      chunks = @storage.bucket.chunks_collection.find
      chunks.each { |chunk| assert_equal grid_info[:_id], chunk[:files_id] }
      assert_equal "hello world", chunks.map { |chunk| chunk[:data].data }.join
    end
  end
end
