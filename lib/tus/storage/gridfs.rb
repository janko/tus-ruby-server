require "mongo"

require "tus/info"
require "tus/errors"

require "digest"

module Tus
  module Storage
    class Gridfs
      attr_reader :client, :prefix, :bucket, :chunk_size

      def initialize(client:, prefix: "fs", chunk_size: 256*1024)
        @client     = client
        @prefix     = prefix
        @chunk_size = chunk_size
        @bucket     = client.database.fs(bucket_name: prefix)

        @bucket.send(:ensure_indexes!)
      end

      def create_file(uid, info = {})
        content_type = Tus::Info.new(info).metadata["content_type"]

        create_grid_file(
          filename:     uid,
          content_type: content_type,
        )
      end

      def concatenate(uid, part_uids, info = {})
        grid_infos = files_collection.find(filename: {"$in" => part_uids}).to_a
        grid_infos.sort_by! { |grid_info| part_uids.index(grid_info[:filename]) }

        validate_parts!(grid_infos, part_uids)

        length       = grid_infos.map { |doc| doc[:length] }.reduce(0, :+)
        content_type = Tus::Info.new(info).metadata["content_type"]

        grid_file = create_grid_file(
          filename:     uid,
          length:       length,
          content_type: content_type,
        )

        # Update the chunks belonging to parts so that they point to the new file.
        grid_infos.inject(0) do |offset, grid_info|
          result = chunks_collection
            .find(files_id: grid_info[:_id])
            .update_many("$set" => {files_id: grid_file.id}, "$inc" => {n: offset})

          offset += result.modified_count
        end

        # Delete the parts after concatenation.
        files_collection.delete_many(filename: {"$in" => part_uids})

        # Tus server requires us to return the size of the concatenated file.
        length
      end

      def patch_file(uid, input, info = {})
        grid_info = find_grid_info!(uid)

        patch_last_chunk(input, grid_info)

        grid_chunks = split_into_grid_chunks(input, grid_info)
        chunks_collection.insert_many(grid_chunks)
        grid_chunks.each { |grid_chunk| grid_chunk.data.data.clear } # deallocate strings

        # Update the total length and refresh the upload date on each update,
        # which are used in #get_file, #concatenate and #expire_files.
        files_collection.find(filename: uid).update_one("$set" => {
          length:     grid_info[:length] + input.size,
          uploadDate: Time.now.utc,
        })
      end

      def read_info(uid)
        grid_info = find_grid_info!(uid)

        grid_info[:metadata]
      end

      def update_info(uid, info)
        grid_info = find_grid_info!(uid)

        files_collection.update_one({filename: uid}, {"$set" => {metadata: info}})
      end

      def get_file(uid, info = {}, range: nil)
        grid_info = find_grid_info!(uid)

        length = range ? range.size : grid_info[:length]

        filter = { files_id: grid_info[:_id] }

        if range
          chunk_start = range.begin / grid_info[:chunkSize]
          chunk_stop  = range.end   / grid_info[:chunkSize]

          filter[:n] = {"$gte" => chunk_start, "$lte" => chunk_stop}
        end

        # Query only the subset of chunks specified by the range query. We
        # cannot use Mongo::FsBucket#open_download_stream here because it
        # doesn't support changing the filter.
        chunks_view = chunks_collection.find(filter).sort(n: 1)

        # Create an Enumerator which will yield chunks of the requested file
        # content, allowing tus server to efficiently stream requested content
        # to the client.
        chunks = Enumerator.new do |yielder|
          chunks_view.each do |document|
            data = document[:data].data

            if document[:n] == chunk_start && document[:n] == chunk_stop
              byte_start = range.begin % grid_info[:chunkSize]
              byte_stop  = range.end   % grid_info[:chunkSize]
            elsif document[:n] == chunk_start
              byte_start = range.begin % grid_info[:chunkSize]
              byte_stop  = grid_info[:chunkSize] - 1
            elsif document[:n] == chunk_stop
              byte_start = 0
              byte_stop  = range.end % grid_info[:chunkSize]
            end

            # If we're on the first or last chunk, return a subset of the chunk
            # specified by the given range, otherwise return the full chunk.
            if byte_start && byte_stop
              yielder << data[byte_start..byte_stop]
            else
              yielder << data
            end
          end
        end

        # We return a response object that responds to #each, #length and #close,
        # which the tus server can return directly as the Rack response.
        Response.new(chunks: chunks, length: length, close: ->{chunks_view.close_query})
      end

      def delete_file(uid, info = {})
        grid_info = files_collection.find(filename: uid).first
        bucket.delete(grid_info[:_id]) if grid_info
      end

      def expire_files(expiration_date)
        grid_infos = files_collection.find(uploadDate: {"$lte" => expiration_date}).to_a
        grid_info_ids = grid_infos.map { |info| info[:_id] }

        files_collection.delete_many(_id: {"$in" => grid_info_ids})
        chunks_collection.delete_many(files_id: {"$in" => grid_info_ids})
      end

      private

      def create_grid_file(**options)
        file_options = {metadata: {}, chunk_size: chunk_size}.merge(options)
        grid_file = Mongo::Grid::File.new("", file_options)

        bucket.insert_one(grid_file)

        grid_file
      end

      def split_into_grid_chunks(io, grid_info)
        grid_info[:md5] = Digest::MD5.new # hack for `Chunk.split` updating MD5
        grid_info = Mongo::Grid::File::Info.new(Mongo::Options::Mapper.transform(grid_info, Mongo::Grid::File::Info::MAPPINGS.invert))
        offset = chunks_collection.count(files_id: grid_info.id)

        Mongo::Grid::File::Chunk.split(io, grid_info, offset)
      end

      def patch_last_chunk(input, grid_info)
        if grid_info[:length] % grid_info[:chunkSize] != 0
          last_chunk = chunks_collection.find(files_id: grid_info[:_id]).sort(n: -1).limit(1).first
          data = last_chunk[:data].data
          data << input.read(grid_info[:chunkSize] - data.length)

          chunks_collection.find(files_id: grid_info[:_id], n: last_chunk[:n])
            .update_one("$set" => {data: BSON::Binary.new(data)})

          data.clear # deallocate string
        end
      end

      def find_grid_info!(uid)
        files_collection.find(filename: uid).first or raise Tus::NotFound
      end

      def validate_parts!(grid_infos, part_uids)
        validate_parts_presence!(grid_infos, part_uids)
        validate_parts_full_chunks!(grid_infos)
      end

      def validate_parts_presence!(grid_infos, part_uids)
        if grid_infos.count != part_uids.count
          raise Tus::Error, "some parts for concatenation are missing"
        end
      end

      def validate_parts_full_chunks!(grid_infos)
        grid_infos.each do |grid_info|
          if grid_info[:length] % grid_info[:chunkSize] != 0 && grid_info != grid_infos.last
            raise Tus::Error, "cannot concatenate parts which aren't evenly distributed across chunks"
          end
        end
      end

      def files_collection
        bucket.files_collection
      end

      def chunks_collection
        bucket.chunks_collection
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
