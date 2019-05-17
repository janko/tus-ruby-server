# frozen-string-literal: true

gem "aws-sdk-s3", "~> 1.2"

require "aws-sdk-s3"
require "content_disposition"

require "tus/info"
require "tus/response"
require "tus/errors"

require "json"
require "cgi"

module Tus
  module Storage
    class S3
      # AWS S3 multipart upload limits
      MIN_PART_SIZE       = 5 * 1024 * 1024
      MAX_PART_SIZE       = 5 * 1024 * 1024 * 1024
      MAX_MULTIPART_PARTS = 10_000
      MAX_OBJECT_SIZE     = 5 * 1024 * 1024 * 1024 * 1024

      attr_reader :bucket, :prefix, :upload_options, :limits

      # Initializes an aws-sdk-s3 client with the given credentials.
      def initialize(bucket:, prefix: nil, upload_options: {}, limits: {}, concurrency: {}, thread_count: nil, **client_options)
        fail ArgumentError, "the :bucket option was nil" unless bucket

        if thread_count
          warn "[Tus-Ruby-Server] :thread_count option is obsolete and will be removed in the next major version"
        elsif concurrency.any?
          warn "[Tus-Ruby-Server] :concurrency option is obsolete and will be removed in the next major version"
        end

        @bucket         = Aws::S3::Bucket.new(name: bucket, **client_options)
        @prefix         = prefix
        @upload_options = upload_options
        @limits         = limits
      end

      # Initiates multipart upload for the given upload, and stores its
      # information inside the info hash.
      def create_file(uid, info = {})
        tus_info = Tus::Info.new(info)

        if tus_info.length && tus_info.length > max_object_size
          fail Tus::Error, "upload length exceeds maximum S3 object size"
        end

        options = {}
        options[:content_type] = tus_info.type if tus_info.type
        options[:content_disposition] = ContentDisposition.inline(tus_info.name) if tus_info.name
        options.merge!(upload_options)

        multipart_upload = object(uid).initiate_multipart_upload(options)

        info["multipart_id"]    = multipart_upload.id
        info["multipart_parts"] = []

        multipart_upload
      end

      # Concatenates multiple partial uploads into a single upload, and returns
      # the size of the resulting upload. The partial uploads are deleted after
      # concatenation.
      #
      # Internally it creates a new multipart upload, copies objects of the
      # given partial uploads into multipart parts, and finalizes the multipart
      # upload.
      #
      # The multipart upload is automatically aborted in case of an exception.
      def concatenate(uid, part_uids, info = {})
        multipart_upload = create_file(uid, info)

        objects = part_uids.map { |part_uid| object(part_uid) }
        parts   = copy_parts(objects, multipart_upload)

        info["multipart_parts"].concat parts

        finalize_file(uid, info)

        delete(part_uids.flat_map { |part_uid| [object(part_uid), object("#{part_uid}.info")] })
      rescue
        multipart_upload&.abort
        raise
      end

      # Appends data to the specified upload in a streaming fashion, and returns
      # the number of bytes it managed to save.
      #
      # The data read from the input is first buffered in memory, and once 5MB
      # (AWS S3's mininum allowed size for a multipart part) or more data has
      # been retrieved, it starts being uploaded in a background thread as the
      # next multipart part. This allows us to start reading the next chunk of
      # input data and soon as possible, achieving streaming.
      #
      # If any network error is raised during the upload to S3, the upload of
      # further input data stops and the number of bytes that manged to get
      # uploaded is returned.
      def patch_file(uid, input, info = {})
        tus_info = Tus::Info.new(info)

        upload_id      = info["multipart_id"]
        part_offset    = info["multipart_parts"].count
        bytes_uploaded = 0

        part_size = calculate_part_size(tus_info.length)

        chunk = input.read(part_size)

        while chunk
          next_chunk = input.read(part_size)

          # merge next chunk into previous if it's smaller than minimum chunk size
          if next_chunk && next_chunk.bytesize < part_size
            chunk << next_chunk
            next_chunk.clear
            next_chunk = nil
          end

          # abort if chunk is smaller than part size and is not the last chunk
          if chunk.bytesize < part_size
            break if (tus_info.length && tus_info.offset) &&
                     chunk.bytesize + tus_info.offset < tus_info.length
          end

          begin
            part = upload_part(chunk, uid, upload_id, part_offset += 1)
            info["multipart_parts"] << part
            bytes_uploaded += chunk.bytesize
          rescue Seahorse::Client::NetworkingError => exception
            warn "ERROR: #{exception.inspect} occurred during upload"
            break # ignore networking errors and return what client has uploaded so far
          end

          chunk.clear
          chunk = next_chunk
        end

        bytes_uploaded
      end

      # Completes the multipart upload using the part information saved in the
      # info hash.
      def finalize_file(uid, info = {})
        upload_id = info["multipart_id"]
        parts = info["multipart_parts"].map do |part|
          { part_number: part["part_number"], etag: part["etag"] }
        end

        multipart_upload = object(uid).multipart_upload(upload_id)
        multipart_upload.complete(multipart_upload: { parts: parts })

        info.delete("multipart_id")
        info.delete("multipart_parts")
      end

      # Returns info of the specified upload. Raises Tus::NotFound if the upload
      # wasn't found.
      def read_info(uid)
        response = object("#{uid}.info").get
        JSON.parse(response.body.string)
      rescue Aws::S3::Errors::NoSuchKey
        raise Tus::NotFound
      end

      # Updates info of the specified upload.
      def update_info(uid, info)
        object("#{uid}.info").put(body: info.to_json)
      end

      # Returns a Tus::Response object through which data of the specified
      # upload can be retrieved in a streaming fashion. Accepts an optional
      # range parameter for selecting a subset of bytes to retrieve.
      def get_file(uid, info = {}, range: nil)
        range  = "bytes=#{range.begin}-#{range.end}" if range
        chunks = object(uid).enum_for(:get, range: range)

        Tus::Response.new(chunks: chunks)
      end

      # Returns a signed expiring URL to the S3 object.
      def file_url(uid, info = {}, content_type: nil, content_disposition: nil, **options)
        options[:response_content_type]        ||= content_type
        options[:response_content_disposition] ||= content_disposition

        object(uid).presigned_url(:get, **options)
      end

      # Deletes resources for the specified upload. If multipart upload is
      # still in progress, aborts the multipart upload, otherwise deletes the
      # object.
      def delete_file(uid, info = {})
        if info["multipart_id"]
          multipart_upload = object(uid).multipart_upload(info["multipart_id"])
          multipart_upload.abort

          delete [object("#{uid}.info")]
        else
          delete [object(uid), object("#{uid}.info")]
        end
      end

      # Deletes resources of uploads older than the specified date. For
      # multipart uploads still in progress, it checks the upload date of the
      # last multipart part.
      def expire_files(expiration_date)
        delete bucket.objects(prefix: @prefix)
          .select { |object| object.last_modified <= expiration_date }

        bucket.multipart_uploads
          .select { |multipart_upload| multipart_upload.key.start_with?(prefix.to_s) }
          .select { |multipart_upload| multipart_upload.initiated <= expiration_date }
          .select { |multipart_upload| multipart_upload.parts.all?{|p| p.last_modified <= expiration_date} }
          .each(&:abort)
      end

      def client
        bucket.client
      end

      private

      # Uploads given body as a new multipart part with the specified part
      # number to the specified multipart upload. Returns part number and ETag
      # that will be required later for completing the multipart upload.
      def upload_part(body, key, upload_id, part_number)
        multipart_upload = object(key).multipart_upload(upload_id)
        multipart_part   = multipart_upload.part(part_number)

        response = multipart_part.upload(body: body)

        { "part_number" => part_number, "etag" => response.etag }
      end

      # Calculates minimum multipart part size required to upload the whole
      # file, taking into account AWS S3 multipart limits on part size and
      # number of parts.
      def calculate_part_size(length)
        return min_part_size if length.nil?
        return length        if length <= min_part_size
        return min_part_size if length <= min_part_size * max_multipart_parts

        part_size = Rational(length, max_multipart_parts).ceil

        if part_size > max_part_size
          fail Tus::Error, "chunk size for upload exceeds maximum part size"
        end

        part_size
      end

      def delete(objects)
        # S3 can delete maximum of 1000 objects in a single request
        objects.each_slice(1000) do |objects_batch|
          delete_params = { objects: objects_batch.map { |object| { key: object.key } } }
          bucket.delete_objects(delete: delete_params)
        end
      end

      # Creates multipart parts for the specified multipart upload by copying
      # given objects into them.
      def copy_parts(objects, multipart_upload)
        threads = objects.map.with_index do |object, idx|
          Thread.new { copy_part(object, idx + 1, multipart_upload) }
        end

        threads.map(&:value)
      end

      # Creates a new multipart part by copying the object specified in the
      # given data. Returns part number and ETag that will be required later
      # for completing the multipart upload.
      def copy_part(object, part_number, multipart_upload)
        response = client.upload_part_copy(
          bucket:      multipart_upload.bucket_name,
          key:         multipart_upload.object_key,
          upload_id:   multipart_upload.id,
          copy_source: [object.bucket_name, object.key].join("/"),
          part_number: part_number,
        )

        { "part_number" => part_number, "etag" => response.copy_part_result.etag }
      end

      # Retuns an Aws::S3::Object with the prefix applied.
      def object(key)
        bucket.object([*prefix, key].join("/"))
      end

      def min_part_size;       limits.fetch(:min_part_size,       MIN_PART_SIZE);       end
      def max_part_size;       limits.fetch(:max_part_size,       MAX_PART_SIZE);       end
      def max_multipart_parts; limits.fetch(:max_multipart_parts, MAX_MULTIPART_PARTS); end
      def max_object_size;     limits.fetch(:max_object_size,     MAX_OBJECT_SIZE);     end
    end
  end
end
