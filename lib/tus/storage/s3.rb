# frozen-string-literal: true

gem "aws-sdk-s3", "~> 1.2"

require "aws-sdk-s3"

require "tus/info"
require "tus/response"
require "tus/errors"

require "json"
require "cgi"

module Tus
  module Storage
    class S3
      MIN_PART_SIZE = 5 * 1024 * 1024 # 5MB is the minimum part size for S3 multipart uploads

      attr_reader :client, :bucket, :prefix, :upload_options, :concurrency

      # Initializes an aws-sdk-s3 client with the given credentials.
      def initialize(bucket:, prefix: nil, upload_options: {}, concurrency: {}, thread_count: nil, **client_options)
        fail ArgumentError, "the :bucket option was nil" unless bucket

        if thread_count
          warn "[Tus-Ruby-Server] :thread_count is deprecated and will be removed in the next major version, use :concurrency instead, e.g `concurrency: { concatenation: 20 }`"
          concurrency[:concatenation] = thread_count
        end

        resource = Aws::S3::Resource.new(**client_options)

        @client         = resource.client
        @bucket         = resource.bucket(bucket)
        @prefix         = prefix
        @upload_options = upload_options
        @concurrency    = concurrency
      end

      # Initiates multipart upload for the given upload, and stores its
      # information inside the info hash.
      def create_file(uid, info = {})
        tus_info = Tus::Info.new(info)

        options = upload_options.dup
        options[:content_type] = tus_info.metadata["content_type"]

        if filename = tus_info.metadata["filename"]
          # Aws-sdk-s3 doesn't sign non-ASCII characters correctly, and browsers
          # will automatically URI-decode filenames.
          filename = CGI.escape(filename).gsub("+", " ")

          options[:content_disposition] ||= "inline"
          options[:content_disposition]  += "; filename=\"#{filename}\""
        end

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

        # Tus server requires us to return the size of the concatenated file.
        object = client.head_object(bucket: bucket.name, key: object(uid).key)
        object.content_length
      rescue => error
        multipart_upload.abort if multipart_upload
        raise error
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

        jobs = []
        chunk = input.read(MIN_PART_SIZE)

        while chunk
          next_chunk = input.read(MIN_PART_SIZE)

          # merge next chunk into previous if it's smaller than minimum chunk size
          if next_chunk && next_chunk.bytesize < MIN_PART_SIZE
            chunk << next_chunk
            next_chunk.clear
            next_chunk = nil
          end

          # abort if chunk is smaller than 5MB and is not the last chunk
          if chunk.bytesize < MIN_PART_SIZE
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
          .select { |multipart_upload|
            last_modified = multipart_upload.parts.map(&:last_modified).max
            last_modified.nil? || last_modified <= expiration_date
          }
          .each(&:abort)
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

      def delete(objects)
        # S3 can delete maximum of 1000 objects in a single request
        objects.each_slice(1000) do |objects_batch|
          delete_params = { objects: objects_batch.map { |object| { key: object.key } } }
          bucket.delete_objects(delete: delete_params)
        end
      end

      # Creates multipart parts for the specified multipart upload by copying
      # given objects into them. It uses a queue and a fixed-size thread pool
      # which consumes that queue.
      def copy_parts(objects, multipart_upload)
        parts   = compute_parts(objects, multipart_upload)
        input   = Queue.new
        results = Queue.new

        parts.each { |part| input << part }
        input.close

        thread_count = concurrency[:concatenation] || 10
        threads = thread_count.times.map { copy_part_thread(input, results) }

        errors = threads.map(&:value).compact
        fail errors.first if errors.any?

        part_results = Array.new(results.size) { results.pop } # convert Queue into an Array
        part_results.sort_by { |part| part.fetch("part_number") }
      end

      # Computes data required for copying objects into new multipart parts.
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

      # Consumes the queue for new multipart part information and issues the
      # copy requests.
      def copy_part_thread(input, results)
        Thread.new do
          begin
            loop do
              part = input.pop or break
              part_result = copy_part(part)
              results << part_result
            end
            nil
          rescue => error
            input.clear # clear other work
            error
          end
        end
      end

      # Creates a new multipart part by copying the object specified in the
      # given data. Returns part number and ETag that will be required later
      # for completing the multipart upload.
      def copy_part(part)
        response = client.upload_part_copy(part)

        { "part_number" => part[:part_number], "etag" => response.copy_part_result.etag }
      end

      # Retuns an Aws::S3::Object with the prefix applied.
      def object(key)
        bucket.object([*prefix, key].join("/"))
      end
    end
  end
end
