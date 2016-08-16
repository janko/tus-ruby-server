require "tmpdir"
require "time"

module Tus
  class Expirator
    attr_reader :storage, :interval

    def initialize(storage, interval: 60)
      @storage  = storage
      @interval = interval
    end

    def expire_files!
      begin
        _expire_files! if expiration_due?
      rescue => error
        warn "#{error.backtrace.first}: #{error.message} (#{error.class})"
        error.backtrace[1..-1].each { |line| warn line }
      end
    end

    def expiration_due?
      Time.now - interval > last_expiration
    end

    private

    def _expire_files!
      storage.list_files.each do |uid|
        info = storage.read_info(uid)
        expires_at = Time.parse(info["Upload-Expires"])
        storage.delete_file(uid) if Time.now > expires_at
      end

      update_last_expiration
    end

    def last_expiration
      if File.exist?(last_expiration_path)
        File.mtime(last_expiration_path)
      else
        Time.new(0)
      end
    end

    def update_last_expiration
      FileUtils.touch(last_expiration_path)
    end

    def last_expiration_path
      File.join(Dir.tmpdir, "tus-last_expiration")
    end
  end
end
