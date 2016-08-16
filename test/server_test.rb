require "test_helper"
require "rack/test_app"
require "fileutils"
require "base64"

describe Tus::Server do
  before do
    @server = Class.new(Tus::Server)
    @app = Rack::TestApp.wrap(Rack::Lint.new(@server))
  end

  after do
    FileUtils.rm_rf("data")
  end

  def options(hash = {})
    default_options.merge(hash) { |key, old, new| old.merge(new) }
  end

  def default_options
    {headers: {"Tus-Resumable" => "1.0.0"}}
  end

  describe "OPTIONS /files" do
    it "returns 204" do
      response = @app.options "/files", options
      assert_equal 204, response.status
    end

    it "doesn't require Tus-Resumable header" do
      response = @app.options "/files", options(headers: {"Tus-Resumable" => ""})
      assert_equal 204, response.status
    end
  end

  describe "POST /files" do
    it "returns 201" do
      response = @app.post "/files", options(headers: {"Upload-Length" => "100"})
      assert_equal 201, response.status
      assert_match %r{^/files/\w+$}, response.location
    end

    it "requires Upload-Length header" do
      response = @app.post "/files", options
      assert_equal 400, response.status

      response = @app.post "/files", options(headers: {"Upload-Length" => "foo"})
      assert_equal 400, response.status

      response = @app.post "/files", options(headers: {"Upload-Length" => "-1"})
      assert_equal 400, response.status

      @server.opts[:max_size] = 10
      response = @app.post "/files", options(headers: {"Upload-Length" => "100"})
      assert_equal 413, response.status
    end

    it "accepts Upload-Metadata header" do
      response = @app.post "/files", options(
        headers: {"Upload-Length"   => "100",
                  "Upload-Metadata" => "filename #{Base64.encode64("nature.jpg")}"}
      )
      assert_equal 201, response.status
    end

    it "returns Upload-Expires header" do
      response = @app.post "/files", options(headers: {"Upload-Length" => "100"})
      assert response.headers.key?("Upload-Expires")
      Time.parse(response.headers["Upload-Expires"])
    end

    it "requires Tus-Resumable header" do
      response = @app.post "/files", options(headers: {"Tus-Resumable" => "0.0.1"})
      assert_equal 412, response.status
    end
  end

  describe "OPTIONS /files/:uid" do
    it "returns 204" do
      response = @app.post "/files", options(headers: {"Upload-Length" => "100"})
      response = @app.options response.location, options
      assert_equal 204, response.status
    end

    it "returns 404 if file is missing" do
      response = @app.options "/files/unknown", options
      assert_equal 404, response.status
    end

    it "doesn't require Tus-Resumable header" do
      response = @app.post "/files", options(headers: {"Upload-Length" => "100"})
      response = @app.options response.location, options(headers: {"Tus-Resumable" => ""})
      assert_equal 204, response.status
    end
  end

  describe "HEAD /files/:uid" do
    it "returns 204" do
      response = @app.post "/files", options(headers: {"Upload-Length" => "100"})
      response = @app.head response.location, options
      assert_equal 204, response.status
      assert_equal "100", response.headers["Upload-Length"]
      assert_equal "0", response.headers["Upload-Offset"]
    end

    it "returns Upload-Metadata if it was set" do
      response = @app.post "/files", options(
        headers: {"Upload-Length" => "100"}
      )
      response = @app.head response.location, options
      refute response.headers.key?("Upload-Metadata")

      response = @app.post "/files", options(
        headers: {"Upload-Length"   => "100",
                  "Upload-Metadata" => "filename #{Base64.encode64("nature.jpg")}"}
      )
      response = @app.head response.location, options
      assert_equal "filename #{Base64.encode64("nature.jpg")}", response.headers["Upload-Metadata"]
    end

    it "returns Upload-Expires header" do
      response = @app.post "/files", options(headers: {"Upload-Length" => "100"})
      response = @app.head response.location, options
      assert response.headers.key?("Upload-Expires")
      Time.parse(response.headers["Upload-Expires"])
    end

    it "prevents caching" do
      response = @app.post "/files", options(headers: {"Upload-Length" => "100"})
      response = @app.head response.location, options
      assert_equal "no-store", response.headers["Cache-Control"]
    end

    it "returns 404 when file is not found" do
      response = @app.head "/files/unknown", options
      assert_equal 404, response.status
    end

    it "requires Tus-Resumable header" do
      response = @app.post "/files", options(headers: {"Upload-Length" => "100"})
      response = @app.head response.location, options(headers: {"Tus-Resumable" => ""})
      assert_equal 412, response.status
    end
  end

  describe "PATCH /files/:uid" do
    it "returns 204" do
      response = @app.post "/files", options(headers: {"Upload-Length" => "100"})
      response = @app.patch response.location, options(
        input: "a" * 5,
        headers: {"Upload-Offset"  => "0",
                  "Content-Type"   => "application/offset+octet-stream"},
      )
      assert_equal 204, response.status
      assert_equal "5", response.headers["Upload-Offset"]
    end

    it "requires Content-Type to be application/offset+octet-stream" do
      response = @app.post "/files", options(headers: {"Upload-Length" => "100"})
      response = @app.patch response.location, options(
        headers: {"Upload-Offset"  => "0",
                  "Content-Type"   => "image/jpeg"},
      )
      assert_equal 415, response.status
    end

    it "requires Upload-Offset to match current offset" do
      response = @app.post "/files", options(headers: {"Upload-Length" => "100"})
      location = response.location

      response = @app.patch location, options(
        headers: {"Upload-Offset" => "",
                  "Content-Type"  => "application/offset+octet-stream"},
      )
      assert_equal 400, response.status

      response = @app.patch location, options(
        headers: {"Upload-Offset" => "foo",
                  "Content-Type"  => "application/offset+octet-stream"},
      )
      assert_equal 400, response.status

      response = @app.patch location, options(
        headers: {"Upload-Offset" => "-1",
                  "Content-Type"  => "application/offset+octet-stream"},
      )
      assert_equal 400, response.status

      response = @app.patch location, options(
        headers: {"Upload-Offset"  => "5",
                  "Content-Type"   => "application/offset+octet-stream"},
      )
      assert_equal 409, response.status
    end

    it "doesn't allow body to surpass Upload-Length" do
      response = @app.post "/files", options(headers: {"Upload-Length" => "100"})
      location = response.location

      response = @app.patch location, options(
        input: "a" * 150,
        headers: {"Upload-Offset" => "0",
                  "Content-Type"  => "application/offset+octet-stream"},
      )
      assert_equal 413, response.status

      response = @app.patch location, options(
        input: "a" * 50,
        headers: {"Upload-Offset" => "0",
                  "Content-Type"  => "application/offset+octet-stream"},
      )
      assert_equal 204, response.status
      response = @app.patch location, options(
        input: "a" * 100,
        headers: {"Upload-Offset" => "50",
                  "Content-Type"  => "application/offset+octet-stream"},
      )
      assert_equal 413, response.status
    end

    it "returns Upload-Expires header" do
      response = @app.post "/files", options(headers: {"Upload-Length" => "100"})
      response = @app.patch response.location, options(
        input: "a" * 5,
        headers: {"Upload-Offset"  => "0",
                  "Content-Type"   => "application/offset+octet-stream"},
      )
      assert response.headers.key?("Upload-Expires")
      Time.parse(response.headers["Upload-Expires"])
    end

    it "returns 404 when file is missing" do
      response = @app.patch "/files/unknown", options(
        headers: {"Upload-Offset" => "0",
                  "Content-Type"  => "application/offset+octet-stream"},
      )
      assert_equal 404, response.status
    end

    it "requires Tus-Resumable header" do
      response = @app.post "/files", options(headers: {"Upload-Length" => "100"})
      response = @app.patch response.location, options(
        headers: {"Upload-Offset" => "0",
                  "Content-Type"  => "application/offset+octet-stream",
                  "Tus-Resumable" => ""},
      )
      assert_equal 412, response.status
    end
  end

  describe "GET /files/:uid" do
    it "returns the file" do
      response = @app.post "/files", options(
        headers: {"Upload-Length" => "100",
                  "Upload-Metadata" => "filename #{Base64.encode64("image.jpg")},content_type #{Base64.encode64("image/jpeg")}"}
      )
      location = response.location
      response = @app.patch location, options(
        input: "a" * 50,
        headers: {"Upload-Offset" => "0",
                  "Content-Type"  => "application/offset+octet-stream"}
      )
      response = @app.patch location, options(
        input: "a" * 50,
        headers: {"Upload-Offset" => "50",
                  "Content-Type"  => "application/offset+octet-stream"}
      )
      response = @app.get location
      assert_equal "a" * 100, response.body_binary
      assert_equal "image/jpeg", response.headers["Content-Type"]
      assert_equal "attachment; filename=\"image.jpg\"", response.headers["Content-Disposition"]
    end

    it "works without metadata" do
      response = @app.post "/files", options(headers: {"Upload-Length" => "100"})
      location = response.location
      response = @app.patch location, options(
        input: "a" * 100,
        headers: {"Upload-Offset" => "0",
                  "Content-Type"  => "application/offset+octet-stream"}
      )
      response = @app.get location
      assert_equal "a" * 100, response.body_binary
    end

    it "returns 404 if file doesn't exist" do
      response = @app.get "/files/unknown"
      assert_equal 404, response.status
    end
  end

  describe "DELETE /files/:uid" do
    it "returns 204" do
      response = @app.post "/files", options(headers: {"Upload-Length" => "100"})
      response = @app.delete response.location, options
      assert_equal 204, response.status
    end

    it "deletes the upload" do
      response = @app.post "/files", options(headers: {"Upload-Length" => "100"})
      location = response.location
      response = @app.delete location, options
      response = @app.delete location, options
      assert_equal 404, response.status
    end

    it "returns 404 if file doesn't exist" do
      response = @app.delete "/files/unknown", options
      assert_equal 404, response.status
    end
  end

  it "returns TUS headers" do
    extensions = "creation,termination,expiration"

    response = @app.options "/files", options
    assert_equal "1.0.0",    response.headers["Tus-Resumable"]
    assert_equal "1.0.0",    response.headers["Tus-Version"]
    assert_equal extensions, response.headers["Tus-Extension"]

    response = @app.options "/files", options(headers: {"Tus-Resumable" => "0.0.1"})
    assert_equal "1.0.0",    response.headers["Tus-Resumable"]
    assert_equal "1.0.0",    response.headers["Tus-Version"]
    assert_equal extensions, response.headers["Tus-Extension"]
  end

  it "returns Tus-Max-Size header if max size is set" do
    response = @app.options "/files", options
    assert response.headers.key?("Tus-Max-Size")
    assert_equal @server.opts[:max_size].to_s, response.headers["Tus-Max-Size"]

    @server.opts.delete(:max_size)
    response = @app.options "/files", options
    refute response.headers.key?("Tus-Max-Size")
  end

  it "handles CORS" do
    response = @app.options "/files", options(headers: {"Origin" => "tus.io"})
    assert response.headers.key?("Access-Control-Allow-Origin")
    assert response.headers.key?("Access-Control-Allow-Methods")
    assert response.headers.key?("Access-Control-Allow-Headers")
    assert response.headers.key?("Access-Control-Max-Age")

    response = @app.head "/files", options(headers: {"Origin" => "tus.io"})
    assert response.headers.key?("Access-Control-Allow-Origin")
    assert response.headers.key?("Access-Control-Expose-Headers")

    response = @app.head "/files", options
    refute response.headers.key?("Access-Control-Allow-Origin")
  end

  it "expires files" do
    @server.opts[:expiration_time]     = 0
    @server.opts[:expiration_interval] = 0
    response = @app.post "/files", options(headers: {"Upload-Length" => "100"})
    response = @app.head response.location, options
    assert_equal 404, response.status
  end

  it "accepts a trailing slash" do
    response = @app.options "/files/"
    assert_equal 204, response.status
  end

  it "can configure base path" do
    @server.opts[:base_path] = "uploads"
    response = @app.options "/uploads"
    assert_equal 204, response.status
  end
end
