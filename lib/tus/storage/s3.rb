require "aws-sdk"

require "tus/info"
require "tus/checksum"
require "tus/errors"

require "json"
require "cgi/util"

Aws.eager_autoload!(services: ["S3"])

module Tus
  module Storage
    class S3
      MIN_PART_SIZE = 5 * 1024 * 1024

      attr_reader :client, :bucket, :prefix, :upload_options

      def initialize(bucket:, prefix: nil, upload_options: {}, thread_count: 10, **client_options)
        resource = Aws::S3::Resource.new(**client_options)

        @client         = resource.client
        @bucket         = resource.bucket(bucket)
        @prefix         = prefix
        @upload_options = upload_options
        @thread_count   = thread_count
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

        multipart_upload
      end

      def concatenate(uid, part_uids, info = {})
        multipart_upload = create_file(uid, info)

        objects = part_uids.map { |part_uid| object(part_uid) }
        parts   = copy_parts(objects, multipart_upload)

        parts.each do |part|
          info["multipart_parts"] << { "part_number" => part[:part_number], "etag" => part[:etag] }
        end

        finalize_file(uid, info)

        delete(part_uids.flat_map { |part_uid| [object(part_uid), object("#{part_uid}.info")] })

        # Tus server requires us to return the size of the concatenated file.
        object = client.head_object(bucket: bucket.name, key: object(uid).key)
        object.content_length
      rescue => error
        abort_multipart_upload(multipart_upload) if multipart_upload
        raise error
      end

      def patch_file(uid, input, info = {})
        upload_id   = info["multipart_id"]
        part_number = info["multipart_parts"].count + 1

        multipart_upload = object(uid).multipart_upload(upload_id)
        multipart_part   = multipart_upload.part(part_number)
        md5              = Tus::Checksum.new("md5").generate(input)

        response = multipart_part.upload(body: input, content_md5: md5)

        info["multipart_parts"] << {
          "part_number" => part_number,
          "etag"        => response.etag[/"(.+)"/, 1],
        }
      rescue Aws::S3::Errors::NoSuchUpload
        raise Tus::NotFound
      end

      def finalize_file(uid, info = {})
        upload_id = info["multipart_id"]
        parts = info["multipart_parts"].map do |part|
          { part_number: part["part_number"], etag: part["etag"] }
        end

        multipart_upload = object(uid).multipart_upload(upload_id)
        multipart_upload.complete(multipart_upload: {parts: parts})

        info.delete("multipart_id")
        info.delete("multipart_parts")
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
        object = object(uid)
        range  = "bytes=#{range.begin}-#{range.end}" if range

        raw_chunks = Enumerator.new do |yielder|
          object.get(range: range) do |chunk|
            yielder << chunk
            chunk.clear # deallocate string
          end
        end

        # Start the request to be notified if the object doesn't exist, and to
        # get Aws::S3::Object#content_length.
        first_chunk = raw_chunks.next

        chunks = Enumerator.new do |yielder|
          yielder << first_chunk
          loop { yielder << raw_chunks.next }
        end

        Response.new(
          chunks: chunks,
          length: object.content_length,
        )
      rescue Aws::S3::Errors::NoSuchKey
        raise Tus::NotFound
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

      def copy_parts(objects, multipart_upload)
        parts = compute_parts(objects, multipart_upload)
        queue = parts.inject(Queue.new) { |queue, part| queue << part }

        threads = @thread_count.times.map { copy_part_thread(queue) }

        threads.flat_map(&:value).sort_by { |part| part[:part_number] }
      end

      def compute_parts(objects, multipart_upload)
        objects.map.with_index do |object, idx|
          {
            bucket:      multipart_upload.bucket_name,
            key:         multipart_upload.object_key,
            upload_id:   multipart_upload.id,
            copy_source: [object.bucket_name, object.key].join("/"),
            part_number: idx + 1,
          }
        end
      end

      def copy_part_thread(queue)
        Thread.new do
          Thread.current.abort_on_exception = true
          begin
            results = []
            loop do
              part = queue.deq(true) rescue break
              results << copy_part(part)
            end
            results
          rescue => error
            queue.clear
            raise error
          end
        end
      end

      def copy_part(part)
        response = client.upload_part_copy(part)

        { part_number: part[:part_number], etag: response.copy_part_result.etag }
      end

      def object(key)
        bucket.object([*prefix, key].join("/"))
      end

      class Response
        def initialize(chunks:, length:)
          @chunks = chunks
          @length = length
        end

        def length
          @length
        end

        def each(&block)
          @chunks.each(&block)
        end

        def close
          # aws-sdk doesn't provide an API to terminate the HTTP connection
        end
      end
    end
  end
end
