ENV["MT_NO_EXPECTATIONS"] = "1"

require "minitest/test"
require "rack/test_app"

require "tus-server"

class MinitestWorld
  include Minitest::Assertions
  attr_accessor :assertions

  def initialize
    @assertions = 0
  end

  def request(verb, path, headers: {}, **options)
    if headers["Transfer-Encoding"] == "chunked"
      chunked_request(verb, path, headers: headers, **options)
    else
      @app.send(verb, path, headers: headers, **options)
    end
  end

  private

  # Hack around rack-test_app not supporting excluding Content-Length
  def chunked_request(verb, path, **options)
    env = Rack::TestApp.new_env(verb.upcase.to_sym, path, **options)
    env.delete("CONTENT_LENGTH")
    Rack::TestApp::Result.new(*@app.instance_variable_get("@app").call(env))
  end
end

World do
  MinitestWorld.new
end

Before do
  @server = Class.new(Tus::Server)
  @storage = @server.opts[:storage] = Tus::Storage::Filesystem.new("data")

  builder = Rack::Builder.new
  builder.use Rack::Lint
  builder.run Rack::URLMap.new("/files" => @server)

  @app = Rack::TestApp.wrap(builder)
end

After do
  FileUtils.rm_rf("data")
end
