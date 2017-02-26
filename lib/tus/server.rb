require "roda"

require "tus/storage/filesystem"
require "tus/info"
require "tus/expirator"
require "tus/checksum"

require "securerandom"
require "time"

module Tus
  class Server < Roda
    SUPPORTED_VERSIONS = ["1.0.0"]
    SUPPORTED_EXTENSIONS = [
      "creation", "creation-defer-length",
      "termination",
      "expiration",
      "concatenation", "concatenation-unfinished",
      "checksum",
    ]
    SUPPORTED_CHECKSUM_ALGORITHMS = %w[sha1 sha256 sha384 sha512 md5 crc32]
    RESUMABLE_CONTENT_TYPE = "application/offset+octet-stream"

    opts[:max_size]            = 1024*1024*1024
    opts[:expiration_time]     = 7*24*60*60
    opts[:expiration_interval] = 60*60

    plugin :all_verbs
    plugin :delete_empty_headers
    plugin :request_headers
    plugin :not_allowed

    route do |r|
      expire_files

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

          uid = SecureRandom.hex
          info = Info.new(
            "Upload-Length"       => request.headers["Upload-Length"],
            "Upload-Offset"       => "0",
            "Upload-Defer-Length" => request.headers["Upload-Defer-Length"],
            "Upload-Metadata"     => request.headers["Upload-Metadata"],
            "Upload-Concat"       => request.headers["Upload-Concat"],
            "Upload-Expires"      => (Time.now + expiration_time).httpdate,
          )

          storage.create_file(uid, info.to_h)

          if info.final_upload?
            length = info.partial_uploads.inject(0) do |length, partial_uid|
              content = storage.read_file(partial_uid)
              storage.patch_file(uid, content)
              storage.delete_file(partial_uid)
              length += content.length
            end

            info["Upload-Length"] = length.to_s
            info["Upload-Offset"] = length.to_s

            storage.update_info(uid, info.to_h)
          end

          response.headers.update(info.to_h)

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

        r.delete do
          storage.delete_file(uid)

          no_content!
        end

        not_found! unless storage.file_exists?(uid)

        r.get do
          path = storage.download_file(uid)
          info = Info.new(storage.read_info(uid))

          server = Rack::File.new(File.dirname(path))

          result = if ::Rack.release > "2"
                     server.serving(request, path)
                   else
                     server = server.dup
                     server.path = path
                     server.serving(env)
                   end

          response.status = result[0]
          response.headers.update(result[1])

          metadata = info.metadata
          response.headers["Content-Disposition"] = "attachment; filename=\"#{metadata["filename"]}\"" if metadata["filename"]
          response.headers["Content-Type"] = metadata["content_type"] if metadata["content_type"]

          request.halt response.finish_with_body(result[2])
        end

        r.head do
          info = storage.read_info(uid)

          response.headers.update(info.to_h)
          response.headers["Cache-Control"] = "no-store"

          no_content!
        end

        r.patch do
          validate_content_type!

          content = request.body.read
          request.body.rewind
          info = Info.new(storage.read_info(uid))

          if info.defer_length?
            validate_upload_length!
            info["Upload-Length"] = request.headers["Upload-Length"]
            info["Upload-Defer-Length"] = nil
          end

          validate_content_length!(info.remaining_length)
          validate_upload_offset!(info.offset)
          validate_upload_checksum! if request.headers["Upload-Checksum"]

          storage.patch_file(uid, content)

          info["Upload-Offset"] = (info.offset + content.length).to_s
          info["Upload-Expires"] = (Time.now + expiration_time).httpdate

          storage.update_info(uid, info.to_h)
          response.headers.update(info.to_h)

          no_content!
        end
      end
    end

    def expire_files
      expirator = Expirator.new(storage, interval: expiration_interval)
      expirator.expire_files!
    end

    def validate_content_type!
      content_type = request.headers["Content-Type"]
      error!(415, "Invalid Content-Type header") if content_type != RESUMABLE_CONTENT_TYPE
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

    def validate_upload_offset!(current_offset)
      upload_offset = request.headers["Upload-Offset"]

      error!(400, "Missing Upload-Offset header") if upload_offset.to_s == ""
      error!(400, "Invalid Upload-Offset header") if upload_offset =~ /\D/
      error!(400, "Invalid Upload-Offset header") if upload_offset.to_i < 0

      if upload_offset.to_i != current_offset
        error!(409, "Upload-Offset header doesn't match current offset")
      end
    end

    def validate_content_length!(remaining_length)
      error!(403, "Cannot modify completed upload") if remaining_length == 0
      error!(413, "Size of this chunk surpasses Upload-Length") if Integer(request.content_length) > remaining_length
    end

    def validate_upload_metadata!
      upload_metadata = request.headers["Upload-Metadata"]

      upload_metadata.split(",").each do |string|
        key, value = string.split(" ")

        error!(400, "Invalid Upload-Metadata header") if key.nil? || value.nil?
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

    def validate_upload_checksum!
      algorithm, checksum = request.headers["Upload-Checksum"].split(" ")

      error!(400, "Invalid Upload-Checksum header") if algorithm.nil? || checksum.nil?
      error!(400, "Invalid Upload-Checksum header") unless SUPPORTED_CHECKSUM_ALGORITHMS.include?(algorithm)

      unless Checksum.new(algorithm).match?(checksum, request.body)
        error!(460, "Checksum from Upload-Checksum header doesn't match generated")
      end
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

    def not_found!(message = "Upload not found")
      error!(404, message)
    end

    def error!(status, message)
      response.status = status
      response.write(message) unless request.head?
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
