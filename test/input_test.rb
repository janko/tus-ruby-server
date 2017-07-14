require "test_helper"
require "stringio"
require "tempfile"

describe Tus::Input do
  before do
    @io    = StringIO.new("input")
    @input = Tus::Input.new(@io)
  end

  describe "#read" do
    describe "without arguments" do
      it "reads all content" do
        assert_equal "input", @input.read
      end

      it "reads remaining content" do
        @input.read(2)
        assert_equal "put", @input.read
      end

      it "returns empty string on EOF" do
        @input.read
        assert_equal "", @input.read
      end
    end

    describe "with length" do
      it "reads specified number of bytes" do
        assert_equal "in",  @input.read(2)
        assert_equal "put", @input.read(5)
      end

      it "returns nil on EOF" do
        @input.read
        assert_nil @input.read(1)
      end
    end

    describe "with length and buffer" do
      it "reads specified number of bytes" do
        assert_equal "in",  @input.read(2, "")
        assert_equal "put", @input.read(5, "")
      end

      it "replaces the given buffer string" do
        buffer = ""
        @input.read(2, buffer)
        assert_equal "in", buffer
        @input.read(5, buffer)
        assert_equal "put", buffer
        @input.read(1, buffer)
        assert_equal "", buffer
      end

      it "returns nil on EOF" do
        @input.read
        assert_nil @input.read(2, "")
      end
    end

    it "raises exception when attempting to read more than limit" do
      @input = Tus::Input.new(StringIO.new("0123456789"), limit: 5)
      assert_raises(Tus::MaxSizeExceeded) { @input.read }

      @input = Tus::Input.new(StringIO.new("0123456789"), limit: 5)
      assert_raises(Tus::MaxSizeExceeded) { @input.read(10) }

      @input = Tus::Input.new(StringIO.new("0123456789"), limit: 5)
      @input.read(5)
      assert_raises(Tus::MaxSizeExceeded) { @input.read(1) }
    end

    it "recovers from closed sockets on chunked requests when using Unicorn" do
      require "unicorn"

      rack_input = Object.new
      rack_input.instance_eval { def read(*args) raise Unicorn::ClientShutdown end }

      @input = Tus::Input.new(rack_input)
      assert_equal "",  @input.read
      assert_nil        @input.read(1)
      assert_nil        @input.read(1, outbuf = "outbuf")
      assert_equal "",  outbuf

      @input = Tus::Input.new(rack_input, content_length: 10)
      assert_raises(Unicorn::ClientShutdown) { @input.read }
    end
  end

  describe "#rewind" do
    it "rewinds the input" do
      assert_equal "input", @input.read
      @input.rewind
      assert_equal "input", @input.read
    end

    it "resets bytes read" do
      @input.read
      @input.rewind
      assert_equal 0, @input.bytes_read
    end
  end

  describe "#size" do
    it "returns content length" do
      @input = Tus::Input.new(IO.pipe[0], content_length: 10)
      assert_equal 10, @input.size

      @input = Tus::Input.new(IO.pipe[0])
      assert_nil @input.size
    end

    it "returns size of Tempfile or StringIO inputs" do
      @input = Tus::Input.new(StringIO.new("input"))
      assert_equal 5, @input.size

      @input = Tus::Input.new(Tempfile.new)
      assert_equal 0, @input.size

      @input = Tus::Input.new(IO.pipe[0])
      assert_nil @input.size
    end
  end

  describe "#close" do
    it "doesn't close the underlying input" do
      @input.close
      refute @io.closed?
    end
  end

  describe "#bytes_read" do
    it "returns how many bytes were read" do
      @input.read(2)
      assert_equal 2, @input.bytes_read
      @input.read(2, "")
      assert_equal 4, @input.bytes_read
      @input.read
      assert_equal 5, @input.bytes_read
    end
  end
end
