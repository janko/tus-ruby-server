require "tus/errors"

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
        file_path(uid).open("wb") { |file| file.write("") }
      end

      def concatenate(uid, part_uids, info = {})
        file_path(uid).open("wb") do |file|
          begin
            part_uids.each do |part_uid|
              IO.copy_stream(file_path(part_uid), file)
            end
          rescue Errno::ENOENT
            raise Tus::Error, "some parts for concatenation are missing"
          end
        end

        delete(part_uids)

        # server requires us to return the size of the concatenated file
        file_path(uid).size
      end

      def patch_file(uid, io, info = {})
        raise Tus::NotFound if !file_path(uid).exist?

        file_path(uid).open("ab") { |file| IO.copy_stream(io, file) }
      end

      def read_info(uid)
        raise Tus::NotFound if !file_path(uid).exist?

        begin
          data = info_path(uid).binread
        rescue Errno::ENOENT
          data = "{}"
        end

        JSON.parse(data)
      end

      def update_info(uid, info)
        info_path(uid).open("wb") { |file| file.write(info.to_json) }
      end

      def get_file(uid, info = {}, range: nil)
        raise Tus::NotFound if !file_path(uid).exist?

        file = file_path(uid).open("rb")
        range ||= 0..file.size-1
        remaining_length = range.end - range.begin + 1

        chunks = Enumerator.new do |yielder|
          file.seek(range.begin)
          buffer = ""

          while remaining_length > 0
            chunk = file.read([16*1024, remaining_length].min, buffer)
            break unless chunk
            remaining_length -= chunk.bytesize

            yielder << chunk
          end
        end

        Response.new(
          chunks: chunks,
          length: remaining_length,
          close:  ->{file.close},
        )
      end

      def delete_file(uid, info = {})
        delete([uid])
      end

      def expire_files(expiration_date)
        uids = []

        Pathname.glob(directory.join("*.file")).each do |pathname|
          uids << pathname.basename(".*") if pathname.mtime <= expiration_date
        end

        delete(uids)
      end

      private

      def delete(uids)
        paths = uids.flat_map { |uid| [file_path(uid), info_path(uid)] }
        FileUtils.rm_f paths
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
        def initialize(chunks:, close:, length:)
          @chunks = chunks
          @close  = close
          @length = length
        end

        def length
          @length
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
