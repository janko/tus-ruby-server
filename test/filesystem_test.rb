require "test_helper"
require "fileutils"
require "stringio"

describe Tus::Storage::Filesystem do
  before do
    @storage = Tus::Storage::Filesystem.new("data")
  end

  after do
    FileUtils.rm_rf("data")
  end

  def permissions(path)
    File.lstat(path).mode & 0777
  end

  describe "#initialize" do
    it "creates the directory if it doesn't exist" do
      FileUtils.rm_rf("data")
      Tus::Storage::Filesystem.new("data")
      assert File.directory?("data")
    end

    it "applies :directory_permissions to the created directory" do
      FileUtils.rm_rf("data")
      Tus::Storage::Filesystem.new("data")
      assert_equal 0755, permissions("data")

      FileUtils.rm_rf("data")
      Tus::Storage::Filesystem.new("data", directory_permissions: 0777)
      assert_equal 0777, permissions("data")
    end
  end

  describe "#create_file" do
    it "creates new empty file" do
      @storage.create_file("foo")
      assert_equal "", @storage.get_file("foo").each.to_a.join
    end

    it "applies :permissions to the created file" do
      @storage.create_file("foo")
      assert_equal 0644, permissions("data/foo")
      assert_equal 0644, permissions("data/foo.info")

      @storage = Tus::Storage::Filesystem.new("data", permissions: 0600)
      @storage.create_file("foo")
      assert_equal 0600, permissions("data/foo")
      assert_equal 0600, permissions("data/foo.info")
    end
  end

  describe "#concatenate" do
    it "creates a new file which is a concatenation of given parts" do
      @storage.create_file("a")
      @storage.patch_file("a", StringIO.new("hello"))
      @storage.create_file("b")
      @storage.patch_file("b", StringIO.new(" world"))
      @storage.concatenate("ab", ["a", "b"])
      assert_equal "hello world", @storage.get_file("ab").each.to_a.join
    end

    it "returns size of the concatenated file" do
      @storage.create_file("a")
      @storage.patch_file("a", StringIO.new("hello"))
      @storage.create_file("b")
      @storage.patch_file("b", StringIO.new(" world"))
      assert_equal 11, @storage.concatenate("ab", ["a", "b"])
    end

    it "deletes concatenated files" do
      @storage.create_file("a")
      @storage.create_file("b")
      @storage.concatenate("ab", ["a", "b"])
      assert_raises(Tus::NotFound) { @storage.read_info("a") }
      assert_raises(Tus::NotFound) { @storage.read_info("b") }
    end

    it "applies correct permissions to the concatenated file" do
      @storage.create_file("a")
      @storage.patch_file("a", StringIO.new("hello"))
      @storage.create_file("b")
      @storage.patch_file("b", StringIO.new(" world"))
      @storage.concatenate("ab", ["a", "b"])
      assert_equal 0644, permissions("data/ab")
      assert_equal 0644, permissions("data/ab.info")

      @storage = Tus::Storage::Filesystem.new("data", permissions: 0600)
      @storage.create_file("a")
      @storage.patch_file("a", StringIO.new("hello"))
      @storage.create_file("b")
      @storage.patch_file("b", StringIO.new(" world"))
      @storage.concatenate("ab", ["a", "b"])
      assert_equal 0600, permissions("data/ab")
      assert_equal 0600, permissions("data/ab.info")
    end

    it "raises an error when parts are missing" do
      assert_raises(Tus::Error) { @storage.concatenate("ab", ["a", "b"]) }
    end
  end

  describe "#patch_file" do
    it "appends to the file" do
      @storage.create_file("foo")
      @storage.patch_file("foo", StringIO.new("hello"))
      @storage.patch_file("foo", StringIO.new(" world"))
      response = @storage.get_file("foo")
      assert_equal "hello world", response.each.to_a.join
    end

    it "returns number of bytes copied" do
      @storage.create_file("foo")
      assert_equal 5, @storage.patch_file("foo", StringIO.new("hello"))
      assert_equal 6, @storage.patch_file("foo", StringIO.new(" world"))
    end

    it "works with Tus::Input" do
      @storage.create_file("foo")
      @storage.patch_file("foo", Tus::Input.new(StringIO.new("hello")))
      @storage.patch_file("foo", Tus::Input.new(StringIO.new(" world")).tap(&:read).tap(&:rewind))
      response = @storage.get_file("foo")
      assert_equal "hello world", response.each.to_a.join
    end
  end

  describe "#read_info" do
    it "retreives the info" do
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
    it "updates the info" do
      @storage.create_file("foo")
      @storage.update_info("foo", {"bar" => "baz"})
      @storage.update_info("foo", {"quux" => "quilt"})
      assert_equal Hash["quux" => "quilt"], @storage.read_info("foo")
    end
  end

  describe "#get_file" do
    it "returns chunked response" do
      @storage.create_file("foo")
      @storage.patch_file("foo", StringIO.new("a" * 16*1024 + "b" * 16*1024))
      response = @storage.get_file("foo")
      assert_equal "a" * 16*1024 + "b" * 16*1024, response.each.to_a.join
      response.close
    end

    it "supports partial responses" do
      @storage.create_file("foo")
      @storage.patch_file("foo", StringIO.new("a" * 16*1024 + "b" * 16*1024))

      response = @storage.get_file("foo", range: (16*1024 - 3)..(16*1024 + 2))
      assert_equal "a" * 3 + "b" * 3, response.each.to_a.join

      response = @storage.get_file("foo", range: (16*1024 - 3)..(32*1024 - 1))
      assert_equal "a" * 3 + "b" * 16*1024, response.each.to_a.join

      response = @storage.get_file("foo", range: (0)..(16*1024 + 2))
      assert_equal "a" * 16*1024 + "b" * 3, response.each.to_a.join
    end

    it "handles multibyte characters" do
      @storage.create_file("foo")
      @storage.patch_file("foo", StringIO.new("😃"))
    end
  end

  describe "#delete_file" do
    it "deletes files from the filesystem" do
      @storage.create_file("foo")
      @storage.update_info("foo", {"bar" => "baz"})

      assert_equal 2, @storage.directory.children.count

      @storage.delete_file("foo")

      assert_equal 0, @storage.directory.children.count
    end

    it "doesn't raise an error if file is missing" do
      @storage.delete_file("unknown")
    end
  end

  describe "#expire_files" do
    it "deletes files past the given expiration date" do
      time = Time.utc(2017, 3, 12)

      @storage.create_file("foo")
      @storage.update_info("foo", {})
      @storage.create_file("bar")
      @storage.update_info("bar", {})
      @storage.create_file("baz")

      File.utime(time,     time,     @storage.directory.join("foo"))
      File.utime(time - 1, time - 1, @storage.directory.join("bar"))
      File.utime(time - 2, time - 2, @storage.directory.join("baz"))

      @storage.expire_files(time - 1)
      assert_equal ["data/foo", "data/foo.info"], @storage.directory.children.map(&:to_s)
    end
  end
end
