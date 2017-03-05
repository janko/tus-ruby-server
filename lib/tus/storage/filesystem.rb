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
        open(file_path(uid), "a") { |file| IO.copy_stream(io, file) }
      end

      def get_file(uid, range: nil)
        file = file_path(uid).open("r", binmode: true)
        range ||= 0..file.size-1

        chunks = Enumerator.new do |yielder|
          file.seek(range.begin)
          remaining_length = range.end - range.begin + 1
          buffer = ""

          while remaining_length > 0
            chunk = file.read([16*1024, remaining_length].min, buffer)
            break unless chunk
            remaining_length -= chunk.length

            yielder << chunk
          end
        end

        Response.new(chunks: chunks, close: ->{file.close})
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

      class Response
        def initialize(chunks:, close:)
          @chunks = chunks
          @close  = close
        end

        def each(&block)
          @chunks.each(&block)
        end

        def close
          @close.call
        end
      end
    end
  end
end
