require "mongo"
require "stringio"
require "tempfile"

module Tus
  module Storage
    class Gridfs
      attr_reader :client, :prefix, :bucket

      def initialize(client:, prefix: "fs")
        @client = client
        @prefix = prefix
        @bucket = @client.database.fs(bucket_name: @prefix)
        @bucket.send(:ensure_indexes!)
      end

      def create_file(uid, metadata = {})
        file = Mongo::Grid::File.new("", filename: uid, metadata: metadata)
        bucket.insert_one(file)
      end

      def file_exists?(uid)
        !!bucket.files_collection.find(filename: uid).first
      end

      def read_file(uid)
        file = bucket.find_one(filename: uid)
        file.data
      end

      def patch_file(uid, content)
        file_info = bucket.files_collection.find(filename: uid).first
        file_info["md5"] = Digest::MD5.new # hack around not able to update digest
        file_info = Mongo::Grid::File::Info.new(file_info)
        offset = bucket.chunks_collection.find(files_id: file_info.id).count
        chunks = Mongo::Grid::File::Chunk.split(content, file_info, offset)
        bucket.chunks_collection.insert_many(chunks)
      end

      def download_file(uid)
        tempfile = Tempfile.new("tus", binmode: true)
        tempfile.sync = true
        bucket.download_to_stream_by_name(uid, tempfile)
        tempfile.path
      end

      def delete_file(uid)
        file_info = bucket.files_collection.find(filename: uid).first
        bucket.delete(file_info.fetch("_id"))
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
