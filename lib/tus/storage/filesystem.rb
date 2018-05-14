# frozen-string-literal: true

require "tus/response"
require "tus/errors"

require "pathname"
require "json"
require "fileutils"

module Tus
  module Storage
    class Filesystem
      attr_reader :directory

      # Initializes the storage with a directory, in which it will save all
      # files. Creates the directory if it doesn't exist.
      def initialize(directory, permissions: 0644, directory_permissions: 0755)
        @directory             = Pathname(directory)
        @permissions           = permissions
        @directory_permissions = directory_permissions

        create_directory! unless @directory.exist?
      end

      # Creates a file for storing uploaded data and a file for storing info.
      def create_file(uid, info = {})
        file_path(uid).binwrite("")
        file_path(uid).chmod(@permissions)

        info_path(uid).binwrite("{}") unless info_path(uid).exist?
        info_path(uid).chmod(@permissions)
      end

      # Concatenates multiple partial uploads into a single upload, and returns
      # the size of the resulting upload. The partial uploads are deleted after
      # concatenation.
      #
      # Raises Tus::Error if any partial upload is missing.
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

      # Appends data to the specified upload in a streaming fashion, and
      # returns the number of bytes it managed to save.
      def patch_file(uid, input, info = {})
        file_path(uid).open("ab") { |file| IO.copy_stream(input, file) }
      end

      # Returns info of the specified upload. Raises Tus::NotFound if the upload
      # wasn't found.
      def read_info(uid)
        raise Tus::NotFound if !file_path(uid).exist?

        JSON.parse(info_path(uid).binread)
      end

      # Updates info of the specified upload.
      def update_info(uid, info)
        info_path(uid).binwrite(JSON.generate(info))
      end

      # Returns a Tus::Response object through which data of the specified
      # upload can be retrieved in a streaming fashion. Accepts an optional
      # range parameter for selecting a subset of bytes to retrieve.
      def get_file(uid, info = {}, range: nil)
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

        Response.new(chunks: chunks, close: file.method(:close), path: file_path(uid).to_s)
      end

      # Deletes data and info files for the specified upload.
      def delete_file(uid, info = {})
        delete([uid])
      end

      # Deletes data and info files of uploads older than the specified date.
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

      def file_path(uid)
        directory.join("#{uid}")
      end

      def info_path(uid)
        directory.join("#{uid}.info")
      end

      def create_directory!
        directory.mkpath
        directory.chmod(@directory_permissions)
      end

      class Response < Tus::Response
        def initialize(path:, **options)
          super(**options)
          @path = path
        end

        # Rack::Sendfile middleware needs response body to respond to #to_path
        def to_path
          @path
        end
      end
    end
  end
end
