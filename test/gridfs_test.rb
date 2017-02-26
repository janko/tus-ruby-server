require "test_helper"
require "tus/storage/gridfs"
require "logger"
require "stringio"

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

  describe "#create_file" do
    it "creates an empty file" do
      @storage.create_file(uid = "foo", {"Foo" => "Bar"})
      assert_equal "", @storage.read_file("foo")
      assert_equal Hash["Foo" => "Bar"], @storage.read_info("foo")
    end
  end

  describe "file_exists?" do
    it "returns true if file exists" do
      @storage.create_file("foo")
      assert_equal true, @storage.file_exists?("foo")
    end

    it "returns false if file doesn't exist" do
      assert_equal false, @storage.file_exists?("unknown")
    end
  end

  describe "#read_file" do
    it "returns contents of the file" do
      @storage.create_file("foo")
      @storage.patch_file("foo", StringIO.new("content"))
      assert_equal "content", @storage.read_file("foo")
    end
  end

  describe "#patch_file" do
    it "appends to the content" do
      @storage.create_file("foo")
      @storage.patch_file("foo", StringIO.new("hello"))
      @storage.patch_file("foo", StringIO.new(" world"))
      assert_equal "hello world", @storage.read_file("foo")
    end

    it "works correctly with multiple chunks" do
      @storage = gridfs(chunk_size: 1)
      @storage.create_file("foo")
      @storage.patch_file("foo", StringIO.new("hello"))
      @storage.patch_file("foo", StringIO.new(" world"))
      assert_equal 11, @storage.bucket.chunks_collection.find.count
      assert_equal "hello world", @storage.read_file("foo")
    end
  end

  describe "#download_file" do
    it "returns path of downloaded file" do
      @storage.create_file("foo")
      @storage.patch_file("foo", StringIO.new("hello"))
      @storage.patch_file("foo", StringIO.new(" world"))
      assert_equal "hello world", File.read(@storage.download_file("foo"))
    end
  end

  describe "#delete_file" do
    it "deletes the file" do
      @storage.create_file("foo")
      @storage.delete_file("foo")
      assert_equal false, @storage.file_exists?("foo")
    end

    it "doesn't fail when file doesn't exist" do
      @storage.delete_file("foo")
    end
  end

  describe "#read_info" do
    it "reads info" do
      @storage.create_file("foo")
      assert_equal Hash.new, @storage.read_info("foo")

      @storage.create_file("bar", {"Foo" => "Bar"})
      assert_equal Hash["Foo" => "Bar"], @storage.read_info("bar")
    end
  end

  describe "#update_info" do
    it "replaces existing info" do
      @storage.create_file("foo", {"Foo" => "Foo"})
      @storage.update_info("foo", {"Bar" => "Bar"})
      assert_equal Hash["Bar" => "Bar"], @storage.read_info("foo")
    end
  end

  describe "#list_files" do
    it "returns list of uids" do
      @storage.create_file("foo")
      @storage.create_file("bar")
      assert_equal ["foo", "bar"], @storage.list_files
    end
  end
end
