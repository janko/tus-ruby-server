require "pathname"
require "json"

module Tus
  module Storage
    class Filesystem
      attr_reader :directory

      def initialize(directory)
        @directory = Pathname(directory)

        create_directory!
      end

      def create_file(uid, info = {})
        file_path(uid).write("")
        info_path(uid).write(info.to_json)
      end

      def file_exists?(uid)
        file_path(uid).exist?
      end

      def patch_file(uid, content)
        file_path(uid).write(content, mode: "ab")
      end

      def download_file(uid)
        file_path(uid).to_s
      end

      def read_info(uid)
        data = info_path(uid).binread
        JSON.parse(data)
      end

      def update_info(uid, info)
        info_path(uid).write(info.to_json)
      end

      private

      def file_path(uid)
        directory.join("#{uid}.file")
      end

      def info_path(uid)
        directory.join("#{uid}.info")
      end

      def create_directory!
        directory.mkpath
        directory.chmod(0755)
      end
    end
  end
end
