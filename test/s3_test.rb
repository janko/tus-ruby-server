require "test_helper"
require "tus/storage/s3"
require "content_disposition"

require "base64"
require "stringio"

describe Tus::Storage::S3 do
  before do
    @storage = s3
  end

  def s3(**options)
    Tus::Storage::S3.new(
      stub_responses: true,
      bucket: "my-bucket",
      **options
    )
  end

  describe "#initialize" do
    it "accepts credentials" do
      storage = s3(
        access_key_id:     "abc",
        secret_access_key: "xyz",
        region:            "eu-west-1",
        bucket:            "tus",
      )

      assert_equal "abc",       storage.client.config.access_key_id
      assert_equal "xyz",       storage.client.config.secret_access_key
      assert_equal "eu-west-1", storage.client.config.region
      assert_equal "tus",       storage.bucket.name
    end

    it "raises explanatory error when :bucket was nil" do
      error = assert_raises(ArgumentError) { s3(bucket: nil) }

      assert_equal "the :bucket option was nil", error.message
    end
  end

  describe "#create_file" do
    it "creates a multipart upload with uid as the key" do
      @storage.client.stub_responses(:create_multipart_upload, { upload_id: "upload_id" })

      @storage.create_file("uid", info = {})

      assert_equal 1, @storage.client.api_requests.count

      assert_equal :create_multipart_upload, @storage.client.api_requests[0][:operation_name]
      assert_equal "uid",                    @storage.client.api_requests[0][:params][:key]

      assert_equal "upload_id", info["multipart_id"]
      assert_equal [],          info["multipart_parts"]
    end

    it "assigns content type from metadata" do
      @storage.create_file("uid", { "Upload-Metadata" => "type #{Base64.encode64("text/plain")}" })

      assert_equal :create_multipart_upload, @storage.client.api_requests[0][:operation_name]
      assert_equal "text/plain",             @storage.client.api_requests[0][:params][:content_type]
    end

    it "assigns content disposition from metadata" do
      @storage.create_file("uid", { "Upload-Metadata" => "name #{Base64.encode64("file.txt")}" })

      assert_equal :create_multipart_upload,              @storage.client.api_requests[0][:operation_name]
      assert_equal ContentDisposition.inline("file.txt"), @storage.client.api_requests[0][:params][:content_disposition]
    end

    it "applies :upload_options" do
      @storage = s3(upload_options: {
        content_type:        "foo/bar",
        content_disposition: "attachment",
      })

      @storage.create_file("uid", { "Upload-Metadata" => [
        "type #{Base64.encode64("text/plain")}",
        "name #{Base64.encode64("file.txt")}",
      ].join(",") })

      assert_equal :create_multipart_upload, @storage.client.api_requests[0][:operation_name]
      assert_equal "foo/bar",                @storage.client.api_requests[0][:params][:content_type]
      assert_equal "attachment",             @storage.client.api_requests[0][:params][:content_disposition]
    end
  end

  describe "#patch_file" do
    before do
      @info = { "multipart_id" => "upload_id", "multipart_parts" => [] }
    end

    it "uploads the input as a multipart part" do
      @storage.client.stub_responses(:upload_part, { etag: "etag" })

      assert_equal 7, @storage.patch_file("uid", StringIO.new("content"), @info)

      assert_equal 1, @storage.client.api_requests.count

      assert_equal :upload_part, @storage.client.api_requests[0][:operation_name]
      assert_equal "upload_id",  @storage.client.api_requests[0][:params][:upload_id]
      assert_equal "uid",        @storage.client.api_requests[0][:params][:key]
      assert_equal 1,            @storage.client.api_requests[0][:params][:part_number]
      assert_equal "7",          @storage.client.api_requests[0][:context].http_request.headers["Content-Length"]

      assert_equal [{"part_number" => 1, "etag" => "etag"}], @info["multipart_parts"]
    end

    it "uses the correct part number" do
      @storage.client.stub_responses(:upload_part, [
        { etag: "etag1" },
        { etag: "etag2" },
        { etag: "etag3" },
      ])

      assert_equal 7, @storage.patch_file("uid", StringIO.new("content"), @info)
      assert_equal 7, @storage.patch_file("uid", StringIO.new("content"), @info)
      assert_equal 7, @storage.patch_file("uid", StringIO.new("content"), @info)

      assert_equal 3, @storage.client.api_requests.count

      assert_equal :upload_part, @storage.client.api_requests[0][:operation_name]
      assert_equal 1,            @storage.client.api_requests[0][:params][:part_number]

      assert_equal :upload_part, @storage.client.api_requests[1][:operation_name]
      assert_equal 2,            @storage.client.api_requests[1][:params][:part_number]

      assert_equal :upload_part, @storage.client.api_requests[2][:operation_name]
      assert_equal 3,            @storage.client.api_requests[2][:params][:part_number]

      assert_equal [{ "part_number" => 1, "etag" => "etag1" },
                    { "part_number" => 2, "etag" => "etag2" },
                    { "part_number" => 3, "etag" => "etag3" }], @info["multipart_parts"]
    end

    it "uploads in batches of 5MB" do
      input = StringIO.new("a" * (10*1024*1024))

      @storage.client.stub_responses(:upload_part, [
        { etag: "etag1" },
        { etag: "etag2" },
      ])

      assert_equal 10 * 1024 * 1024, @storage.patch_file("uid", input, @info)

      assert_equal 2, @storage.client.api_requests.count

      assert_equal :upload_part,       @storage.client.api_requests[0][:operation_name]
      assert_equal 1,                  @storage.client.api_requests[0][:params][:part_number]
      assert_equal (5*1024*1024).to_s, @storage.client.api_requests[0][:context].http_request.headers["Content-Length"]

      assert_equal :upload_part,       @storage.client.api_requests[1][:operation_name]
      assert_equal 2,                  @storage.client.api_requests[1][:params][:part_number]
      assert_equal (5*1024*1024).to_s, @storage.client.api_requests[1][:context].http_request.headers["Content-Length"]

      assert_equal [{ "part_number" => 1, "etag" => "etag1" },
                    { "part_number" => 2, "etag" => "etag2" }], @info["multipart_parts"]
    end

    it "merges last chunk into previous if it's smaller than minimum allowed" do
      input = StringIO.new("a" * (10*1024*1024 + 1))

      @storage.client.stub_responses(:upload_part, [
        { etag: "etag1" },
        { etag: "etag2" },
      ])

      assert_equal 10*1024*1024 + 1, @storage.patch_file("uid", input, @info)

      assert_equal 2, @storage.client.api_requests.count

      assert_equal :upload_part,       @storage.client.api_requests[0][:operation_name]
      assert_equal 1,                  @storage.client.api_requests[0][:params][:part_number]
      assert_equal (5*1024*1024).to_s, @storage.client.api_requests[0][:context].http_request.headers["Content-Length"]

      assert_equal :upload_part,           @storage.client.api_requests[1][:operation_name]
      assert_equal 2,                      @storage.client.api_requests[1][:params][:part_number]
      assert_equal (5*1024*1024 + 1).to_s, @storage.client.api_requests[1][:context].http_request.headers["Content-Length"]

      assert_equal [{ "part_number" => 1, "etag" => "etag1" },
                    { "part_number" => 2, "etag" => "etag2" }], @info["multipart_parts"]
    end

    it "doesn't accept chunk smaller than 5MB if it's not the last chunk" do
      input = StringIO.new("a" * (4*1024*1024))

      @info.merge!(
        "Upload-Offset" => 0.to_s,
        "Upload-Length" => (10*1024*1024).to_s,
      )

      assert_equal 0, @storage.patch_file("uid", input, @info)

      assert_equal 0, @storage.client.api_requests.count

      assert_equal [], @info["multipart_parts"]
    end

    it "accepts chunk smaller than 5MB if it's the last chunk" do
      input = StringIO.new("a" * (4*1024*1024))

      @info.merge!(
        "Upload-Offset" => (6*1024*1024).to_s,
        "Upload-Length" => (10*1024*1024).to_s,
      )

      @storage.client.stub_responses(:upload_part, { etag: "etag" })

      assert_equal 4 * 1024 * 1024, @storage.patch_file("uid", input, @info)

      assert_equal 1, @storage.client.api_requests.count

      assert_equal :upload_part,       @storage.client.api_requests[0][:operation_name]
      assert_equal 1,                  @storage.client.api_requests[0][:params][:part_number]
      assert_equal (4*1024*1024).to_s, @storage.client.api_requests[0][:context].http_request.headers["Content-Length"]

      assert_equal [{"part_number" => 1, "etag" => "etag"}], @info["multipart_parts"]
    end

    it "works for non-rewindable inputs" do
      read_pipe, write_pipe = IO.pipe

      write_pipe.write "content"
      write_pipe.close

      @storage.client.stub_responses(:upload_part, { etag: "etag" })

      assert_equal 7, @storage.patch_file("uid", read_pipe, @info)

      assert_equal 1, @storage.client.api_requests.count

      assert_equal :upload_part, @storage.client.api_requests[0][:operation_name]
      assert_equal 1,            @storage.client.api_requests[0][:params][:part_number]
      assert_equal "7",          @storage.client.api_requests[0][:context].http_request.headers["Content-Length"]

      assert_equal [{"part_number" => 1, "etag" => "etag"}], @info["multipart_parts"]
    end

    it "recovers from network errors" do
      input = StringIO.new("a" * (10*1024*1024))

      @storage.client.stub_responses(:upload_part, [
        { etag: "etag1" },
        Seahorse::Client::NetworkingError.new(Timeout::Error.new("timed out")),
      ])

      capture_io do # silence warnings
        assert_equal 5 * 1024 * 1024, @storage.patch_file("uid", input, @info)
      end

      assert_equal 2, @storage.client.api_requests.count

      assert_equal [{"part_number" => 1, "etag" => "etag1"}], @info["multipart_parts"]
    end
  end

  describe "#finalize_file" do
    before do
      @info = { "multipart_id" => "upload_id", "multipart_parts" => [] }
    end

    it "completes the multipart upload" do
      @storage.client.stub_responses(:upload_part, [
        { etag: "etag1" },
        { etag: "etag2" },
      ])

      @storage.patch_file("uid", StringIO.new("content"), @info)
      @storage.patch_file("uid", StringIO.new("content"), @info)
      @storage.finalize_file("uid", @info)

      assert_equal 3, @storage.client.api_requests.count

      assert_equal :complete_multipart_upload, @storage.client.api_requests[2][:operation_name]
      assert_equal "uid",                      @storage.client.api_requests[2][:params][:key]
      assert_equal "upload_id",                @storage.client.api_requests[2][:params][:upload_id]
      assert_equal Hash[
        parts: [
          { part_number: 1, etag: "etag1" },
          { part_number: 2, etag: "etag2" },
        ]
      ], @storage.client.api_requests[2][:params][:multipart_upload]

      refute @info.key?("multipart_id")
      refute @info.key?("multipart_parts")
    end
  end

  describe "#concatenate" do
    it "copies parts into a new multipart upload and deletes the source parts" do
      @storage.client.stub_responses(:create_multipart_upload, { upload_id: "upload_id" })
      @storage.client.stub_responses(:upload_part_copy, -> (context) {
        { copy_part_result: { etag: "etag#{context.params[:part_number]}" } }
      })
      @storage.client.stub_responses(:head_object, { content_length: 10 })

      assert_equal 10, @storage.concatenate("uid", ["part_uid1", "part_uid2"])

      assert_equal 6, @storage.client.api_requests.count

      assert_equal :create_multipart_upload, @storage.client.api_requests[0][:operation_name]
      assert_equal "uid",                    @storage.client.api_requests[0][:params][:key]

      # this is parallelized, so we don't know the order
      upload_part_copy_requests = @storage.client.api_requests[1..2]
        .sort_by { |request| request[:params][:part_number] }

      assert_equal :upload_part_copy,     upload_part_copy_requests[0][:operation_name]
      assert_equal "uid",                 upload_part_copy_requests[0][:params][:key]
      assert_equal "upload_id",           upload_part_copy_requests[0][:params][:upload_id]
      assert_equal 1,                     upload_part_copy_requests[0][:params][:part_number]
      assert_equal "my-bucket/part_uid1", upload_part_copy_requests[0][:params][:copy_source]

      assert_equal :upload_part_copy,     upload_part_copy_requests[1][:operation_name]
      assert_equal "uid",                 upload_part_copy_requests[1][:params][:key]
      assert_equal "upload_id",           upload_part_copy_requests[1][:params][:upload_id]
      assert_equal 2,                     upload_part_copy_requests[1][:params][:part_number]
      assert_equal "my-bucket/part_uid2", upload_part_copy_requests[1][:params][:copy_source]

      assert_equal :complete_multipart_upload, @storage.client.api_requests[3][:operation_name]
      assert_equal "uid",                      @storage.client.api_requests[3][:params][:key]
      assert_equal "upload_id",                @storage.client.api_requests[3][:params][:upload_id]
      assert_equal Hash[
        parts: [
          { part_number: 1, etag: "etag1" },
          { part_number: 2, etag: "etag2" },
        ]
      ], @storage.client.api_requests[3][:params][:multipart_upload]

      assert_equal :delete_objects, @storage.client.api_requests[4][:operation_name]
      assert_equal Hash[
        objects: [
          { key: "part_uid1" }, { key: "part_uid1.info" },
          { key: "part_uid2" }, { key: "part_uid2.info" },
        ]
      ], @storage.client.api_requests[4][:params][:delete]

      assert_equal :head_object, @storage.client.api_requests[5][:operation_name]
      assert_equal "uid",        @storage.client.api_requests[5][:params][:key]
      assert_equal "my-bucket",  @storage.client.api_requests[5][:params][:bucket]
    end

    it "aborts multipart upload on runtime errors" do
      Thread.report_on_exception = false if Thread.respond_to?(:report_on_exception=)

      @storage.client.stub_responses(:create_multipart_upload, { upload_id: "upload_id", key: "uid" })
      @storage.client.stub_responses(:upload_part_copy, ["TimeoutError"])
      assert_raises(Aws::S3::Errors::TimeoutError) { @storage.concatenate("uid", ["part_uid1", "part_uid2"], {}) }
      assert_equal :abort_multipart_upload, @storage.client.api_requests[-1][:operation_name]
      assert_equal "uid",                   @storage.client.api_requests[-1][:params][:key]
      assert_equal "upload_id",             @storage.client.api_requests[-1][:params][:upload_id]

      @storage.client.stub_responses(:create_multipart_upload, "TimeoutError")
      assert_raises(Aws::S3::Errors::TimeoutError) { @storage.concatenate("uid", ["part_uid1", "part_uid2"]) }

      Thread.report_on_exception = true if Thread.respond_to?(:report_on_exception=)
    end
  end

  describe "#read_info" do
    it "retrieves the info object content" do
      @storage.client.stub_responses(:get_object, {
        body: StringIO.new('{"Key":"Value"}'),
      })

      assert_equal Hash["Key" => "Value"], @storage.read_info("uid")

      assert_equal 1, @storage.client.api_requests.count

      assert_equal :get_object, @storage.client.api_requests[0][:operation_name]
      assert_equal "uid.info",  @storage.client.api_requests[0][:params][:key]
    end

    it "raises Tus::NotFound when object is missing" do
      @storage.client.stub_responses(:get_object, "NoSuchKey")

      assert_raises(Tus::NotFound) { @storage.read_info("uid") }
    end
  end

  describe "#update_info" do
    it "creates an object which stores info" do
      @storage.update_info("uid", { "Key" => "Value" })

      assert_equal 1, @storage.client.api_requests.count

      assert_equal :put_object,       @storage.client.api_requests[0][:operation_name]
      assert_equal "uid.info",        @storage.client.api_requests[0][:params][:key]
      assert_equal '{"Key":"Value"}', @storage.client.api_requests[0][:params][:body]
    end
  end

  describe "#get_file" do
    it "retrieves a response object which streams content" do
      @storage.client.stub_responses(:get_object, { body: "content" })

      response = @storage.get_file("uid")

      assert_equal ["content"], response.each.to_a
      response.close # responds to close

      assert_equal 1, @storage.client.api_requests.count

      assert_equal :get_object, @storage.client.api_requests[0][:operation_name]
      assert_equal "uid",       @storage.client.api_requests[0][:params][:key]
    end

    it "accepts byte ranges" do
      @storage.client.stub_responses(:get_object, { body: "nte" })

      response = @storage.get_file("uid", range: 2..4)

      assert_equal ["nte"], response.each.to_a

      assert_equal 1, @storage.client.api_requests.count

      assert_equal :get_object, @storage.client.api_requests[0][:operation_name]
      assert_equal "bytes=2-4", @storage.client.api_requests[0][:params][:range]
    end

    it "works for empty files" do
      @storage.client.stub_responses(:get_object, body: "")

      response = @storage.get_file("uid", { "Upload-Length" => 0 })

      assert_equal [], response.each.to_a
    end
  end

  describe "#file_url" do
    it "returns signed expiring URL to the object" do
      assert_match /X-Amz-Signature=/, @storage.file_url("uid")
    end

    it "accepts :content_type" do
      assert_match /response-content-type=text%2Fplain/, @storage.file_url("uid", content_type: "text/plain")
      assert_match /response-content-type=text%2Fother/, @storage.file_url("uid", content_type: "text/plain", response_content_type: "text/other")
    end

    it "accepts :content_disposition" do
      assert_match /response-content-disposition=attachment/, @storage.file_url("uid", content_disposition: "attachment")
      assert_match /response-content-disposition=inline/,     @storage.file_url("uid", content_disposition: "attachment", response_content_disposition: "inline")
    end

    it "accepts other AWS SDK options" do
      assert_match /response-cache-control=max-age%3D3600/, @storage.file_url("uid", response_cache_control: "max-age=3600")
    end
  end

  describe "#delete_file" do
    it "deletes multipart upload and info object if upload is not finished" do
      @storage.delete_file("uid", { "multipart_id" => "upload_id" })

      assert_equal 2, @storage.client.api_requests.count

      assert_equal :abort_multipart_upload, @storage.client.api_requests[0][:operation_name]
      assert_equal "upload_id",             @storage.client.api_requests[0][:params][:upload_id]
      assert_equal "uid",                   @storage.client.api_requests[0][:params][:key]

      assert_equal :delete_objects, @storage.client.api_requests[1][:operation_name]
      assert_equal Hash[
        objects: [{ key: "uid.info" }]
      ], @storage.client.api_requests[1][:params][:delete]
    end

    it "deletes content object and info object if upload is finished" do
      @storage.delete_file("uid")

      assert_equal 1, @storage.client.api_requests.count

      assert_equal :delete_objects, @storage.client.api_requests[0][:operation_name]
      assert_equal Hash[
        objects: [{ key: "uid" }, { key: "uid.info" }]
      ], @storage.client.api_requests[0][:params][:delete]
    end
  end

  describe "#expire_files" do
    before do
      @expiration_date = Time.now.utc
    end

    it "deletes objects that are past the expiration date" do
      @storage.client.stub_responses(:list_objects, contents: [
        { key: "uid1", last_modified: @expiration_date - 1 },
        { key: "uid2", last_modified: @expiration_date },
        { key: "uid3", last_modified: @expiration_date + 1 },
      ])

      @storage.expire_files(@expiration_date)

      assert_equal :delete_objects, @storage.client.api_requests[1][:operation_name]
      assert_equal Hash[
        objects: [{ key: "uid1" }, { key: "uid2" }]
      ], @storage.client.api_requests[1][:params][:delete]
    end

    it "deletes multipart uploads which are past the expiration date" do
      @storage.client.stub_responses(:list_multipart_uploads, uploads: [
        { upload_id: "upload_id1", key: "uid1", initiated: @expiration_date + 1 },
        { upload_id: "upload_id2", key: "uid2", initiated: @expiration_date },
        { upload_id: "upload_id3", key: "uid3", initiated: @expiration_date - 1},
        { upload_id: "upload_id4", key: "uid4", initiated: @expiration_date - 1},
      ])
      @storage.client.stub_responses(:list_parts, [
        { parts: [] },
        { parts: [{ part_number: 1, last_modified: @expiration_date - 1 }] },
        { parts: [{ part_number: 1, last_modified: @expiration_date - 1 },
                  { part_number: 2, last_modified: @expiration_date + 1 }] },
      ])

      @storage.expire_files(@expiration_date)

      assert_equal 7, @storage.client.api_requests.count

      assert_equal :list_objects,           @storage.client.api_requests[0][:operation_name]
      assert_equal :list_multipart_uploads, @storage.client.api_requests[1][:operation_name]

      assert_equal :list_parts,  @storage.client.api_requests[2][:operation_name]
      assert_equal "upload_id2", @storage.client.api_requests[2][:params][:upload_id]
      assert_equal "uid2",       @storage.client.api_requests[2][:params][:key]

      assert_equal :list_parts,  @storage.client.api_requests[3][:operation_name]
      assert_equal "upload_id3", @storage.client.api_requests[3][:params][:upload_id]
      assert_equal "uid3",       @storage.client.api_requests[3][:params][:key]

      assert_equal :list_parts,  @storage.client.api_requests[4][:operation_name]
      assert_equal "upload_id4", @storage.client.api_requests[4][:params][:upload_id]
      assert_equal "uid4",       @storage.client.api_requests[4][:params][:key]

      assert_equal :abort_multipart_upload, @storage.client.api_requests[5][:operation_name]
      assert_equal "upload_id2",            @storage.client.api_requests[5][:params][:upload_id]
      assert_equal "uid2",                  @storage.client.api_requests[5][:params][:key]

      assert_equal :abort_multipart_upload, @storage.client.api_requests[6][:operation_name]
      assert_equal "upload_id3",            @storage.client.api_requests[6][:params][:upload_id]
      assert_equal "uid3",                  @storage.client.api_requests[6][:params][:key]
    end

    it "takes :prefix into account" do
      @storage = s3(prefix: "prefix")
      @storage.client.stub_responses(:list_multipart_uploads, uploads: [
        { upload_id: "upload_id1", key: "prefix/uid1", initiated: @expiration_date },
        { upload_id: "upload_id2", key: "uid2",        initiated: @expiration_date },
      ])

      @storage.expire_files(@expiration_date)

      assert_equal 4, @storage.client.api_requests.count

      assert_equal :list_objects,           @storage.client.api_requests[0][:operation_name]
      assert_equal "prefix",                @storage.client.api_requests[0][:params][:prefix]

      assert_equal :list_multipart_uploads, @storage.client.api_requests[1][:operation_name]

      assert_equal :list_parts, @storage.client.api_requests[2][:operation_name]

      assert_equal :abort_multipart_upload, @storage.client.api_requests[3][:operation_name]
      assert_equal "upload_id1",            @storage.client.api_requests[3][:params][:upload_id]
      assert_equal "prefix/uid1",           @storage.client.api_requests[3][:params][:key]
    end
  end
end
