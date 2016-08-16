require "pathname"
require "json"

module Tus
  module Storage
    class Filesystem
      attr_reader :directory

      def initialize(directory)
        @directory = Pathname(directory)

        create_directory! unless @directory.exist?
      end

      def create_file(uid, info = {})
        write(file_path(uid), "")
        write(info_path(uid), info.to_json)
      end

      def file_exists?(uid)
        file_path(uid).exist?
      end

      def read_file(uid)
        file_path(uid).binread
      end

      def patch_file(uid, content)
        write(file_path(uid), content, mode: "ab")
      end

      def download_file(uid)
        file_path(uid).to_s
      end

      def delete_file(uid)
        file_path(uid).delete
        info_path(uid).delete
      end

      def read_info(uid)
        data = info_path(uid).binread
        JSON.parse(data)
      end

      def update_info(uid, info)
        write(info_path(uid), info.to_json)
      end

      def list_files
        paths = Dir[directory.join("*.file")]
        paths.map { |path| File.basename(path, ".file") }
      end

      private

      def write(pathname, content, mode: "wb")
        pathname.open(mode) do |file|
          file.sync = true
          file.write(content)
        end
      end

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
