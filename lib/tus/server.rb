require "roda"

require "tus/metadata"
require "tus/storage/filesystem"

require "securerandom"
require "tmpdir"

module Tus
  class Server < Roda
    SUPPORTED_VERSIONS     = ["1.0.0"]
    SUPPORTED_EXTENSIONS   = ["creation", "termination"]
    RESUMABLE_CONTENT_TYPE = "application/offset+octet-stream"

    opts[:base_path] = "files"
    opts[:storage]   = Tus::Storage::Filesystem.new(Dir.tmpdir)
    opts[:max_size]  = 1024*1024*1024

    plugin :all_verbs
    plugin :slash_path_empty
    plugin :delete_empty_headers
    plugin :request_headers
    plugin :default_headers, "Content-Type" => ""
    plugin :module_include
    plugin :middleware

    route do |r|
      r.on base_path do
        r.get ":uid" do |uid|
          not_found! unless storage.file_exists?(uid)

          path = storage.download_file(uid)
          info = storage.read_info(uid)

          file = Rack::File.new(File.dirname(path))

          result = file.serving(request, path)

          response.status = result[0]
          response.headers.update(result[1])

          metadata = info["Upload-Metadata"] || {}
          response.headers["Content-Disposition"] = "attachment; filename=\"#{metadata["filename"]}\"" if metadata["filename"]
          response.headers["Content-Type"] = metadata["content_type"] if metadata["content_type"]

          request.halt response.finish_with_body(result[2])
        end

        response.headers.update(
          "Tus-Resumable" => SUPPORTED_VERSIONS.first,
          "Tus-Version"   => SUPPORTED_VERSIONS.join(","),
          "Tus-Extension" => SUPPORTED_EXTENSIONS.join(","),
          "Tus-Max-Size"  => max_size.to_s,
        )

        handle_cors!

        r.is do
          r.options do
            no_content!
          end

          validate_tus_resumable!

          r.post do
            validate_upload_length!

            uid = SecureRandom.hex
            info = {
              "Upload-Length"   => request.headers["Upload-Length"].to_i,
              "Upload-Offset"   => 0,
              "Upload-Metadata" => Metadata.parse(request.headers["Upload-Metadata"].to_s),
            }

            storage.create_file(uid, info)
            file_url = "/#{base_path}/#{uid}"

            created!(file_url)
          end
        end

        r.is ":uid" do |uid|
          not_found! unless storage.file_exists?(uid)

          r.options do
            no_content!
          end

          validate_tus_resumable!

          r.head do
            info = storage.read_info(uid)

            response.headers.update(
              "Upload-Length"   => info["Upload-Length"].to_s,
              "Upload-Offset"   => info["Upload-Offset"].to_s,
              "Upload-Metadata" => Metadata.serialize(info["Upload-Metadata"]),
            )

            response.headers["Cache-Control"] = "no-store"

            no_content!
          end

          r.patch do
            validate_content_type!

            content = request.body.read
            info = storage.read_info(uid)

            validate_upload_offset!(info["Upload-Offset"])
            validate_content_length!(content, info["Upload-Length"] - info["Upload-Offset"])

            storage.patch_file(uid, content)

            info["Upload-Offset"] = info["Upload-Offset"] + content.length
            storage.update_info(uid, info)

            response.headers["Upload-Offset"] = info["Upload-Offset"].to_s

            no_content!
          end

          r.delete do
            storage.delete_file(uid)

            no_content!
          end
        end
      end
    end

    def validate_content_type!
      content_type = request.headers["Content-Type"]
      error!(415, "Invalid Content-Type header") if content_type != RESUMABLE_CONTENT_TYPE
    end

    def validate_tus_resumable!
      client_version = request.headers["Tus-Resumable"]
      error!(412, "Unsupported version") unless SUPPORTED_VERSIONS.include?(client_version)
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

    def validate_content_length!(content, remaining_length)
      if content.length > remaining_length
        error!(413, "Size of this chunk surpasses Upload-Length")
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
      response.headers["Content-Length"] = ""
    end

    def created!(location)
      response.status = 201
      response.headers["Location"] = location
    end

    def not_found!(message = "Upload not found")
      error!(404, message)
    end

    def error!(status, message)
      response.status = status
      response.write(message)
      request.halt
    end

    def base_path
      opts[:base_path]
    end

    def storage
      opts[:storage]
    end

    def max_size
      opts[:max_size]
    end
  end
end
