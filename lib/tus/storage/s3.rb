require "aws-sdk"

require "tus/info"
require "tus/checksum"
require "tus/errors"

require "json"
require "cgi/util"

module Tus
  module Storage
    class S3
      MIN_PART_SIZE = 5 * 1024 * 1024

      attr_reader :client, :bucket, :prefix, :upload_options

      def initialize(bucket:, prefix: nil, upload_options: {}, **client_options)
        resource = Aws::S3::Resource.new(**client_options)

        @client = resource.client
        @bucket = resource.bucket(bucket)
        @prefix = prefix
        @upload_options = upload_options
      end

      def create_file(uid, info = {})
        tus_info = Tus::Info.new(info)

        options = upload_options.dup
        options[:content_type] = tus_info.metadata["content_type"]

        if filename = tus_info.metadata["filename"]
          options[:content_disposition] ||= "inline"
          options[:content_disposition]  += "; filename=\"#{CGI.escape(filename).gsub("+", " ")}\""
        end

        multipart_upload = object(uid).initiate_multipart_upload(options)

        info["multipart_id"]    = multipart_upload.id
        info["multipart_parts"] = []
      end

      def concatenate(uid, part_uids, info = {})
        create_file(uid, info)

        multipart_upload = object(uid).multipart_upload(info["multipart_id"])

        queue = Queue.new
        part_uids.each_with_index do |part_uid, idx|
          queue << {
            copy_source: [bucket.name, object(part_uid).key].join("/"),
            part_number: idx + 1
          }
        end

        threads = 10.times.map do
          Thread.new do
            Thread.current.abort_on_exception = true
            completed = []

            begin
              loop do
                multipart_copy_task = queue.deq(true) rescue break

                part_number = multipart_copy_task[:part_number]
                copy_source = multipart_copy_task[:copy_source]

                part = multipart_upload.part(part_number)
                response = part.copy_from(copy_source: copy_source)

                completed << {
                  part_number: part_number,
                  etag: response.copy_part_result.etag,
                }
              end

              completed
            rescue
              queue.clear
              raise
            end
          end
        end

        parts = threads.flat_map(&:value).sort_by { |part| part[:part_number] }

        multipart_upload.complete(multipart_upload: {parts: parts})

        delete(part_uids.flat_map { |part_uid| [object(part_uid), object("#{part_uid}.info")] })

        info.delete("multipart_id")
        info.delete("multipart_parts")
      rescue
        abort_multipart_upload(multipart_upload) if multipart_upload
        raise
      end

      def patch_file(uid, io, info = {})
        raise Tus::Error, "Chunk size cannot be smaller than 5MB" if io.size < MIN_PART_SIZE

        upload_id   = info["multipart_id"]
        part_number = info["multipart_parts"].count + 1

        multipart_upload = object(uid).multipart_upload(upload_id)
        multipart_part   = multipart_upload.part(part_number)
        md5              = Tus::Checksum.new("md5").generate(io)

        begin
          response = multipart_part.upload(body: io, content_md5: md5)
        rescue Aws::S3::Errors::NoSuchUpload
          raise Tus::NotFound
        end

        info["multipart_parts"] << {
          "part_number" => part_number,
          "etag"        => response.etag[/"(.+)"/, 1],
        }

        tus_info = Tus::Info.new(info)

        # finalize the multipart upload if this chunk was the last part
        if tus_info.length && tus_info.offset + io.size == tus_info.length
          multipart_upload.complete(
            multipart_upload: {
              parts: info["multipart_parts"].map do |part|
                {part_number: part["part_number"], etag: part["etag"]}
              end
            }
          )

          info.delete("multipart_id")
          info.delete("multipart_parts")
        end
      end

      def read_info(uid)
        response = object("#{uid}.info").get
        JSON.parse(response.body.string)
      rescue Aws::S3::Errors::NoSuchKey
        raise Tus::NotFound
      end

      def update_info(uid, info)
        object("#{uid}.info").put(body: info.to_json)
      end

      def get_file(uid, info = {}, range: nil)
        if range
          range = "bytes=#{range.begin}-#{range.end}"
        end

        raw_chunks = Enumerator.new do |yielder|
          object(uid).get(range: range) do |chunk|
            yielder << chunk
            chunk.clear # deallocate string
          end
        end

        begin
          first_chunk = raw_chunks.next
        rescue Aws::S3::Errors::NoSuchKey
          raise Tus::NotFound
        end

        chunks = Enumerator.new do |yielder|
          yielder << first_chunk
          loop { yielder << raw_chunks.next }
        end

        Response.new(chunks: chunks)
      end

      def delete_file(uid, info = {})
        if info["multipart_id"]
          multipart_upload = object(uid).multipart_upload(info["multipart_id"])
          abort_multipart_upload(multipart_upload)

          delete [object("#{uid}.info")]
        else
          delete [object(uid), object("#{uid}.info")]
        end
      end

      def expire_files(expiration_date)
        old_objects = bucket.objects.select do |object|
          object.last_modified <= expiration_date
        end

        delete(old_objects)

        bucket.multipart_uploads.each do |multipart_upload|
          next unless multipart_upload.initiated <= expiration_date
          most_recent_part = multipart_upload.parts.sort_by(&:last_modified).last
          if most_recent_part.nil? || most_recent_part.last_modified <= expiration_date
            abort_multipart_upload(multipart_upload)
          end
        end
      end

      private

      def delete(objects)
        # S3 can delete maximum of 1000 objects in a single request
        objects.each_slice(1000) do |objects_batch|
          delete_params = {objects: objects_batch.map { |object| {key: object.key} }}
          bucket.delete_objects(delete: delete_params)
        end
      end

      # In order to ensure the multipart upload was successfully aborted,
      # we need to check whether all parts have been deleted, and retry
      # the abort if the list is nonempty.
      def abort_multipart_upload(multipart_upload)
        loop do
          multipart_upload.abort
          break unless multipart_upload.parts.any?
        end
      rescue Aws::S3::Errors::NoSuchUpload
        # multipart upload was successfully aborted or doesn't exist
      end

      def object(key)
        bucket.object([*prefix, key].join("/"))
      end

      class Response
        def initialize(chunks:)
          @chunks = chunks
        end

        def each(&block)
          @chunks.each(&block)
        end
      end
    end
  end
end
