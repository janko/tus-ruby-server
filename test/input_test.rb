require "test_helper"
require "stringio"

describe Tus::Input do
  before do
    @io = StringIO.new("input")
    @input = Tus::Input.new(@io)
  end

  it "wraps the underlying IO object" do
    assert_equal 5, @input.size
    refute @input.eof?

    assert_equal "input", @input.read
    assert @input.eof?
    assert_equal "",      @input.read
    @input.rewind
    refute @input.eof?

    assert_equal "input", @input.read(10)
    assert @input.eof?
    @input.rewind

    assert_equal "in",  @input.read(2)
    refute @input.eof?
    assert_equal "put", @input.read(3)
    assert @input.eof?
    assert_equal nil,   @input.read(1)
    @input.rewind

    buffer = ""
    @input.read(2, buffer)
    assert_equal "in", buffer
    refute @input.eof?
    @input.read(3, buffer)
    assert_equal "put", buffer
    assert @input.eof?
    @input.read(1, buffer)
    assert_equal "", buffer
    assert @input.eof?
    @input.rewind

    @input.close
    refute @io.closed?
  end
end
