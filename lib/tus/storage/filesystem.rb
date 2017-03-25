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
        file_path(uid).binwrite("")
        info_path(uid).binwrite("{}")
      end

      def concatenate(uid, part_uids, info = {})
        file_path(uid).open("wb") do |file|
          part_uids.each do |part_uid|
            # Rather than checking upfront whether all parts exist, we use
            # exception flow to account for the possibility of parts being
            # deleted during concatenation.
            begin
              IO.copy_stream(file_path(part_uid), file)
            rescue Errno::ENOENT
              raise Tus::Error, "some parts for concatenation are missing"
            end
          end
        end

        # Delete parts after concatenation.
        delete(part_uids)

        # Tus server requires us to return the size of the concatenated file.
        file_path(uid).size
      end

      def patch_file(uid, input, info = {})
        exists!(uid)

        file_path(uid).open("ab") { |file| IO.copy_stream(input, file) }
      end

      def read_info(uid)
        exists!(uid)

        JSON.parse(info_path(uid).binread)
      end

      def update_info(uid, info)
        exists!(uid)

        info_path(uid).binwrite(JSON.generate(info))
      end

      def get_file(uid, info = {}, range: nil)
        exists!(uid)

        file = file_path(uid).open("rb")
        range ||= 0..(file.size - 1)
        length = range.end - range.begin + 1

        chunks = Enumerator.new do |yielder|
          file.seek(range.begin)
          remaining_length = length

          while remaining_length > 0
            chunk = file.read([16*1024, remaining_length].min, buffer ||= "") or break
            remaining_length -= chunk.bytesize
            yielder << chunk
          end
        end

        Response.new(
          chunks: chunks,
          length: length,
          close:  ->{file.close},
        )
      end

      def delete_file(uid, info = {})
        delete([uid])
      end

      def expire_files(expiration_date)
        uids = directory.children
          .select { |pathname| pathname.mtime <= expiration_date }
          .map { |pathname| pathname.basename(".*").to_s }

        delete(uids)
      end

      private

      def delete(uids)
        paths = uids.flat_map { |uid| [file_path(uid), info_path(uid)] }

        FileUtils.rm_f paths
      end

      def exists!(uid)
        raise Tus::NotFound if !file_path(uid).exist?
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
