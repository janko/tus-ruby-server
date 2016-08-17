require "tus/info"
require "time"

module Tus
  class Expirator
    attr_reader :storage, :interval

    def initialize(storage, interval: 60)
      @storage  = storage
      @interval = interval
    end

    def expire_files!
      return unless expiration_due?
      update_last_expiration

      Thread.new do
        thread = Thread.current
        thread.abort_on_exception = false
        thread.report_on_exception = true if thread.respond_to?(:report_on_exception) # Ruby 2.4

        _expire_files!
      end
    end

    def expiration_due?
      Time.now - interval > last_expiration
    end

    private

    def _expire_files!
      storage.list_files.each do |uid|
        next if uid == "expirator"
        begin
          info = Info.new(storage.read_info(uid))
          storage.delete_file(uid) if Time.now > info.expires
        rescue
        end
      end
    end

    def last_expiration
      info = storage.read_info("expirator")
      Time.parse(info["Last-Expiration"])
    rescue
      Time.new(0)
    end

    def update_last_expiration
      if storage.file_exists?("expirator")
        storage.update_info("expirator", {"Last-Expiration" => Time.now.httpdate})
      else
        storage.create_file("expirator", {"Last-Expiration" => Time.now.httpdate})
      end
    end
  end
end
