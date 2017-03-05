require "mongo"

require "tempfile"
require "digest"

module Tus
  module Storage
    class Gridfs
      attr_reader :client, :prefix, :bucket, :chunk_size

      def initialize(client:, prefix: "fs", chunk_size: 256*1024)
        @client = client
        @prefix = prefix
        @bucket = @client.database.fs(bucket_name: @prefix)
        @bucket.send(:ensure_indexes!)
        @chunk_size = chunk_size
      end

      def create_file(uid, metadata = {})
        file = Mongo::Grid::File.new("", filename: uid, metadata: metadata, chunk_size: chunk_size)
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
        file_info[:md5] = Digest::MD5.new
        file_info = Mongo::Grid::File::Info.new(Mongo::Options::Mapper.transform(file_info, Mongo::Grid::File::Info::MAPPINGS.invert))

        offset = bucket.chunks_collection.find(files_id: file_info.id).count
        chunks = Mongo::Grid::File::Chunk.split(io, file_info, offset)

        bucket.chunks_collection.insert_many(chunks)
        chunks.each { |chunk| chunk.data.data.clear } # deallocate strings

        bucket.files_collection.find(filename: uid).update_one("$set" => {
          length:     file_info.length + io.size,
          uploadDate: Time.now.utc,
        })
      end

      def download_file(uid)
        tempfile = Tempfile.new("tus", binmode: true)
        tempfile.sync = true
        bucket.download_to_stream_by_name(uid, tempfile)
        tempfile.path
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

      private

      def bson_id(uid)
        BSON::ObjectId(uid)
      end
    end
  end
end
