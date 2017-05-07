require "tus/errors"

require "pathname"
require "json"
require "fileutils"

module Tus
  module Storage
    class Filesystem
      attr_reader :directory

      def initialize(directory, permissions: 0644, directory_permissions: 0755)
        @directory             = Pathname(directory)
        @permissions           = permissions
        @directory_permissions = directory_permissions

        create_directory! unless @directory.exist?
      end

      def create_file(uid, info = {})
        file_path(uid).binwrite("")
        file_path(uid).chmod(@permissions)

        info_path(uid).binwrite("{}")
        info_path(uid).chmod(@permissions)
      end

      def concatenate(uid, part_uids, info = {})
        create_file(uid, info)

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
        length = range ? range.size : file.size

        # Create an Enumerator which will yield chunks of the requested file
        # content, allowing tus server to efficiently stream requested content
        # to the client.
        chunks = Enumerator.new do |yielder|
          file.seek(range.begin) if range
          remaining_length = length

          while remaining_length > 0
            chunk = file.read([16*1024, remaining_length].min) or break
            remaining_length -= chunk.bytesize
            yielder << chunk
          end
        end

        # We return a response object that responds to #each, #length and #close,
        # which the tus server can return directly as the Rack response.
        Response.new(chunks: chunks, length: length, close: ->{file.close})
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
        directory.chmod(@directory_permissions)
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
