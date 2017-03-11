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

      def file_exists?(uid)
        !!bucket.files_collection.find(filename: uid).first
      end

      def read_file(uid)
        file = bucket.find_one(filename: uid)
        file.data
      end

      def patch_file(uid, io)
        file_info = bucket.files_collection.find(filename: uid).first
        file_info[:md5] = Digest::MD5.new # hack for `Chunk.split` updating MD5
        file_info[:chunkSize] ||= io.size
        file_info = Mongo::Grid::File::Info.new(Mongo::Options::Mapper.transform(file_info, Mongo::Grid::File::Info::MAPPINGS.invert))

        tus_info = Tus::Info.new(file_info.metadata)

        unless io.size % file_info.chunk_size == 0 ||        # IO fits into chunks
               tus_info.length.nil? ||                       # Unknown length
               file_info.length + io.size == tus_info.length # Last chunk

          raise "Input has length #{io.size} but expected it to be a multiple of" \
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

      def get_file(uid, range: nil)
        file_info = bucket.files_collection.find(filename: uid).first

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

      def read_info(uid)
        info = bucket.files_collection.find(filename: uid).first
        info.fetch("metadata")
      end

      def update_info(uid, info)
        bucket.files_collection.find(filename: uid).update_one("$set" => {metadata: info})
      end

      def list_files
        infos = bucket.files_collection.find.to_a
        infos.map { |info| info.fetch("filename") }
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
