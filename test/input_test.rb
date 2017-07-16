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

    it "recovers from closed sockets when using Unicorn" do
      require "unicorn"

      rack_input = Object.new
      rack_input.instance_eval { def read(*args) raise Unicorn::ClientShutdown end }

      @input = Tus::Input.new(rack_input)
      assert_equal "",  @input.read
      assert_nil        @input.read(1)
      assert_nil        @input.read(1, outbuf = "outbuf")
      assert_equal "",  outbuf
    end
  end

  describe "#rewind" do
    it "rewinds the input" do
      assert_equal "input", @input.read
      @input.rewind
      assert_equal "input", @input.read
    end

    it "resets bytes read" do
      @input = Tus::Input.new(StringIO.new("0123456789"), limit: 5)
      @input.read(3)
      @input.rewind
      @input.read(3)
    end
  end

  describe "#close" do
    it "doesn't close the underlying input" do
      @input.close
      refute @io.closed?
    end
  end
end
