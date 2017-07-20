# frozen-string-literal: true
require "tus/server"
require "goliath"

class Tus::Server::Goliath < Goliath::API
  # Called as soon as request headers are parsed.
  def on_headers(env, headers)
    # the write end of the pipe is written in #on_body, and the read end is read by Tus::Server
    env["tus.input-reader"], env["tus.input-writer"] = IO.pipe
    # use a thread so that request is being processed in parallel
    env["tus.request-thread"] = Thread.new do
      call_tus_server env.merge("rack.input" => env["tus.input-reader"])
    end
  end

  # Called on each request body chunk received from the client.
  def on_body(env, data)
    # append data to the write end of the pipe if open, otherwise do nothing
    env["tus.input-writer"].write(data) unless env["tus.input-writer"].closed?
  rescue Errno::EPIPE
    # read end of the pipe has been closed, so we close the write end as well
    env["tus.input-writer"].close
  end

  # Called at the end of the request (after #response is called), but also on
  # client disconnect (in which case #response isn't called), so we want to do
  # the same finalization in both methods.
  def on_close(env)
    finalize(env)
  end

  # Called after all the data has been received from the client.
  def response(env)
    status, headers, body = finalize(env)

    env[STREAM_START].call(status, headers)

    operation = proc { body.each { |chunk| env.stream_send(chunk) } }
    callback  = proc { env.stream_close }

    EM.defer(operation, callback) # use an outside thread pool for streaming

    nil
  end

  private

  # Calls the actual Roda application with the slightly modified env hash.
  def call_tus_server(env)
    Tus::Server.call env.merge(
      "rack.url_scheme" => (env["options"][:ssl] ? "https" : "http"), # https://github.com/postrank-labs/goliath/issues/210
      "async.callback"  => nil, # prevent Roda from calling EventMachine when streaming
    )
  end

  # This method needs to be idempotent, because it can be called twice (on
  # normal requests both #response and #on_close will be called, and on client
  # disconnect only #on_close will be called).
  def finalize(env)
    # closing the write end of the pipe will mark EOF on the read end
    env["tus.input-writer"].close unless env["tus.input-writer"].closed?
    # wait for the request to finish
    result = env["tus.request-thread"].value
    # close read end of the pipe, since nothing is going to read from it anymore
    env["tus.input-reader"].close unless env["tus.input-reader"].closed?
    # return rack response
    result
  end
end
