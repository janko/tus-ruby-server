require "pathname"
require "json"
require "fileutils"

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
        update_info(uid, info)
      end

      def concatenate(uid, part_uids, info = {})
        open(file_path(uid), "w") do |file|
          begin
            part_uids.each do |part_uid|
              IO.copy_stream(file_path(part_uid), file)
            end
          rescue Errno::ENOENT
            raise Tus::Error, "some parts for concatenation are missing"
          end
        end

        info["Upload-Length"] = info["Upload-Offset"] = file_path(uid).size.to_s
        update_info(uid, info)

        delete(part_uids)
      end

      def patch_file(uid, io)
        raise Tus::NotFound if !file_path(uid).exist?

        open(file_path(uid), "a") { |file| IO.copy_stream(io, file) }
      end

      def read_info(uid)
        raise Tus::NotFound if !file_path(uid).exist?

        data = info_path(uid).binread

        JSON.parse(data)
      end

      def update_info(uid, info)
        open(info_path(uid), "w") { |file| file.write(info.to_json) }
      end

      def get_file(uid, range: nil)
        raise Tus::NotFound if !file_path(uid).exist?

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
        delete([uid])
      end

      def expire_files(expiration_date)
        Pathname.glob(directory.join("*.file")).each do |pathname|
          if pathname.mtime <= expiration_date
            pathname.delete
            pathname.sub_ext(".info").delete
          end
        end
      end

      private

      def delete(uids)
        paths = uids.flat_map { |uid| [file_path(uid), info_path(uid)] }
        FileUtils.rm_f paths
      end

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
