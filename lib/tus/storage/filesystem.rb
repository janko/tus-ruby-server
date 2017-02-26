require "tus/utils"

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
        open(file_path(uid), "w") { |file| file.write("") }
        open(info_path(uid), "w") { |file| file.write(info.to_json) }
      end

      def file_exists?(uid)
        file_path(uid).exist? && info_path(uid).exist?
      end

      def read_file(uid)
        file_path(uid).binread
      end

      def patch_file(uid, io)
        open(file_path(uid), "a") do |file|
          Utils.read_chunks(io) { |chunk| file.write(chunk) }
        end
      end

      def download_file(uid)
        file_path(uid).to_s
      end

      def delete_file(uid)
        if file_exists?(uid)
          file_path(uid).delete
          info_path(uid).delete
        end
      end

      def read_info(uid)
        data = info_path(uid).binread
        JSON.parse(data)
      end

      def update_info(uid, info)
        open(info_path(uid), "w") { |file| file.write(info.to_json) }
      end

      def list_files
        paths = Dir[directory.join("*.file")]
        paths.map { |path| File.basename(path, ".file") }
      end

      private

      def open(pathname, mode, **options)
        pathname.open(mode, binmode: true, **options) do |file|
          file.sync = true
          yield file
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
