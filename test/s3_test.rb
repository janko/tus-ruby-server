require "test_helper"
require "tus/storage/s3"

require "aws-sdk"

require "base64"
require "stringio"

describe Tus::Storage::S3 do
  before do
    @storage = s3
  end

  def s3(**options)
    options[:stub_responses] ||= true
    options[:bucket]         ||= "my-bucket"

    Tus::Storage::S3.new(options)
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
  end

  describe "#create_file" do
    it "creates a multipart upload with uid as the key" do
      @storage.client.stub_responses(:get_object, "NoSuchKey")
      @storage.client.stub_responses(:create_multipart_upload, -> (multipart_context) {
        @storage.client.stub_responses(:get_object, {})
        { upload_id: "upload_id" }
      })

      @storage.create_file("uid", info = {})

      @storage.bucket.object("uid").get
      assert_equal "upload_id", info["multipart_id"]
      assert_equal [],          info["multipart_parts"]
    end

    it "assigns content type from metadata" do
      @storage.client.stub_responses(:create_multipart_upload, -> (context) {
        @storage.client.stub_responses(:get_object, content_type: context.params[:content_type])
        { upload_id: "upload_id" }
      })

      @storage.create_file("uid", {"Upload-Metadata" => "content_type #{Base64.encode64("text/plain")}"})

      assert_equal "text/plain", @storage.bucket.object("uid").get.content_type
    end

    it "assigns content disposition from filename metadata" do
      @storage.client.stub_responses(:create_multipart_upload, -> (context) {
        @storage.client.stub_responses(:get_object, content_disposition: context.params[:content_disposition])
        { upload_id: "upload_id" }
      })

      @storage.create_file("uid", {"Upload-Metadata" => "filename #{Base64.encode64("file.txt")}"})

      assert_equal "inline; filename=\"file.txt\"", @storage.bucket.object("uid").get.content_disposition
    end

    it "escapes non-ASCII characters which aws-sdk cannot sign well" do
      @storage.client.stub_responses(:create_multipart_upload, -> (context) {
        @storage.client.stub_responses(:get_object, content_disposition: context.params[:content_disposition])
        { upload_id: "upload_id" }
      })

      @storage.create_file("uid", {"Upload-Metadata" => "filename #{Base64.encode64("ē .txt")}"})

      assert_equal "inline; filename=\"%C4%93 .txt\"", @storage.bucket.object("uid").get.content_disposition
    end

    it "works with content disposition in default upload options" do
      @storage = s3(upload_options: {content_disposition: "attachment"})

      @storage.client.stub_responses(:create_multipart_upload, -> (context) {
        @storage.client.stub_responses(:get_object, content_disposition: context.params[:content_disposition])
        { upload_id: "upload_id" }
      })
      @storage.create_file("uid")
      assert_equal "attachment", @storage.bucket.object("uid").get.content_disposition

      @storage.client.stub_responses(:create_multipart_upload, -> (context) {
        @storage.client.stub_responses(:get_object, content_disposition: context.params[:content_disposition])
        { upload_id: "upload_id" }
      })
      @storage.create_file("uid", {"Upload-Metadata" => "filename #{Base64.encode64("file.txt")}"})
      assert_equal "attachment; filename=\"file.txt\"", @storage.bucket.object("uid").get.content_disposition
    end
  end

  describe "#patch_file" do
    before do
      @storage.client.stub_responses(:create_multipart_upload, upload_id: "upload_id")
      @storage.client.stub_responses(:list_multipart_uploads, uploads: [{ upload_id: "upload_id", key: "uid" }])
      @storage.create_file("uid", @info = {})
    end

    it "uploads the input as a multipart part" do
      @storage.client.stub_responses(:upload_part, -> (context) {
        assert_equal "upload_id",                context.params[:upload_id]
        assert_equal "uid",                      context.params[:key]
        assert_equal 1,                          context.params[:part_number]
        assert_equal "mgNkuembtIDdJeHwKEyFVQ==", context.params[:content_md5]
        assert_equal "content",                  context.params[:body].read

        { etag: "etag" }
      })

      @storage.patch_file("uid", StringIO.new("content"), @info)

      assert_equal [{"part_number" => 1, "etag" => "etag"}], @info["multipart_parts"]
    end

    it "uses the correct part number" do
      @storage.client.stub_responses(:upload_part, -> (context) {
        { etag: "etag#{context.params[:part_number]}" }
      })

      @storage.patch_file("uid", StringIO.new("content"), @info)
      @storage.patch_file("uid", StringIO.new("content"), @info)
      @storage.patch_file("uid", StringIO.new("content"), @info)

      parts = [{ "part_number" => 1, "etag" => "etag1" },
               { "part_number" => 2, "etag" => "etag2" },
               { "part_number" => 3, "etag" => "etag3" }]

      assert_equal parts, @info["multipart_parts"]
    end

    it "raises Tus::NotFound when multipart upload is missing" do
      @storage.client.stub_responses(:upload_part, "NoSuchUpload")

      assert_raises(Tus::NotFound) do
        @storage.patch_file("uid", StringIO.new("content"), @info)
      end
    end
  end

  describe "#finalize_file" do
    before do
      @storage.client.stub_responses(:create_multipart_upload, upload_id: "upload_id")
      @storage.client.stub_responses(:list_multipart_uploads, uploads: [{ upload_id: "upload_id", key: "uid" }])
      @storage.create_file("uid", @info = {})
    end

    it "completes the multipart upload" do
      @storage.client.stub_responses(:upload_part, [
        { etag: "etag1" },
        { etag: "etag2" },
      ])
      @storage.client.stub_responses(:complete_multipart_upload, -> (context) {
        assert_equal "uid",       context.params[:key]
        assert_equal "upload_id", context.params[:upload_id]

        payload = { parts: [{ part_number: 1, etag: "etag1" },
                            { part_number: 2, etag: "etag2" }] }
        assert_equal payload, context.params[:multipart_upload]

        @storage.client.stub_responses(:list_multipart_uploads, uploads: [])

        {}
      })

      @storage.patch_file("uid", StringIO.new("content"), @info)
      @storage.patch_file("uid", StringIO.new("content"), @info)
      @storage.finalize_file("uid", @info)

      assert_equal [], @storage.bucket.multipart_uploads.to_a
      refute @info.key?("multipart_id")
      refute @info.key?("multipart_parts")
    end
  end

  describe "#concatenate" do
    it "copies parts into a new multipart upload" do
      @storage.client.stub_responses(:create_multipart_upload, -> (context) {
        assert_equal "uid", context.params[:key]
        { upload_id: "upload_id" }
      })
      @storage.client.stub_responses(:upload_part_copy, -> (context) {
        assert_equal "uid",                       context.params[:key]
        assert_equal "upload_id",                 context.params[:upload_id]
        assert_includes [1, 2],                   context.params[:part_number]
        assert_match %r{my-bucket/part_uid(1|2)}, context.params[:copy_source]

        { copy_part_result: { etag: "etag#{context.params[:part_number]}" } }
      })
      @storage.client.stub_responses(:complete_multipart_upload, -> (context) {
        assert_equal "uid",       context.params[:key]
        assert_equal "upload_id", context.params[:upload_id]

        payload = { parts: [{ part_number: 1, etag: "etag1" },
                            { part_number: 2, etag: "etag2" }] }

        assert_equal payload, context.params[:multipart_upload]
      })
      @storage.client.stub_responses(:head_object, -> (context) {
        assert_equal "uid", context.params[:key]
        { content_length: 10 }
      })

      content_length = @storage.concatenate("uid", ["part_uid1", "part_uid2"], {})

      assert_equal 10, content_length
    end

    it "propagates errors and aborts multipart upload" do
      @storage.client.stub_responses(:create_multipart_upload, "TimeoutError")
      assert_raises(Aws::S3::Errors::TimeoutError) { @storage.concatenate("uid", ["part_uid1", "part_uid2"], {}) }

      @storage.client.stub_responses(:create_multipart_upload, upload_id: "upload_id", key: "uid")
      @storage.client.stub_responses(:list_multipart_uploads, uploads: [{ upload_id: "upload_id", key: "uid" }])
      @storage.client.stub_responses(:upload_part_copy, ["TimeoutError", { copy_part_result: { etag: "etag" } }])
      @storage.client.stub_responses(:abort_multipart_upload, -> (context) {
        assert_equal "upload_id", context.params[:upload_id]
        assert_equal "uid",       context.params[:key]
        @storage.client.stub_responses(:list_multipart_uploads, uploads: [])
      })
      assert_raises(Aws::S3::Errors::TimeoutError) { @storage.concatenate("uid", ["part_uid1", "part_uid2"], {}) }
      assert_equal [], @storage.bucket.multipart_uploads.to_a
    end
  end

  describe "#read_info" do
    it "retrieves the info object content" do
      @storage.client.stub_responses(:get_object, -> (context) {
        assert_equal "uid.info", context.params[:key]
        { body: StringIO.new('{"Key":"Value"}') }
      })

      assert_equal Hash["Key" => "Value"], @storage.read_info("uid")
    end

    it "raises Tus::NotFound when object is missing" do
      @storage.client.stub_responses(:get_object, "NoSuchKey")

      assert_raises(Tus::NotFound) { @storage.read_info("uid") }
    end
  end

  describe "#update_info" do
    it "creates an object which stores info" do
      @storage.client.stub_responses(:put_object, -> (context) {
        assert_equal "uid.info", context.params[:key]
        @storage.client.stub_responses(:get_object, body: StringIO.new(context.params[:body]))
      })

      @storage.update_info("uid", {"Key" => "Value"})

      assert_equal '{"Key":"Value"}', @storage.bucket.object("uid.info").get.body.string
    end
  end

  describe "#get_file" do
    it "retrieves a response object" do
      @storage.client.stub_responses(:get_object, -> (context) {
        assert_equal "uid", context.params[:key]
        { body: "content" }
      })
      @storage.client.stub_responses(:head_object, -> (context) {
        assert_equal "uid", context.params[:key]
        { content_length: 7 }
      })

      response = @storage.get_file("uid")

      assert_equal 7,           response.length
      assert_equal ["content"], response.each.to_a
      response.close
    end

    it "accepts byte ranges" do
      @storage.client.stub_responses(:get_object, -> (context) {
        match = context.params.fetch(:range).match(/(\d+)-(\d+)/)
        from, to = match.values_at(1, 2).map(&:to_i)

        { body: "content"[from..to] }
      })
      @storage.client.stub_responses(:head_object, content_length: 3)

      response = @storage.get_file("uid", range: 2..4)

      assert_equal 3,       response.length
      assert_equal ["nte"], response.each.to_a
    end

    it "raises a Tus::NotFound error on missing object" do
      @storage.client.stub_responses(:get_object, "NoSuchKey")

      assert_raises(Tus::NotFound) { @storage.get_file("uid") }
    end
  end

  describe "#delete_file" do
    before do
      @storage.client.stub_responses(:create_multipart_upload, upload_id: "upload_id")
      @storage.client.stub_responses(:list_multipart_uploads, uploads: [{ upload_id: "upload_id", key: "uid" }])
      @storage.create_file("uid", @info = {})
    end

    it "deletes multipart upload and info object if upload is not finished" do
      @storage.client.stub_responses(:abort_multipart_upload, -> (context) {
        assert_equal "upload_id", context.params[:upload_id]
        assert_equal "uid",       context.params[:key]
        @storage.client.stub_responses(:list_multipart_uploads, [])
      })
      @storage.client.stub_responses(:delete_objects, -> (context) {
        assert_equal [{key: "uid.info"}], context.params[:delete][:objects]
        @storage.client.stub_responses(:get_object, "NoSuchKey")
      })

      @storage.delete_file("uid", @info)

      assert_equal [], @storage.bucket.multipart_uploads.to_a
      assert_raises(Aws::S3::Errors::NoSuchKey) { @storage.bucket.object("uid.info").get }
    end

    it "deletes content object and info object if upload is finished" do
      @storage.finalize_file("uid", @info)
      @storage.client.stub_responses(:delete_objects, -> (context) {
        assert_equal [{key: "uid"}, {key: "uid.info"}], context.params[:delete][:objects]
        @storage.client.stub_responses(:get_object, "NoSuchKey")
      })

      @storage.delete_file("uid", @info)

      assert_raises(Aws::S3::Errors::NoSuchKey) { @storage.bucket.object("uid").get }
      assert_raises(Aws::S3::Errors::NoSuchKey) { @storage.bucket.object("uid.info").get }
    end

    it "doesn't raise error when multipart upload doesn't exist" do
      @storage.client.stub_responses(:abort_multipart_upload, "NoSuchUpload")
      @storage.delete_file("uid")
    end
  end

  describe "#expire_files" do
    before do
      @expiration_date = Time.now.utc
    end

    it "delets objects that are past the expiration date" do
      @storage.client.stub_responses(:list_objects, contents: [
        { key: "uid1", last_modified: @expiration_date - 1 },
        { key: "uid2", last_modified: @expiration_date },
        { key: "uid3", last_modified: @expiration_date + 1 },
      ])
      @storage.client.stub_responses(:delete_objects, -> (context) {
        assert_equal [{key: "uid1"}, {key: "uid2"}], context.params[:delete][:objects]
        @storage.client.stub_responses(:get_object, "NoSuchKey")
      })

      @storage.expire_files(@expiration_date)

      assert_raises(Aws::S3::Errors::NoSuchKey) { @storage.bucket.object("uid1").get }
      assert_raises(Aws::S3::Errors::NoSuchKey) { @storage.bucket.object("uid2").get }
    end

    it "deletes multipart uploads which are past the expiration date" do
      @storage.client.stub_responses(:list_multipart_uploads, uploads: [
        { upload_id: "upload_id1", key: "uid1", initiated: @expiration_date + 1 },
        { upload_id: "upload_id2", key: "uid2", initiated: @expiration_date },
        { upload_id: "upload_id3", key: "uid3", initiated: @expiration_date - 1},
        { upload_id: "upload_id4", key: "uid4", initiated: @expiration_date - 1},
      ])
      deleted_multipart_uploads = []
      @storage.client.stub_responses(:list_parts, -> (context) {
        case context.params[:upload_id]
        when *deleted_multipart_uploads
          { parts: [] }
        when "upload_id1"
          { parts: [] }
        when "upload_id2"
          { parts: [] }
        when "upload_id3"
          { parts: [{ part_number: 1, last_modified: @expiration_date - 1 }] }
        when "upload_id4"
          { parts: [{ part_number: 1, last_modified: @expiration_date - 1 },
                    { part_number: 2, last_modified: @expiration_date + 1 }] }
        end
      })
      @storage.client.stub_responses(:abort_multipart_upload, -> (context) {
        deleted_multipart_uploads << context.params[:upload_id]
      })

      @storage.expire_files(@expiration_date)

      assert_equal ["upload_id2", "upload_id3"], deleted_multipart_uploads
    end
  end
end
