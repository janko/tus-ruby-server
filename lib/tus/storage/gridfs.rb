require "tus/info"
require "mongo"
require "digest"

module Tus
  module Storage
    class Gridfs
      attr_reader :client, :prefix, :bucket, :chunk_size

      def initialize(client:, prefix: "fs", chunk_size: nil)
        @client = client
        @prefix = prefix
        @bucket = @client.database.fs(bucket_name: @prefix)
        @bucket.send(:ensure_indexes!)
        @chunk_size = chunk_size
      end

      def create_file(uid, info = {})
        file = Mongo::Grid::File.new("", filename: uid, metadata: info, chunk_size: chunk_size)
        bucket.insert_one(file)
      end

      def concatenate(uid, part_uids, info = {})
        file_infos = bucket.files_collection.find(filename: {"$in" => part_uids}).to_a
        file_infos.sort_by! { |file_info| part_uids.index(file_info[:filename]) }

        if file_infos.count != part_uids.count
          raise Tus::Error, "some parts for concatenation are missing"
        end

        chunk_sizes = file_infos.map { |file_info| file_info[:chunkSize] }
        if chunk_sizes[0..-2].uniq.count > 1
          raise Tus::Error, "some parts have different chunk sizes, so they cannot be concatenated"
        end

        if chunk_sizes.uniq != [chunk_sizes.last] && bucket.chunks_collection.find(files_id: file_infos.last[:_id]).count > 1
          raise Tus::Error, "last part has different chunk size and is composed of more than one chunk"
        end

        length     = file_infos.inject(0) { |sum, file_info| sum + file_info[:length] }
        chunk_size = file_infos.first[:chunkSize]

        info["Upload-Length"] = info["Upload-Offset"] = length.to_s

        file = Mongo::Grid::File.new("", filename: uid, metadata: info, chunk_size: chunk_size, length: length)
        bucket.insert_one(file)

        file_infos.inject(0) do |offset, file_info|
          result = bucket.chunks_collection
            .find(files_id: file_info[:_id])
            .update_many("$set" => {files_id: file.id}, "$inc" => {n: offset})

          offset += result.modified_count
        end

        bucket.files_collection.delete_many(filename: {"$in" => part_uids})
      end

      def patch_file(uid, io)
        file_info = bucket.files_collection.find(filename: uid).first
        raise Tus::NotFound if file_info.nil?

        file_info[:md5] = Digest::MD5.new # hack for `Chunk.split` updating MD5
        file_info[:chunkSize] ||= io.size
        file_info = Mongo::Grid::File::Info.new(Mongo::Options::Mapper.transform(file_info, Mongo::Grid::File::Info::MAPPINGS.invert))

        tus_info = Tus::Info.new(file_info.metadata)

        unless io.size % file_info.chunk_size == 0 ||        # content fits into chunks
               tus_info.length.nil? ||                       # unknown length
               file_info.length + io.size == tus_info.length # last chunk

          raise Tus::Error,
            "Input has length #{io.size} but expected it to be a multiple of" \
            "chunk size #{file_info.chunk_size} or for it to be the last chunk"
        end

        offset = bucket.chunks_collection.find(files_id: file_info.id).count
        chunks = Mongo::Grid::File::Chunk.split(io, file_info, offset)

        bucket.chunks_collection.insert_many(chunks)
        chunks.each { |chunk| chunk.data.data.clear } # deallocate strings

        bucket.files_collection.find(filename: uid).update_one("$set" => {
          length:     file_info.length + io.size,
          uploadDate: Time.now.utc,
          chunkSize:  file_info.chunk_size,
        })
      end

      def read_info(uid)
        file_info = bucket.files_collection.find(filename: uid).first
        raise Tus::NotFound if file_info.nil?

        file_info.fetch("metadata")
      end

      def update_info(uid, info)
        bucket.files_collection.find(filename: uid)
          .update_one("$set" => {metadata: info})
      end

      def get_file(uid, range: nil)
        file_info = bucket.files_collection.find(filename: uid).first
        raise Tus::NotFound if file_info.nil?

        filter = {files_id: file_info[:_id]}

        if range
          chunk_start = range.begin / file_info[:chunkSize] if range.begin
          chunk_stop  = range.end   / file_info[:chunkSize] if range.end

          filter[:n] = {}
          filter[:n].update("$gte" => chunk_start) if chunk_start
          filter[:n].update("$lte" => chunk_stop) if chunk_stop
        end

        chunks_view = bucket.chunks_collection.find(filter).read(bucket.read_preference).sort(n: 1)

        chunks = Enumerator.new do |yielder|
          chunks_view.each do |document|
            data = document[:data].data

            if document[:n] == chunk_start && document[:n] == chunk_stop
              byte_start = range.begin % file_info[:chunkSize]
              byte_stop  = range.end   % file_info[:chunkSize]
            elsif document[:n] == chunk_start
              byte_start = range.begin % file_info[:chunkSize]
              byte_stop  = file_info[:chunkSize] - 1
            elsif document[:n] == chunk_stop
              byte_start = 0
              byte_stop  = range.end % file_info[:chunkSize]
            end

            if byte_start && byte_stop
              partial_data = data[byte_start..byte_stop]
              yielder << partial_data
              partial_data.clear # deallocate chunk string
            else
              yielder << data
            end

            data.clear # deallocate chunk string
          end
        end

        Response.new(chunks: chunks, close: ->{chunks_view.close_query})
      end

      def delete_file(uid)
        file_info = bucket.files_collection.find(filename: uid).first
        bucket.delete(file_info.fetch("_id")) if file_info
      end

      def expire_files(expiration_date)
        file_infos = bucket.files_collection.find(uploadDate: {"$lte" => expiration_date}).to_a
        file_info_ids = file_infos.map { |info| info[:_id] }

        bucket.files_collection.delete_many(_id: {"$in" => file_info_ids})
        bucket.chunks_collection.delete_many(files_id: {"$in" => file_info_ids})
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
