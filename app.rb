require "goliath"

class App < Goliath::API
  def response(env)
    env[STREAM_START].call(200, {})
    3.times do
      env[STREAM_SEND].binding.receiver.callback do
        puts "sleeping"
        sleep 1
        env[STREAM_SEND].binding.receiver.conn.send_data "chunk"
      end
    end
    env[STREAM_CLOSE].call

    nil
  end
end
