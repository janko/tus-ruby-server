require "roda"

require "tus/storage/filesystem"
require "tus/info"
require "tus/input"
require "tus/checksum"
require "tus/errors"

require "securerandom"
require "time"

module Tus
  class Server < Roda
    SUPPORTED_VERSIONS = ["1.0.0"]
    SUPPORTED_EXTENSIONS = [
      "creation", "creation-defer-length",
      "termination",
      "expiration",
      "concatenation",
      "checksum",
    ]
    SUPPORTED_CHECKSUM_ALGORITHMS = %w[sha1 sha256 sha384 sha512 md5 crc32]
    RESUMABLE_CONTENT_TYPE = "application/offset+octet-stream"

    opts[:max_size]        = nil
    opts[:expiration_time] = 7*24*60*60
    opts[:disposition]     = "inline"

    plugin :all_verbs
    plugin :default_headers, {"Content-Type" => ""}
    plugin :delete_empty_headers
    plugin :request_headers
    plugin :not_allowed
    plugin :streaming

    route do |r|
      if request.headers["X-HTTP-Method-Override"]
        request.env["REQUEST_METHOD"] = request.headers["X-HTTP-Method-Override"]
      end

      response.headers.update(
        "Tus-Resumable" => SUPPORTED_VERSIONS.first,
      )

      handle_cors!
      validate_tus_resumable! unless request.options? || request.get?

      r.is ['', true] do
        r.options do
          response.headers.update(
            "Tus-Version"            => SUPPORTED_VERSIONS.join(","),
            "Tus-Extension"          => SUPPORTED_EXTENSIONS.join(","),
            "Tus-Max-Size"           => max_size.to_s,
            "Tus-Checksum-Algorithm" => SUPPORTED_CHECKSUM_ALGORITHMS.join(","),
          )

          no_content!
        end

        r.post do
          validate_upload_length! unless request.headers["Upload-Concat"].to_s.start_with?("final") || request.headers["Upload-Defer-Length"] == "1"
          validate_upload_metadata! if request.headers["Upload-Metadata"]
          validate_upload_concat! if request.headers["Upload-Concat"]

          uid  = SecureRandom.hex
          info = Tus::Info.new(
            "Upload-Length"       => request.headers["Upload-Length"],
            "Upload-Offset"       => "0",
            "Upload-Defer-Length" => request.headers["Upload-Defer-Length"],
            "Upload-Metadata"     => request.headers["Upload-Metadata"],
            "Upload-Concat"       => request.headers["Upload-Concat"],
            "Upload-Expires"      => (Time.now + expiration_time).httpdate,
          )

          if info.concatenation?
            validate_partial_uploads!(info.partial_uploads)

            length = storage.concatenate(uid, info.partial_uploads, info.to_h)
            info["Upload-Length"] = length.to_s
            info["Upload-Offset"] = length.to_s
          else
            storage.create_file(uid, info.to_h)
          end

          storage.update_info(uid, info.to_h)

          response.headers.update(info.headers)

          file_url = "#{request.url.chomp("/")}/#{uid}"
          created!(file_url)
        end
      end

      r.is ":uid" do |uid|
        r.options do
          response.headers.update(
            "Tus-Version"            => SUPPORTED_VERSIONS.join(","),
            "Tus-Extension"          => SUPPORTED_EXTENSIONS.join(","),
            "Tus-Max-Size"           => max_size.to_s,
            "Tus-Checksum-Algorithm" => SUPPORTED_CHECKSUM_ALGORITHMS.join(","),
          )

          no_content!
        end

        begin
          info = Tus::Info.new(storage.read_info(uid))
        rescue Tus::NotFound
          error!(404, "Upload Not Found")
        end

        r.head do
          response.headers.update(info.headers)
          response.headers["Cache-Control"] = "no-store"

          no_content!
        end

        r.patch do
          if info.defer_length? && request.headers["Upload-Length"]
            validate_upload_length!

            info["Upload-Length"]       = request.headers["Upload-Length"]
            info["Upload-Defer-Length"] = nil
          end

          input = get_input(info)

          validate_content_type!
          validate_upload_offset!(info)
          validate_content_length!(request.content_length.to_i, info) if request.content_length
          validate_upload_checksum!(input) if request.headers["Upload-Checksum"]

          begin
            bytes_uploaded = storage.patch_file(uid, input, info.to_h)
          rescue Tus::MaxSizeExceeded
            validate_content_length!(input.pos, info)
          end

          info["Upload-Offset"] = (info.offset + bytes_uploaded).to_s
          info["Upload-Expires"] = (Time.now + expiration_time).httpdate

          if info.offset == info.length # last chunk
            storage.finalize_file(uid, info.to_h) if storage.respond_to?(:finalize_file)
          end

          storage.update_info(uid, info.to_h)
          response.headers.update(info.headers)

          no_content!
        end

        r.get do
          validate_upload_finished!(info)
          range = handle_range_request!(info.length)

          response.headers["Content-Length"] = (range.end - range.begin + 1).to_s

          metadata = info.metadata
          response.headers["Content-Disposition"]  = opts[:disposition]
          response.headers["Content-Disposition"] += "; filename=\"#{metadata["filename"]}\"" if metadata["filename"]
          response.headers["Content-Type"] = metadata["content_type"] || "application/octet-stream"

          response = storage.get_file(uid, info.to_h, range: range)

          stream(callback: ->{response.close}) do |out|
            response.each { |chunk| out << chunk }
          end
        end

        r.delete do
          storage.delete_file(uid, info.to_h)

          no_content!
        end
      end
    end

    def get_input(info)
      offset = info.offset
      total  = info.length || max_size
      limit  = total - offset if total

      Tus::Input.new(request.body, limit: limit)
    end

    def validate_content_type!
      error!(415, "Invalid Content-Type header") if request.content_type != RESUMABLE_CONTENT_TYPE
    end

    def validate_tus_resumable!
      client_version = request.headers["Tus-Resumable"]

      unless SUPPORTED_VERSIONS.include?(client_version)
        response.headers["Tus-Version"] = SUPPORTED_VERSIONS.join(",")
        error!(412, "Unsupported version")
      end
    end

    def validate_upload_length!
      upload_length = request.headers["Upload-Length"]

      error!(400, "Missing Upload-Length header") if upload_length.to_s == ""
      error!(400, "Invalid Upload-Length header") if upload_length =~ /\D/
      error!(400, "Invalid Upload-Length header") if upload_length.to_i < 0

      if max_size && upload_length.to_i > max_size
        error!(413, "Upload-Length header too large")
      end
    end

    def validate_upload_offset!(info)
      upload_offset = request.headers["Upload-Offset"]

      error!(400, "Missing Upload-Offset header") if upload_offset.to_s == ""
      error!(400, "Invalid Upload-Offset header") if upload_offset =~ /\D/
      error!(400, "Invalid Upload-Offset header") if upload_offset.to_i < 0

      if upload_offset.to_i != info.offset
        error!(409, "Upload-Offset header doesn't match current offset")
      end
    end

    def validate_content_length!(size, info)
      if info.length
        error!(403, "Cannot modify completed upload") if info.offset == info.length
        error!(413, "Size of this chunk surpasses Upload-Length") if info.offset + size > info.length
      elsif max_size
        error!(413, "Size of this chunk surpasses Tus-Max-Size") if info.offset + size > max_size
      end
    end

    def validate_upload_finished!(info)
      error!(403, "Cannot download unfinished upload") unless info.length == info.offset
    end

    def validate_upload_metadata!
      upload_metadata = request.headers["Upload-Metadata"]

      upload_metadata.split(",").each do |string|
        key, value = string.split(" ")

        error!(400, "Invalid Upload-Metadata header") if key.nil?
        error!(400, "Invalid Upload-Metadata header") if key.ord > 127
        error!(400, "Invalid Upload-Metadata header") if key =~ /,| /

        error!(400, "Invalid Upload-Metadata header") if value =~ /[^a-zA-Z0-9+\/=]/
      end
    end

    def validate_upload_concat!
      upload_concat = request.headers["Upload-Concat"]

      error!(400, "Invalid Upload-Concat header") if upload_concat !~ /^(partial|final)/

      if upload_concat.start_with?("final")
        string = upload_concat.split(";").last
        string.split(" ").each do |url|
          error!(400, "Invalid Upload-Concat header") if url !~ %r{^#{request.script_name}/\w+$}
        end
      end
    end

    def validate_partial_uploads!(part_uids)
      queue = Queue.new
      part_uids.each { |part_uid| queue << part_uid }

      threads = 10.times.map do
        Thread.new do
          results = []
          loop do
            part_uid = queue.deq(true) rescue break
            part_info = storage.read_info(part_uid)
            results << part_info["Upload-Concat"]
          end
          results
        end
      end

      upload_concat_values = threads.flat_map(&:value)
      unless upload_concat_values.all? { |value| value == "partial" }
        error!(400, "One or more uploads were not partial")
      end
    rescue Tus::NotFound
      error!(404, "One or more partial uploads were not found")
    end

    def validate_upload_checksum!(input)
      algorithm, checksum = request.headers["Upload-Checksum"].split(" ")

      error!(400, "Invalid Upload-Checksum header") if algorithm.nil? || checksum.nil?
      error!(400, "Invalid Upload-Checksum header") unless SUPPORTED_CHECKSUM_ALGORITHMS.include?(algorithm)

      generated_checksum = Tus::Checksum.generate(algorithm, input)
      error!(460, "Upload-Checksum value doesn't match generated checksum") if generated_checksum != checksum
    end

    # "Range" header handling logic copied from Rack::File
    def handle_range_request!(length)
      if Rack.release >= "2.0"
        ranges = Rack::Utils.get_byte_ranges(request.headers["Range"], length)
      else
        ranges = Rack::Utils.byte_ranges(request.env, length)
      end

      if ranges.nil? || ranges.length > 1
        # No ranges, or multiple ranges (which we don't support):
        response.status = 200
        range = 0..length-1
      elsif ranges.empty?
        # Unsatisfiable. Return error, and file size:
        response.headers["Content-Range"] = "bytes */#{length}"
        error!(416, "Byte range unsatisfiable")
      else
        # Partial content:
        range = ranges[0]
        response.status = 206
        response.headers["Content-Range"] = "bytes #{range.begin}-#{range.end}/#{length}"
      end

      range
    end

    def handle_cors!
      origin = request.headers["Origin"]

      return if origin.to_s == ""

      response.headers["Access-Control-Allow-Origin"] = origin

      if request.options?
        response.headers["Access-Control-Allow-Methods"] = "POST, GET, HEAD, PATCH, DELETE, OPTIONS"
        response.headers["Access-Control-Allow-Headers"] = "Origin, X-Requested-With, Content-Type, Upload-Length, Upload-Offset, Tus-Resumable, Upload-Metadata"
        response.headers["Access-Control-Max-Age"]       = "86400"
      else
        response.headers["Access-Control-Expose-Headers"] = "Upload-Offset, Location, Upload-Length, Tus-Version, Tus-Resumable, Tus-Max-Size, Tus-Extension, Upload-Metadata"
      end
    end

    def no_content!
      response.status = 204
      request.halt
    end

    def created!(location)
      response.status = 201
      response.headers["Location"] = location
      request.halt
    end

    def error!(status, message)
      response.status = status
      response.write(message) unless request.head?
      response.headers["Content-Type"] = "text/plain"
      request.halt
    end

    def storage
      opts[:storage] || Tus::Storage::Filesystem.new("data")
    end

    def max_size
      opts[:max_size]
    end

    def expiration_time
      opts[:expiration_time]
    end

    def expiration_interval
      opts[:expiration_interval]
    end
  end
end
