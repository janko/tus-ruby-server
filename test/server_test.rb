require "test_helper"
require "rack/test_app"
require "fileutils"
require "base64"
require "uri"
require "digest"

describe Tus::Server do
  before do
    @server = Class.new(Tus::Server)
    @storage = @server.opts[:storage] = Tus::Storage::Filesystem.new("data")

    builder = Rack::Builder.new
    builder.use Rack::Lint
    builder.run Rack::URLMap.new("/files" => @server)

    @app = Rack::TestApp.wrap(builder)
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

  describe "OPTIONS /files/" do
    it "returns 204" do
      response = @app.options "/files/", options
      assert_equal 204, response.status
      assert_equal Tus::Server::SUPPORTED_VERSIONS.join(","), response.headers["Tus-Version"]
      assert_equal Tus::Server::SUPPORTED_EXTENSIONS.join(","), response.headers["Tus-Extension"]
      assert_equal @server.opts[:max_size].to_s, response.headers["Tus-Max-Size"]
      assert_equal Tus::Server::SUPPORTED_CHECKSUM_ALGORITHMS.join(","), response.headers["Tus-Checksum-Algorithm"]
    end

    it "doesn't return Tus-Max-Size if it's not set" do
      @server.opts[:max_size] = nil
      response = @app.options "/files/", options
      assert_equal 204, response.status
      refute response.headers.key?("Tus-Max-Size")
    end

    it "doesn't require Tus-Resumable header" do
      response = @app.options "/files/", options(headers: {"Tus-Resumable" => ""})
      assert_equal 204, response.status
    end
  end

  describe "POST /files/" do
    it "returns 201" do
      response = @app.post "/files/", options(headers: {"Upload-Length" => "100"})
      assert_equal 201, response.status
      assert_match %r{^http://localhost/files/\w+$}, response.location
    end

    it "requires Upload-Length header" do
      response = @app.post "/files/", options
      assert_equal 400, response.status

      response = @app.post "/files/", options(headers: {"Upload-Length" => "foo"})
      assert_equal 400, response.status

      response = @app.post "/files/", options(headers: {"Upload-Length" => "-1"})
      assert_equal 400, response.status

      @server.opts[:max_size] = 10
      response = @app.post "/files/", options(headers: {"Upload-Length" => "100"})
      assert_equal 413, response.status
    end

    it "accepts Upload-Metadata header" do
      response = @app.post "/files/", options(
        headers: {"Upload-Length"   => "100",
                  "Upload-Metadata" => "filename #{Base64.encode64("nature.jpg")}"}
      )
      assert_equal 201, response.status
      file_path = URI(response.location).path

      response = @app.head file_path, options
      assert_equal "filename #{Base64.encode64("nature.jpg")}", response.headers["Upload-Metadata"]
    end

    it "doesn't accept invalid Upload-Metadata header" do
      response = @app.post "/files/", options(
        headers: {"Upload-Length"   => "100",
                  "Upload-Metadata" => "❨╯°□°❩╯︵┻━┻ #{Base64.encode64("nature.jpg")}"}
      )
      assert_equal 400, response.status

      response = @app.post "/files/", options(
        headers: {"Upload-Length"   => "100",
                  "Upload-Metadata" => "filename *****"}
      )
      assert_equal 400, response.status
    end

    it "handles Upload-Concat header" do
      response = @app.post "/files/", options(
        headers: {"Upload-Length" => "1",
                  "Upload-Concat" => "partial"}
      )
      assert_equal 201, response.status
      assert_equal "partial", response.headers["Upload-Concat"]
      file_path1 = URI(response.location).path
      response = @app.patch file_path1, options(
        input: "a",
        headers: {"Upload-Offset" => "0",
                  "Content-Type"  => "application/offset+octet-stream"}
      )
      assert_equal 204, response.status

      response = @app.post "/files/", options(
        headers: {"Upload-Length" => "1",
                  "Upload-Concat" => "partial"}
      )
      assert_equal 201, response.status
      assert_equal "partial", response.headers["Upload-Concat"]
      file_path2 = URI(response.location).path
      response = @app.patch file_path2, options(
        input: "b",
        headers: {"Upload-Offset" => "0",
                  "Content-Type"  => "application/offset+octet-stream"}
      )
      assert_equal 204, response.status

      response = @app.post "/files/", options(
        headers: {"Upload-Concat" => "final;#{file_path1} #{file_path2}"}
      )
      assert_equal 201, response.status
      assert_equal "final;#{file_path1} #{file_path2}", response.headers["Upload-Concat"]
      assert_equal "2", response.headers["Upload-Length"]
      assert_equal "2", response.headers["Upload-Offset"]

      file_path = URI(response.location).path
      response = @app.get file_path, options
      assert_equal "ab", response.body_binary

      response = @app.get file_path1, options
      assert_equal 404, response.status
      response = @app.get file_path2, options
      assert_equal 404, response.status
    end

    it "can concat unfinished uploads" do
      response = @app.post "/files/", options(
        headers: {"Upload-Length" => "1",
                  "Upload-Concat" => "partial"}
      )
      file_path1 = URI(response.location).path

      response = @app.post "/files/", options(
        headers: {"Upload-Length" => "1",
                  "Upload-Concat" => "partial"}
      )
      file_path2 = URI(response.location).path

      response = @app.post "/files/", options(
        headers: {"Upload-Concat" => "final;#{file_path1} #{file_path2}"}
      )
      assert_equal 201, response.status
      assert_equal "final;#{file_path1} #{file_path2}", response.headers["Upload-Concat"]
      assert_equal "0", response.headers["Upload-Length"]
      assert_equal "0", response.headers["Upload-Offset"]
    end

    it "doesn't allow invalid Upload-Concat header" do
      response = @app.post "/files/", options(
        headers: {"Upload-Length" => "0",
                  "Upload-Concat" => "foo"}
      )
      assert_equal 400, response.status
    end

    it "creates Upload-Expires header" do
      response = @app.post "/files/", options(headers: {"Upload-Length" => "100"})
      assert response.headers.key?("Upload-Expires")
      Time.parse(response.headers["Upload-Expires"])
      file_path = URI(response.location).path

      response = @app.head file_path, options
      assert response.headers.key?("Upload-Expires")
      Time.parse(response.headers["Upload-Expires"])
    end

    it "can create upload without Upload-Length with Upload-Defer-Length" do
      response = @app.post "/files/", options(headers: {"Upload-Defer-Length" => "1"})
      assert_equal 201, response.status
      file_path = URI(response.location).path

      response = @app.head file_path, options
      refute response.headers.key?("Upload-Length")
      assert_equal "1", response.headers["Upload-Defer-Length"]

      response = @app.patch file_path, options(
        headers: {"Upload-Offset" => "0",
                  "Content-Type"  => "application/offset+octet-stream"}
      )
      assert_equal 400, response.status

      response = @app.patch file_path, options(
        headers: {"Upload-Length" => "100",
                  "Upload-Offset" => "0",
                  "Content-Type"  => "application/offset+octet-stream"}
      )
      assert_equal 204, response.status
      assert_equal "100", response.headers["Upload-Length"]
      refute response.headers.key?("Upload-Defer-Length")
    end

    it "requires Tus-Resumable header" do
      response = @app.post "/files/", options(headers: {"Tus-Resumable" => "0.0.1"})
      assert_equal 412, response.status
    end
  end

  describe "OPTIONS /files/:uid" do
    it "returns 204" do
      response = @app.post "/files/", options(headers: {"Upload-Length" => "100"})
      file_path = URI(response.location).path
      response = @app.options file_path, options
      assert_equal 204, response.status
      assert_equal Tus::Server::SUPPORTED_VERSIONS.join(","), response.headers["Tus-Version"]
      assert_equal Tus::Server::SUPPORTED_EXTENSIONS.join(","), response.headers["Tus-Extension"]
      assert_equal @server.opts[:max_size].to_s, response.headers["Tus-Max-Size"]
      assert_equal Tus::Server::SUPPORTED_CHECKSUM_ALGORITHMS.join(","), response.headers["Tus-Checksum-Algorithm"]
    end

    it "doesn't return Tus-Max-Size if it's not set" do
      response = @app.post "/files/", options(headers: {"Upload-Length" => "100"})
      file_path = URI(response.location).path
      @server.opts[:max_size] = nil
      response = @app.options file_path, options
      assert_equal 204, response.status
      refute response.headers.key?("Tus-Max-Size")
    end

    it "returns 404 if file is missing" do
      response = @app.options "/files/unknown", options
      assert_equal 404, response.status
    end

    it "doesn't require Tus-Resumable header" do
      response = @app.post "/files/", options(headers: {"Upload-Length" => "100"})
      file_path = URI(response.location).path
      response = @app.options file_path, options(headers: {"Tus-Resumable" => ""})
      assert_equal 204, response.status
    end
  end

  describe "HEAD /files/:uid" do
    it "returns 204" do
      response = @app.post "/files/", options(headers: {"Upload-Length" => "100"})
      file_path = URI(response.location).path
      response = @app.head file_path, options
      assert_equal 204, response.status
      assert_equal "100", response.headers["Upload-Length"]
      assert_equal "0", response.headers["Upload-Offset"]
    end

    it "prevents caching" do
      response = @app.post "/files/", options(headers: {"Upload-Length" => "100"})
      file_path = URI(response.location).path
      response = @app.head file_path, options
      assert_equal "no-store", response.headers["Cache-Control"]
    end

    it "returns 404 when file is not found" do
      response = @app.head "/files/unknown", options
      assert_equal 404, response.status
    end

    it "requires Tus-Resumable header" do
      response = @app.post "/files/", options(headers: {"Upload-Length" => "100"})
      file_path = URI(response.location).path
      response = @app.head file_path, options(headers: {"Tus-Resumable" => ""})
      assert_equal 412, response.status
    end

    it "doesn't return response on errors" do
      response = @app.head "/files/unknown", options
      assert_equal "", response.body_binary
    end
  end

  describe "PATCH /files/:uid" do
    it "returns 204" do
      response = @app.post "/files/", options(headers: {"Upload-Length" => "100"})
      file_path = URI(response.location).path
      response = @app.patch file_path, options(
        input: "a" * 5,
        headers: {"Upload-Offset"  => "0",
                  "Content-Type"   => "application/offset+octet-stream"},
      )
      assert_equal 204, response.status
      assert_equal "5", response.headers["Upload-Offset"]
    end

    it "requires Content-Type to be application/offset+octet-stream" do
      response = @app.post "/files/", options(headers: {"Upload-Length" => "100"})
      file_path = URI(response.location).path
      response = @app.patch file_path, options(
        headers: {"Upload-Offset"  => "0",
                  "Content-Type"   => "image/jpeg"},
      )
      assert_equal 415, response.status
    end

    it "requires Upload-Offset to match current offset" do
      response = @app.post "/files/", options(headers: {"Upload-Length" => "100"})
      file_path = URI(response.location).path

      response = @app.patch file_path, options(
        headers: {"Upload-Offset" => "",
                  "Content-Type"  => "application/offset+octet-stream"},
      )
      assert_equal 400, response.status

      response = @app.patch file_path, options(
        headers: {"Upload-Offset" => "foo",
                  "Content-Type"  => "application/offset+octet-stream"},
      )
      assert_equal 400, response.status

      response = @app.patch file_path, options(
        headers: {"Upload-Offset" => "-1",
                  "Content-Type"  => "application/offset+octet-stream"},
      )
      assert_equal 400, response.status

      response = @app.patch file_path, options(
        headers: {"Upload-Offset"  => "5",
                  "Content-Type"   => "application/offset+octet-stream"},
      )
      assert_equal 409, response.status
    end

    it "doesn't allow body to surpass Upload-Length" do
      response = @app.post "/files/", options(headers: {"Upload-Length" => "100"})
      file_path = URI(response.location).path

      response = @app.patch file_path, options(
        input: "a" * 150,
        headers: {"Upload-Offset" => "0",
                  "Content-Type"  => "application/offset+octet-stream"},
      )
      assert_equal 413, response.status

      response = @app.patch file_path, options(
        input: "a" * 50,
        headers: {"Upload-Offset" => "0",
                  "Content-Type"  => "application/offset+octet-stream"},
      )
      assert_equal 204, response.status
      response = @app.patch file_path, options(
        input: "a" * 100,
        headers: {"Upload-Offset" => "50",
                  "Content-Type"  => "application/offset+octet-stream"},
      )
      assert_equal 413, response.status
    end

    it "doesn't allow modifying completed uploads" do
      response = @app.post "/files/", options(headers: {"Upload-Length" => "0"})
      file_path = URI(response.location).path
      response = @app.patch file_path, options(
        headers: {"Upload-Offset" => "0",
                  "Content-Type" => "application/offset+octet-stream"}
      )
      assert_equal 403, response.status
    end

    it "handles Upload-Checksum header" do
      response = @app.post "/files/", options(headers: {"Upload-Length" => "100"})
      file_path = URI(response.location).path

      response = @app.patch file_path, options(
        input: "a" * 50,
        headers: {"Upload-Offset"   => "0",
                  "Upload-Checksum" => "sha1 #{Base64.encode64(Digest::SHA1.hexdigest("a" * 50))}",
                  "Content-Type"    => "application/offset+octet-stream"}
      )
      assert_equal 204, response.status
    end

    it "fails on invalid Upload-Checksum header" do
      response = @app.post "/files/", options(headers: {"Upload-Length" => "100"})
      file_path = URI(response.location).path

      response = @app.patch file_path, options(
        input: "a" * 50,
        headers: {"Upload-Offset"   => "0",
                  "Upload-Checksum" => "sha1 foobar",
                  "Content-Type"    => "application/offset+octet-stream"}
      )
      assert_equal 460, response.status

      response = @app.patch file_path, options(
        input: "a" * 50,
        headers: {"Upload-Offset"   => "0",
                  "Upload-Checksum" => "foobar #{Base64.encode64(Digest::SHA1.hexdigest("a" * 50))}",
                  "Content-Type"    => "application/offset+octet-stream"}
      )
      assert_equal 400, response.status
    end

    it "returns 404 when file is missing" do
      response = @app.patch "/files/unknown", options(
        headers: {"Upload-Offset" => "0",
                  "Content-Type"  => "application/offset+octet-stream"},
      )
      assert_equal 404, response.status
    end

    it "requires Tus-Resumable header" do
      response = @app.post "/files/", options(headers: {"Upload-Length" => "100"})
      file_path = URI(response.location).path
      response = @app.patch file_path, options(
        headers: {"Upload-Offset" => "0",
                  "Content-Type"  => "application/offset+octet-stream",
                  "Tus-Resumable" => ""},
      )
      assert_equal 412, response.status
    end
  end

  describe "GET /files/:uid" do
    it "returns the file" do
      response = @app.post "/files/", options(
        headers: {"Upload-Length" => "100",
                  "Upload-Metadata" => "filename #{Base64.encode64("image.jpg")},content_type #{Base64.encode64("image/jpeg")}"}
      )
      file_path = URI(response.location).path
      response = @app.patch file_path, options(
        input: "a" * 50,
        headers: {"Upload-Offset" => "0",
                  "Content-Type"  => "application/offset+octet-stream"}
      )
      response = @app.patch file_path, options(
        input: "a" * 50,
        headers: {"Upload-Offset" => "50",
                  "Content-Type"  => "application/offset+octet-stream"}
      )
      response = @app.get file_path
      assert_equal "a" * 100, response.body_binary
      assert_equal "image/jpeg", response.headers["Content-Type"]
      assert_equal "attachment; filename=\"image.jpg\"", response.headers["Content-Disposition"]
    end

    it "works without metadata" do
      response = @app.post "/files/", options(headers: {"Upload-Length" => "100"})
      file_path = URI(response.location).path
      response = @app.patch file_path, options(
        input: "a" * 100,
        headers: {"Upload-Offset" => "0",
                  "Content-Type"  => "application/offset+octet-stream"}
      )
      response = @app.get file_path
      assert_equal "a" * 100, response.body_binary
    end

    it "returns 404 if file doesn't exist" do
      response = @app.get "/files/unknown"
      assert_equal 404, response.status
    end
  end

  describe "DELETE /files/:uid" do
    it "returns 204" do
      response = @app.post "/files/", options(headers: {"Upload-Length" => "100"})
      file_path = URI(response.location).path
      response = @app.delete file_path, options
      assert_equal 204, response.status
    end

    it "deletes the upload" do
      response = @app.post "/files/", options(headers: {"Upload-Length" => "100"})
      file_path = URI(response.location).path
      response = @app.delete file_path, options
      response = @app.delete file_path, options
      assert_equal 404, response.status
    end

    it "returns 404 if file doesn't exist" do
      response = @app.delete "/files/unknown", options
      assert_equal 404, response.status
    end
  end

  it "includes Tus-Version when invalid Tus-Resumable was given" do
    response = @app.post "/files/", options(headers: {"Upload-Length" => "100"})
    file_path = URI(response.location).path
    response = @app.head file_path, options(headers: {"Tus-Resumable" => "0.0.1"})
    assert_equal 412, response.status
    assert_equal Tus::Server::SUPPORTED_VERSIONS.join(","), response.headers["Tus-Version"]
  end

  it "handles CORS" do
    response = @app.options "/files/", options(headers: {"Origin" => "tus.io"})
    assert response.headers.key?("Access-Control-Allow-Origin")
    assert response.headers.key?("Access-Control-Allow-Methods")
    assert response.headers.key?("Access-Control-Allow-Headers")
    assert response.headers.key?("Access-Control-Max-Age")

    response = @app.head "/files/", options(headers: {"Origin" => "tus.io"})
    assert response.headers.key?("Access-Control-Allow-Origin")
    assert response.headers.key?("Access-Control-Expose-Headers")

    response = @app.head "/files/", options
    refute response.headers.key?("Access-Control-Allow-Origin")
  end

  it "expires files" do
    @server.opts[:expiration_time]     = 0
    @server.opts[:expiration_interval] = 0
    response = @app.post "/files/", options(headers: {"Upload-Length" => "100"})
    file_path = URI(response.location).path
    @app.options "/files/", options # trigger expirator
    loop { break unless @storage.file_exists?(file_path.split("/").last) }
    response = @app.head file_path, options
    break if response.status == 404
  end

  it "supports overriding HTTP verb with X-HTTP-Method-Override" do
    response = @app.get "/files/", options(headers: {"X-HTTP-Method-Override" => "OPTIONS"})
    assert_equal 204, response.status
  end

  it "returns 405 method allowed" do
    response = @app.patch "/files/", options
    assert_equal 405, response.status

    response = @app.post "/files/", options(headers: {"Upload-Length" => "100"})
    file_path = URI(response.location).path
    response = @app.post file_path, options
    assert_equal 405, response.status
  end
end
